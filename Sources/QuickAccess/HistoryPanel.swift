import AppKit
import SwiftUI
import AVFoundation
import ImageIO

/// Key capable so Escape, the arrow keys, and clicking away behave the way a
/// window is expected to. The old panel was non activating, which meant its
/// key monitor never fired and Escape did nothing.
final class HistoryWindow: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// A compact dock of recent captures across the top of the screen. Scrolls
/// sideways through everything, filters by kind, works from the keyboard, and
/// every thumbnail can be dragged straight out into another app or a terminal.
final class HistoryPanelController: NSObject, NSWindowDelegate {
    static let shared = HistoryPanelController()

    /// Small on purpose: this sits over whatever the user is working on, so it
    /// has to stay out of the way while still showing a full row of captures.
    private static let height: CGFloat = 196

    private var panel: NSPanel?
    private var model: HistoryDockModel?
    private var keyMonitor: Any?
    private var scrollMonitor: Any?

    var isVisible: Bool { panel != nil }

    func toggle() {
        if panel != nil {
            close()
        } else {
            show()
        }
    }

    func show() {
        close()
        let mouse = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) })
            ?? NSScreen.main ?? NSScreen.screens.first else { return }
        let model = HistoryDockModel()
        self.model = model

        // Only as wide as the captures need. A dock stretched across an
        // ultra wide display left a few tiles stranded at one end of a long
        // empty bar.
        let visible = screen.visibleFrame
        let content = CGFloat(model.all.count) * (HistoryTile.size.width + HistoryDockView.tileSpacing)
            - HistoryDockView.tileSpacing + HistoryDockView.inset * 2
        let width = min(max(content, 620), min(1240, visible.width - 120))
        let height = HistoryPanelController.height
        let rect = NSRect(x: visible.midX - width / 2, y: visible.maxY - height - 10,
                          width: width, height: height)

        let panel = HistoryWindow(contentRect: rect.offsetBy(dx: 0, dy: 10), styleMask: [.borderless],
                                  backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        panel.isMovableByWindowBackground = false
        panel.acceptsMouseMovedEvents = true
        panel.delegate = self
        panel.contentView = NSHostingView(rootView: HistoryDockView(model: model))
        panel.alphaValue = 0

        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        // Drops a few points into place as it fades up, so it reads as coming
        // down from the menu bar rather than appearing from nowhere.
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.25, 1)
            panel.animator().alphaValue = 1
            panel.animator().setFrame(rect, display: true)
        }
        self.panel = panel

        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, let model = self.model, event.window === self.panel else { return event }
            let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
            switch event.keyCode {
            case 53: self.close(); return nil // Escape
            case 123: model.moveSelection(by: -1); return nil // Left
            case 124: model.moveSelection(by: 1); return nil // Right
            case 36, 76: model.copySelection(); return nil // Return
            case 51, 117 where flags == [.command]: model.trashSelection(); return nil // ⌘⌫
            default: break
            }
            if flags.isEmpty, event.charactersIgnoringModifiers?.lowercased() == "e" {
                model.editSelection()
                return nil
            }
            return event
        }

        // A mouse wheel only scrolls vertically, which a sideways strip ignores.
        // Turn those notches sideways; trackpads already scroll both ways.
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard event.window === self?.panel, !event.hasPreciseScrollingDeltas,
                  abs(event.scrollingDeltaY) > abs(event.scrollingDeltaX),
                  let cg = event.cgEvent?.copy() else { return event }
            let fields: [(CGEventField, CGEventField)] = [
                (.scrollWheelEventDeltaAxis1, .scrollWheelEventDeltaAxis2),
                (.scrollWheelEventPointDeltaAxis1, .scrollWheelEventPointDeltaAxis2),
                (.scrollWheelEventFixedPtDeltaAxis1, .scrollWheelEventFixedPtDeltaAxis2)
            ]
            for (vertical, horizontal) in fields {
                cg.setIntegerValueField(horizontal, value: cg.getIntegerValueField(vertical))
                cg.setIntegerValueField(vertical, value: 0)
            }
            return NSEvent(cgEvent: cg) ?? event
        }

        NotificationCenter.default.addObserver(self, selector: #selector(dragEnded),
                                               name: .snaplineDragEnded, object: nil)
    }

    func close() {
        NotificationCenter.default.removeObserver(self, name: .snaplineDragEnded, object: nil)
        for monitor in [keyMonitor, scrollMonitor] {
            if let monitor { NSEvent.removeMonitor(monitor) }
        }
        keyMonitor = nil
        scrollMonitor = nil
        model = nil
        guard let panel else { return }
        self.panel = nil
        panel.delegate = nil
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.12
            panel.animator().alphaValue = 0
        }, completionHandler: {
            panel.orderOut(nil)
        })
    }

    func windowDidResignKey(_ notification: Notification) {
        // Dragging a capture out makes the destination app key. Keep the dock
        // alive until the drop lands, otherwise the drag dies halfway.
        guard !DragOutSource.isDragging else { return }
        close()
    }

    @objc private func dragEnded() {
        guard let panel, !panel.isKeyWindow else { return }
        close()
    }
}

// MARK: Model

struct HistoryItem: Identifiable, Equatable {
    enum Kind {
        case screenshot, recording, gif
    }

    let id: URL
    let url: URL
    let kind: Kind
    let date: Date

    init(url: URL) {
        self.id = url
        self.url = url
        switch url.pathExtension.lowercased() {
        case "mp4", "mov": kind = .recording
        case "gif": kind = .gif
        default: kind = .screenshot
        }
        let values = try? url.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey])
        date = values?.creationDate ?? values?.contentModificationDate ?? Date()
    }

    /// "Just now", "12 min ago", "3 hr ago", then "Yesterday" and a plain date.
    var age: String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) {
            let seconds = Date().timeIntervalSince(date)
            if seconds < 60 { return "Just now" }
            if seconds < 3600 { return "\(Int(seconds / 60)) min ago" }
            return "\(Int(seconds / 3600)) hr ago"
        }
        if calendar.isDateInYesterday(date) { return "Yesterday" }
        let formatter = DateFormatter()
        formatter.dateFormat = calendar.isDate(date, equalTo: Date(), toGranularity: .year) ? "d MMM" : "d MMM yyyy"
        return formatter.string(from: date)
    }
}

/// Shared by the SwiftUI dock and the panel's keyboard handling, so a key
/// press and a click run exactly the same action.
final class HistoryDockModel: ObservableObject {
    enum Filter: CaseIterable {
        case all, screenshots, recordings, gifs

        var title: String {
            switch self {
            case .all: return "All"
            case .screenshots: return "Screenshots"
            case .recordings: return "Recordings"
            case .gifs: return "GIFs"
            }
        }

        func includes(_ item: HistoryItem) -> Bool {
            switch self {
            case .all: return true
            case .screenshots: return item.kind == .screenshot
            case .recordings: return item.kind == .recording
            case .gifs: return item.kind == .gif
            }
        }
    }

    @Published private(set) var all: [HistoryItem] = []
    @Published var filter: Filter = .all {
        didSet { selection = items.first?.id }
    }
    @Published var selection: URL?
    @Published private(set) var copiedID: URL?

    private var observer: NSObjectProtocol?

    init() {
        all = HistoryStore.shared.items().map(HistoryItem.init)
        selection = all.first?.id
        observer = NotificationCenter.default.addObserver(forName: .snaplineHistoryChanged, object: nil,
                                                          queue: .main) { [weak self] _ in
            self?.reload()
        }
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    var items: [HistoryItem] { all.filter(filter.includes) }

    func count(_ filter: Filter) -> Int { all.filter(filter.includes).count }

    /// Filters with nothing in them stay out of the header; All always shows.
    var visibleFilters: [Filter] { Filter.allCases.filter { $0 == .all || count($0) > 0 } }

    private func reload() {
        let previous = items
        let fresh = HistoryStore.shared.items().map(HistoryItem.init)
        withAnimation(.easeOut(duration: 0.18)) {
            all = fresh
            if !visibleFilters.contains(filter) { filter = .all }
            // A trashed selection hands over to its neighbour instead of vanishing.
            if let selection, !items.contains(where: { $0.id == selection }) {
                let index = previous.firstIndex { $0.id == selection } ?? 0
                self.selection = items.isEmpty ? nil : items[min(index, items.count - 1)].id
            }
        }
    }

    // MARK: Keyboard

    func moveSelection(by step: Int) {
        let list = items
        guard !list.isEmpty else { return }
        let current = list.firstIndex { $0.id == selection } ?? (step > 0 ? -1 : list.count)
        selection = list[max(0, min(list.count - 1, current + step))].id
    }

    private var selectedItem: HistoryItem? { items.first { $0.id == selection } }

    func copySelection() { selectedItem.map(copy) }
    func editSelection() { selectedItem.map(edit) }
    func trashSelection() { selectedItem.map(trash) }

    // MARK: Actions

    func copy(_ item: HistoryItem) {
        selection = item.id
        ImageWriter.copyFileToClipboard(item.url)
        QuickAccessCenter.shared.markClipboardOwner(nil)
        withAnimation(.easeOut(duration: 0.12)) { copiedID = item.id }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            guard self?.copiedID == item.id else { return }
            withAnimation(.easeOut(duration: 0.15)) { self?.copiedID = nil }
        }
    }

    func edit(_ item: HistoryItem) {
        guard item.kind == .screenshot else {
            NSWorkspace.shared.open(item.url)
            return
        }
        guard let source = CGImageSourceCreateWithURL(item.url as CFURL, nil),
              let cg = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return }
        var scale: CGFloat = 1
        if let rep = NSImage(contentsOf: item.url)?.representations.first, rep.size.width > 0 {
            scale = CGFloat(cg.width) / rep.size.width
        }
        EditorWindowController.open(capture: Capture(image: cg, scale: max(1, scale),
                                                     savedURL: item.url, fileURL: item.url))
        HistoryPanelController.shared.close()
    }

    func restore(_ item: HistoryItem) {
        selection = item.id
        QuickAccessCenter.shared.restore(url: item.url)
    }

    func pin(_ item: HistoryItem) {
        guard let nsImage = NSImage(contentsOf: item.url) else { return }
        PinWindowController.pin(nsImage: nsImage)
        HistoryPanelController.shared.close()
    }

    func trash(_ item: HistoryItem) {
        HistoryStore.shared.delete(item.url)
    }

    func clearHistory() {
        HistoryStore.shared.clear()
    }
}

// MARK: Dock

struct HistoryDockView: View {
    @ObservedObject var model: HistoryDockModel

    static let tileSpacing: CGFloat = 12
    static let inset: CGFloat = 16

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            if model.items.isEmpty {
                emptyState
            } else {
                strip
            }
        }
        .padding(.top, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color.black.opacity(0.38)))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.white.opacity(0.09), lineWidth: 0.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .environment(\.colorScheme, .dark)
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 14) {
            Text("Recent Captures")
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(.white.opacity(0.94))

            HStack(spacing: 2) {
                ForEach(model.visibleFilters, id: \.self) { filter in
                    filterChip(filter)
                }
            }
            .padding(2)
            .background(Capsule().fill(Color.white.opacity(0.06)))

            Spacer(minLength: 12)

            if !model.items.isEmpty {
                // Shown whole or not at all: a narrow dock drops the hint
                // rather than cutting it off halfway.
                ViewThatFits(in: .horizontal) {
                    Text("←  →  select   ↩  copy   E  edit   ⌘⌫  trash")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(.white.opacity(0.3))
                        .fixedSize()
                    Color.clear.frame(width: 0, height: 0)
                }
            }

            HStack(spacing: 2) {
                Menu {
                    Button("Open Captures Folder") {
                        NSWorkspace.shared.open(SettingsStore.shared.saveDirectoryURL)
                    }
                    Divider()
                    Button("Clear History") { model.clearHistory() }
                } label: {
                    headerIcon("ellipsis")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("More")

                Button { HistoryPanelController.shared.close() } label: {
                    headerIcon("xmark")
                }
                .buttonStyle(.plain)
                .help("Close (Esc)")
            }
        }
        .padding(.horizontal, HistoryDockView.inset)
    }

    private func filterChip(_ filter: HistoryDockModel.Filter) -> some View {
        let selected = model.filter == filter
        return Button {
            withAnimation(.easeOut(duration: 0.15)) { model.filter = filter }
        } label: {
            HStack(spacing: 5) {
                Text(filter.title)
                Text("\(model.count(filter))")
                    .foregroundStyle(.white.opacity(selected ? 0.55 : 0.32))
            }
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.white.opacity(selected ? 0.95 : 0.55))
            .padding(.horizontal, 10)
            .frame(height: 22)
            .background(Capsule().fill(Color.white.opacity(selected ? 0.14 : 0)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private func headerIcon(_ system: String) -> some View {
        Image(systemName: system)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.white.opacity(0.55))
            .frame(width: 24, height: 24)
            .contentShape(Rectangle())
    }

    // MARK: Strip

    private var strip: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: HistoryDockView.tileSpacing) {
                    ForEach(model.items) { item in
                        HistoryTile(item: item, model: model)
                            .id(item.id)
                            .transition(.opacity.combined(with: .scale(scale: 0.92)))
                    }
                }
                .padding(.horizontal, HistoryDockView.inset)
                .padding(.top, 3) // room for the selection ring
                .padding(.bottom, 12)
            }
            .onChange(of: model.selection) { _, selection in
                guard let selection else { return }
                withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(selection, anchor: .center) }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 20, weight: .light))
                .foregroundStyle(.white.opacity(0.3))
            Text(model.filter == .all ? "No captures yet" : "No \(model.filter.title.lowercased()) yet")
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(.white.opacity(0.7))
            if let shortcut = SettingsStore.shared.shortcut(for: .captureArea) {
                Text("Press \(shortcut.displayString) to capture an area")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.38))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.bottom, 12)
    }
}

// MARK: Tile

struct HistoryTile: View {
    let item: HistoryItem
    @ObservedObject var model: HistoryDockModel

    static let size = CGSize(width: 156, height: 98)

    @State private var thumbnail: NSImage?
    @State private var detail: String?
    @State private var hovering = false
    @State private var dragHandle = DragOutHandle()

    private var selected: Bool { model.selection == item.id }
    private var copied: Bool { model.copiedID == item.id }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            artwork
                .frame(width: HistoryTile.size.width, height: HistoryTile.size.height)
                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                .overlay(border)
                .contentShape(Rectangle())
                .onTapGesture { model.copy(item) }
                .dragOut(dragHandle) {
                    DragPayload(fileURL: { item.url }, preview: { thumbnail })
                }
                .overlay { hoverActions }
                .overlay(alignment: .topTrailing) { trashButton }
                .overlay(alignment: .bottomLeading) { kindBadge }
                .overlay { copiedBadge }
                .help("Click to copy, drag into any app or terminal")

            caption
        }
        .frame(width: HistoryTile.size.width)
        .onHover { inside in
            withAnimation(.easeOut(duration: 0.12)) { hovering = inside }
        }
        .onAppear(perform: load)
        .contextMenu { menu }
    }

    // MARK: Pieces

    /// The shot fills the tile, so a dark terminal capture still reads as a
    /// picture rather than a small dark rectangle floating in a dark box.
    private var artwork: some View {
        ZStack {
            Color.white.opacity(0.06)

            if let thumbnail {
                Image(nsImage: thumbnail)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: HistoryTile.size.width, height: HistoryTile.size.height)
            } else {
                Image(systemName: item.kind == .screenshot ? "photo" : "film")
                    .font(.system(size: 16, weight: .light))
                    .foregroundStyle(.white.opacity(0.3))
            }

            if hovering || copied {
                Color.black.opacity(0.45)
            }
        }
    }

    private var border: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(Color.white.opacity(hovering ? 0.22 : 0.1), lineWidth: 0.5)
            if selected {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .strokeBorder(Color.accentColor, lineWidth: 2)
                    .padding(-3)
            }
        }
        .allowsHitTesting(false)
    }

    @ViewBuilder
    private var hoverActions: some View {
        if hovering, !copied {
            HStack(spacing: 8) {
                roundButton("arrow.uturn.backward", help: "Restore to overlay") { model.restore(item) }
                if item.kind == .screenshot {
                    roundButton("pencil", help: "Annotate (E)") { model.edit(item) }
                } else {
                    roundButton("play.fill", help: "Open") { model.edit(item) }
                }
                roundButton("doc.on.doc", help: "Copy (Return)") { model.copy(item) }
            }
            .transition(.opacity)
        }
    }

    @ViewBuilder
    private var trashButton: some View {
        if hovering, !copied {
            Button { model.trash(item) } label: {
                Image(systemName: "trash")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.9))
                    .frame(width: 20, height: 20)
                    .background(Circle().fill(Color.black.opacity(0.55)))
                    .overlay(Circle().strokeBorder(Color.white.opacity(0.15), lineWidth: 0.5))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help("Move to Trash (⌘⌫)")
            .padding(5)
            .transition(.opacity)
        }
    }

    /// Recordings and GIFs carry a small label so they are never mistaken for stills.
    @ViewBuilder
    private var kindBadge: some View {
        if item.kind != .screenshot, !hovering {
            HStack(spacing: 3) {
                Image(systemName: item.kind == .recording ? "play.fill" : "photo.stack")
                    .font(.system(size: 7.5, weight: .bold))
                Text(item.kind == .recording ? "Video" : "GIF")
                    .font(.system(size: 9.5, weight: .semibold))
            }
            .foregroundStyle(.white.opacity(0.95))
            .padding(.horizontal, 6)
            .frame(height: 17)
            .background(Capsule().fill(Color.black.opacity(0.6)))
            .padding(5)
        }
    }

    @ViewBuilder
    private var copiedBadge: some View {
        if copied {
            Label("Copied", systemImage: "checkmark")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.black.opacity(0.85))
                .padding(.horizontal, 10)
                .frame(height: 24)
                .background(Capsule().fill(Color.white.opacity(0.95)))
                .allowsHitTesting(false)
                .transition(.opacity)
        }
    }

    private var caption: some View {
        HStack(spacing: 4) {
            Text(item.age)
                .foregroundStyle(.white.opacity(selected ? 0.85 : 0.6))
            if let detail {
                Text("·").foregroundStyle(.white.opacity(0.25))
                Text(detail)
                    .foregroundStyle(.white.opacity(0.38))
                    .monospacedDigit()
            }
        }
        .font(.system(size: 10.5, weight: .medium))
        .lineLimit(1)
        .padding(.leading, 1)
    }

    private func roundButton(_ system: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: system)
                .font(.system(size: 10.5, weight: .bold))
                .foregroundStyle(Color.black.opacity(0.82))
                .frame(width: 28, height: 28)
                .background(Circle().fill(Color.white.opacity(0.95)))
                .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    @ViewBuilder
    private var menu: some View {
        Button("Copy") { model.copy(item) }
        Button("Restore to Overlay") { model.restore(item) }
        if item.kind == .screenshot {
            Button("Annotate") { model.edit(item) }
            Button("Pin to Screen") { model.pin(item) }
        } else {
            Button("Open") { model.edit(item) }
        }
        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }
        Divider()
        Button("Move to Trash") { model.trash(item) }
    }

    // MARK: Loading

    /// Thumbnail plus the caption detail: pixel size for stills and GIFs,
    /// running time for recordings.
    private func load() {
        guard thumbnail == nil else { return }
        let url = item.url
        let kind = item.kind
        DispatchQueue.global(qos: .userInitiated).async {
            var image: NSImage?
            var info: String?
            if kind == .recording {
                let asset = AVURLAsset(url: url)
                let generator = AVAssetImageGenerator(asset: asset)
                generator.appliesPreferredTrackTransform = true
                generator.maximumSize = CGSize(width: 480, height: 480)
                if let cg = try? generator.copyCGImage(at: .zero, actualTime: nil) {
                    image = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
                }
                let seconds = Int(CMTimeGetSeconds(asset.duration).rounded())
                if seconds > 0 { info = String(format: "%d:%02d", seconds / 60, seconds % 60) }
            } else if let source = CGImageSourceCreateWithURL(url as CFURL, nil) {
                let options: [CFString: Any] = [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: 480
                ]
                if let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) {
                    image = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
                }
                if let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                   let width = properties[kCGImagePropertyPixelWidth] as? Int,
                   let height = properties[kCGImagePropertyPixelHeight] as? Int {
                    info = "\(width)×\(height)"
                }
            }
            DispatchQueue.main.async {
                guard let image else {
                    // The file went missing behind our back; drop the stale entry.
                    HistoryStore.shared.forget(url)
                    return
                }
                thumbnail = image
                detail = info
            }
        }
    }
}
