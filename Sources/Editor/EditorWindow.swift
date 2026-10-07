import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

/// Editor window hosting the toolbar and canvas.
final class EditorWindowController: NSWindowController, NSWindowDelegate {
    private static var controllers: [EditorWindowController] = []

    let state: EditorState
    private var keyMonitor: Any?
    private var titlebarObservers: [NSObjectProtocol] = []
    private var buttonsPending = false

    // Export cache. Every result action used to render the full document and
    // encode it to PNG on the main thread (Done did it twice, a drag rendered
    // twice), 200 to 300 ms of frozen UI on a Retina shot. Now the result is
    // rendered once per edit, encoded once, off the main thread, and reused.
    private var stateObserver: AnyCancellable?
    /// Bumped on every document change; cached results are valid for one revision.
    private var revision = 0
    private var rendered: (revision: Int, image: CGImage)?
    private var encodedPNG: (revision: Int, data: Data)?
    /// The file a drag last wrote, reused while nothing has changed since.
    private var persisted: (revision: Int, url: URL)?
    private var prewarm: DispatchWorkItem?
    private static let encodeQueue = DispatchQueue(label: "com.joymadhu.Snapline.editor-encode", qos: .userInitiated)

    static func open(capture: Capture) {
        let controller = EditorWindowController(state: EditorState(capture: capture))
        controllers.append(controller)
        controller.showWindow(nil)
        // Cooperative activation can be refused; force the window forward regardless.
        controller.window?.orderFrontRegardless()
        controller.window?.makeKey()
        NSApp.activate(ignoringOtherApps: true)
    }

    init(state: EditorState) {
        self.state = state

        let screen = NSScreen.main ?? NSScreen.screens[0]
        let maxW = screen.visibleFrame.width * 0.78
        let maxH = screen.visibleFrame.height * 0.82
        let imgW = CGFloat(state.baseImage.width) / state.captureScale
        let imgH = CGFloat(state.baseImage.height) / state.captureScale
        // Toolbar and status bar take 80 points; 48 more keeps the shot off the edges.
        let chrome = EditorToolbar.height + EditorStatusBar.height + 48
        let fit = min(maxW / max(imgW, 1), (maxH - chrome) / max(imgH, 1), 1)
        // The window opens wide enough for the fully spelled out toolbar when
        // the screen allows, and can never be made narrower than the compact
        // toolbar, so the toolbar is never squeezed past what it can show.
        let fullWidth = EditorToolbar.width(of: .full, state: state)
        let minimumWidth = EditorToolbar.width(of: .compact, state: state)
        let openWidth = min(max(fullWidth, imgW * fit + 48), screen.visibleFrame.width - 40)
        let contentSize = NSSize(width: max(minimumWidth, openWidth),
                                 height: max(540, imgH * fit + chrome))

        // The toolbar lives in the title bar row, as in Xcode, Figma, and
        // CleanShot's annotate window, instead of under an empty title strip.
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: contentSize),
                              // Not miniaturizable: the editor is a short task that ends
                              // in Done, and a minimised editor was easy to lose.
                              styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.title = state.savedURL?.lastPathComponent ?? "Snapline"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = EditorPalette.canvas
        window.contentMinSize = NSSize(width: minimumWidth, height: 460)
        window.center()
        window.isReleasedWhenClosed = false

        super.init(window: window)

        window.delegate = self
        let root = EditorRootView(state: state, controller: self)
        window.contentView = NSHostingView(rootView: root)
        installKeyMonitor()
        positionWindowButtons()
        watchTitlebarLayout()
        stateObserver = state.objectWillChange.sink { [weak self] _ in self?.documentChanged() }
        schedulePrewarm()
    }

    /// Centres the close, minimise, and zoom buttons in the taller toolbar row.
    /// Only touches frames that are off, so it is cheap to call often.
    private func positionWindowButtons() {
        guard let window, let close = window.standardWindowButton(.closeButton),
              let container = close.superview?.superview else { return }
        let height = EditorToolbar.height
        var frame = container.frame
        if frame.size.height != height || frame.origin.y != window.frame.height - height {
            frame.size.height = height
            frame.origin.y = window.frame.height - height
            container.frame = frame
        }
        for (index, kind) in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].enumerated() {
            guard let button = window.standardWindowButton(kind) else { continue }
            let origin = NSPoint(x: 20 + CGFloat(index) * 20, y: (height - button.frame.height) / 2)
            if button.frame.origin != origin { button.setFrameOrigin(origin) }
        }
    }

    /// AppKit lays the title bar out again on far more than resizing: a title
    /// or focus change, the window becoming key, document state. Each time the
    /// buttons jump back to the top, out of line with the toolbar. So the views
    /// involved report their frame changes, and the buttons are put back once
    /// AppKit's own layout pass is over; doing it inside the notification gets
    /// overwritten by the rest of that pass.
    private func watchTitlebarLayout() {
        guard let close = window?.standardWindowButton(.closeButton) else { return }
        let views = [close, close.superview, close.superview?.superview].compactMap { $0 }
        for view in views {
            view.postsFrameChangedNotifications = true
            titlebarObservers.append(NotificationCenter.default.addObserver(
                forName: NSView.frameDidChangeNotification, object: view, queue: .main) { [weak self] _ in
                    guard let self, !self.buttonsPending else { return }
                    self.buttonsPending = true
                    DispatchQueue.main.async {
                        self.buttonsPending = false
                        self.positionWindowButtons()
                    }
                })
        }
    }

    func windowDidResize(_ notification: Notification) { positionWindowButtons() }
    func windowDidExitFullScreen(_ notification: Notification) { positionWindowButtons() }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, let window = self.window, window.isKeyWindow else { return event }
            if window.firstResponder is NSTextView { return event }
            let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
            let key = event.charactersIgnoringModifiers?.lowercased() ?? ""

            if flags == [.command] && key == "z" { self.state.undo(); return nil }
            if flags == [.command, .shift] && key == "z" { self.state.redo(); return nil }
            if flags == [.command] && key == "c" { self.copyResult(); return nil }
            if flags == [.command] && key == "s" { self.saveResult(); return nil }
            if flags == [.command] && key == "w" { window.close(); return nil }
            if flags == [.command] && (event.keyCode == 36 || event.keyCode == 76) { self.done(); return nil }
            if flags.isEmpty {
                switch event.keyCode {
                case 51, 117: // delete keys
                    if self.state.selectedID != nil { self.state.deleteSelected(); return nil }
                case 53: // escape
                    if self.state.cropDraft != nil { self.state.cropDraft = nil; return nil }
                    if self.state.selectedID != nil { self.state.selectedID = nil; return nil }
                case 36, 76: // return keys
                    if self.state.tool == .crop, self.state.cropDraft != nil {
                        self.state.applyCrop(); return nil
                    }
                default:
                    if self.state.editingTextID == nil,
                       let tool = EditorTool.allCases.first(where: { $0.key == key }) {
                        self.state.choose(tool); return nil
                    }
                }
            }
            return event
        }
    }

    func windowWillClose(_ notification: Notification) {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        titlebarObservers.forEach(NotificationCenter.default.removeObserver)
        titlebarObservers = []
        prewarm?.cancel()
        stateObserver = nil
        EditorWindowController.controllers.removeAll { $0 === self }
    }

    // MARK: Result actions

    /// The flattened document, rendered at most once per edit. Synchronous,
    /// for the few callers that need the pixels right now (a drag's preview
    /// and file); everything else goes through `withResult`.
    func renderResult() -> CGImage? {
        if let rendered, rendered.revision == revision { return rendered.image }
        guard let image = EditorRenderer.render(state: state) else { return nil }
        rendered = (revision, image)
        return image
    }

    private func documentChanged() {
        revision += 1
        schedulePrewarm()
    }

    /// Once edits pause, renders and encodes the result in the background, so
    /// Copy, Done, and a drag find it ready.
    private func schedulePrewarm() {
        prewarm?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.withResult(encoded: true) { _, _, _ in } }
        prewarm = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
    }

    /// The current result, rendered from a snapshot of the document off the
    /// main thread, plus its PNG bytes when `encoded` is set (or when they are
    /// cached anyway). Completion runs on the main thread with the revision the
    /// pixels belong to, and does not need this controller to still be alive.
    private func withResult(encoded: Bool, _ completion: @escaping (CGImage, Data?, Int) -> Void) {
        let current = revision
        let cachedImage = rendered?.revision == current ? rendered?.image : nil
        let cachedPNG = readyPNG
        if let cachedImage, !encoded || cachedPNG != nil {
            completion(cachedImage, cachedPNG, current)
            return
        }
        let document = cachedImage == nil ? state.document() : nil
        let scale = state.captureScale
        Self.encodeQueue.async {
            guard let image = cachedImage ?? document.flatMap({ EditorRenderer.render($0) }) else { return }
            let png = encoded ? ImageWriter.data(for: image, format: .png, jpgQuality: 1, scale: scale) : nil
            DispatchQueue.main.async { [weak self] in
                if let self, self.revision == current {
                    self.rendered = (current, image)
                    if let png { self.encodedPNG = (current, png) }
                }
                completion(image, png, current)
            }
        }
    }

    /// PNG bytes for the current revision if they are already encoded.
    private var readyPNG: Data? {
        guard let encodedPNG, encodedPNG.revision == revision else { return nil }
        return encodedPNG.data
    }

    func copyResult() {
        let scale = state.captureScale
        withResult(encoded: true) { image, png, _ in
            ImageWriter.copyToClipboard(image, png: png, scale: scale)
            Toast.show("Copied to clipboard")
        }
    }

    func saveResult() {
        let target = state.savedURL ?? ImageWriter.uniqueURL(
            in: SettingsStore.shared.directory(for: .screenshot),
            fileName: ImageWriter.suggestedFileName(ext: SettingsStore.shared.imageFormat.fileExtension))
        state.savedURL = target
        save(to: target)
    }

    private func save(to target: URL) {
        let scale = state.captureScale
        withResult(encoded: false) { [weak self] image, png, revision in
            ImageWriter.exportInBackground(image, scale: scale, to: target, png: png, copy: false) { written in
                guard let written else { return Toast.show("Could not save") }
                HistoryStore.shared.add(written)
                if let self {
                    self.state.savedURL = written
                    if self.revision == revision { self.persisted = (revision, written) }
                }
                Toast.show("Saved")
            }
        }
    }

    /// Done means the edits become the capture. The file is rewritten in place,
    /// the clipboard and the quick access overlay pick up the edited image, and
    /// the window goes away. From the overlay card the edited shot can then be
    /// dragged into any app or terminal like a fresh capture.
    ///
    /// The window closes at once. The card appears as soon as the render is
    /// ready, and the write and clipboard follow in the background, queued
    /// after any capture write; a drag from the card waits for them, so it
    /// always carries the edits.
    func done() {
        let target = persistTarget()
        let scale = state.captureScale
        let savedURL = state.savedURL
        withResult(encoded: false) { image, png, _ in
            QuickAccessCenter.shared.showEdited(Capture(image: image, scale: scale, savedURL: savedURL, fileURL: target))
            ImageWriter.exportInBackground(image, scale: scale, to: target, png: png, copy: true) { written in
                if let written { HistoryStore.shared.add(written) }
            }
        }
        window?.close()
    }

    /// The file edits are written over: the saved file, else the one the
    /// capture came in as, else a new one in the screenshots folder.
    private func persistTarget() -> URL {
        if let target = state.savedURL ?? state.sourceFileURL { return target }
        let url = ImageWriter.uniqueURL(in: SettingsStore.shared.directory(for: .screenshot),
                                        fileName: ImageWriter.suggestedFileName(ext: SettingsStore.shared.imageFormat.fileExtension))
        state.savedURL = url
        return url
    }

    /// The file a drag out of the editor hands to the receiving app. It has to
    /// exist before the drag starts, so this one stays synchronous, but it
    /// reuses the file from an earlier drag or Save when nothing changed since,
    /// and the prewarmed render and PNG otherwise.
    func persistResult() -> URL? {
        if let persisted, persisted.revision == revision,
           FileManager.default.fileExists(atPath: persisted.url.path) {
            return persisted.url
        }
        guard let image = renderResult() else { return nil }
        let target = persistTarget()
        let ext = target.pathExtension.lowercased()
        let format: ImageFormat = ext == "jpg" || ext == "jpeg" ? .jpg : .png
        let data = format == .png
            ? readyPNG ?? ImageWriter.data(for: image, format: .png, jpgQuality: 1, scale: state.captureScale)
            : ImageWriter.data(for: image, format: .jpg, jpgQuality: SettingsStore.shared.jpgQuality,
                               scale: state.captureScale)
        // The capture's own first write must land before the edit overwrites it.
        ImageWriter.waitForPendingWrites()
        guard let data, (try? data.write(to: target)) != nil else { return nil }
        HistoryStore.shared.add(target)
        persisted = (revision, target)
        return target
    }

    func resultPreview() -> NSImage? {
        guard let image = renderResult() else { return nil }
        let factor = max(1, state.captureScale)
        return NSImage(cgImage: image, size: NSSize(width: CGFloat(image.width) / factor,
                                                    height: CGFloat(image.height) / factor))
    }

    func saveResultAs() {
        guard let window else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png, .jpeg]
        panel.nameFieldStringValue = ImageWriter.suggestedFileName(ext: SettingsStore.shared.imageFormat.fileExtension)
        panel.directoryURL = SettingsStore.shared.saveDirectoryURL
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url, let self else { return }
            self.state.savedURL = url
            self.save(to: url)
        }
    }

    func pinResult() {
        let scale = state.captureScale
        withResult(encoded: false) { image, _, _ in
            PinWindowController.pin(cgImage: image, scale: scale)
        }
    }
}

// MARK: Palette

/// Three steps of dark, darkest at the canvas so the shot is the brightest
/// thing in the window, and hairlines instead of borders between them.
enum EditorPalette {
    static let canvas = NSColor(srgbRed: 0.071, green: 0.075, blue: 0.086, alpha: 1)
    static let bar = Color(nsColor: NSColor(srgbRed: 0.106, green: 0.110, blue: 0.125, alpha: 1))
    static let hairline = Color.white.opacity(0.07)
    static let control = Color.white.opacity(0.07)
    static let controlHover = Color.white.opacity(0.11)
    static let selected = Color.white.opacity(0.15)
}

// MARK: Root view

struct EditorRootView: View {
    @ObservedObject var state: EditorState
    weak var controller: EditorWindowController?
    @State private var zoom: CGFloat = 1

    var body: some View {
        VStack(spacing: 0) {
            EditorToolbar(state: state, controller: controller)
            Rectangle().fill(EditorPalette.hairline).frame(height: 1)
            EditorCanvasView(state: state)
                .onPreferenceChange(EditorZoomKey.self) { zoom = $0 }
            Rectangle().fill(EditorPalette.hairline).frame(height: 1)
            EditorStatusBar(state: state, zoom: zoom)
        }
        .background(Color(nsColor: EditorPalette.canvas))
        .ignoresSafeArea()
        .preferredColorScheme(.dark)
    }
}

/// The canvas reports its fit scale so the status bar can show it.
struct EditorZoomKey: PreferenceKey {
    static var defaultValue: CGFloat = 1
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

/// Empty toolbar space moves the window like a title bar would, and a double
/// click zooms it, since the toolbar now covers the title bar.
struct WindowDragArea: NSViewRepresentable {
    final class DragView: NSView {
        override var mouseDownCanMoveWindow: Bool { true }
        override func mouseDown(with event: NSEvent) {
            if event.clickCount == 2 {
                // Zoom even when the system setting says minimise: the editor
                // cannot be minimised, and doing nothing would feel broken.
                let action = UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick") ?? "Maximize"
                if action != "None" { window?.zoom(nil) }
            } else {
                window?.performDrag(with: event)
            }
        }
    }
    func makeNSView(context: Context) -> NSView { DragView() }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

// MARK: Toolbar

struct EditorToolbar: View {
    static let height: CGFloat = 52

    @ObservedObject var state: EditorState
    weak var controller: EditorWindowController?
    @State private var showBackground = false
    @State private var showColors = false
    @State private var dragHandle = DragOutHandle()

    /// How much the toolbar spells out. The window is never narrower than
    /// `.compact` needs, so one of these always fits.
    enum Layout: CaseIterable {
        /// Every colour inline, labelled actions.
        case full
        /// Colours folded into one button, labelled actions.
        case regular
        /// Colours folded, icon only actions.
        case compact
    }

    /// Set only when measuring: renders exactly one layout at its ideal width.
    var measuring: Layout?

    var body: some View {
        Group {
            if let measuring {
                row(measuring).fixedSize()
            } else {
                // The first layout that fits wins, measured by SwiftUI rather
                // than guessed from a width threshold.
                ViewThatFits(in: .horizontal) {
                    ForEach(Layout.allCases, id: \.self) { row($0) }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: EditorToolbar.height)
        .background(WindowDragArea())
        .background(EditorPalette.bar)
    }

    private func row(_ layout: Layout) -> some View {
        HStack(spacing: 10) {
            Color.clear.frame(width: 72) // close, minimise, zoom
            toolButtons
            divider
            colorControl(compact: layout != .full)
            strokeControl
            divider
            undoRedo
            Spacer(minLength: 16)
            backgroundControl(compact: layout == .compact)
            divider
            actionButtons(compact: layout == .compact)
        }
        .padding(.trailing, 14)
        .frame(height: EditorToolbar.height)
    }

    /// The width a layout needs, measured from the real views so fonts and
    /// symbols can never drift out of step with the window's size limits.
    static func width(of layout: Layout, state: EditorState) -> CGFloat {
        let host = NSHostingView(rootView: EditorToolbar(state: state, controller: nil, measuring: layout)
            .environment(\.colorScheme, .dark))
        return ceil(host.fittingSize.width)
    }

    private var divider: some View {
        Rectangle().fill(Color.white.opacity(0.1)).frame(width: 1, height: 20)
    }

    // MARK: Tools

    private var toolButtons: some View {
        HStack(spacing: 2) {
            ForEach(EditorTool.allCases) { tool in
                ToolbarIconButton(symbol: tool.symbol, help: tool.help, selected: state.tool == tool) {
                    state.choose(tool)
                }
            }
        }
        .padding(3)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.white.opacity(0.04)))
    }

    // MARK: Colour and stroke

    @ViewBuilder
    private func colorControl(compact: Bool) -> some View {
        if compact {
            Button { showColors.toggle() } label: {
                swatch(state.color, selected: false)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Colour")
            .popover(isPresented: $showColors, arrowEdge: .bottom) {
                HStack(spacing: 6) { swatchButtons(closeOnPick: true) }.padding(12)
            }
        } else {
            HStack(spacing: 3) { swatchButtons(closeOnPick: false) }
        }
    }

    @ViewBuilder
    private func swatchButtons(closeOnPick: Bool) -> some View {
        ForEach(Array(EditorState.palette.enumerated()), id: \.offset) { _, color in
            Button {
                state.color = color
                state.updateSelected { $0.color = color }
                if closeOnPick { showColors = false }
            } label: {
                swatch(color, selected: state.color == color)
                    .frame(width: 22, height: 26)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    /// A filled dot with a hairline, so black and white read on the dark bar,
    /// and a ring with a gap around the current colour.
    private func swatch(_ color: NSColor, selected: Bool) -> some View {
        Circle()
            .fill(Color(nsColor: color))
            .frame(width: 15, height: 15)
            .overlay(Circle().strokeBorder(Color.white.opacity(0.22), lineWidth: 0.5))
            .padding(2.5)
            .overlay(Circle().strokeBorder(Color.white.opacity(selected ? 0.9 : 0), lineWidth: 1.5))
    }

    /// Four weights shown as dots of their own size, so the choice is visible
    /// rather than hidden in a menu.
    private var strokeControl: some View {
        HStack(spacing: 1) {
            ForEach([(CGFloat(2), CGFloat(4)), (3, 6), (5, 8.5), (8, 11)], id: \.0) { width, dot in
                Button { state.strokeChoice = width } label: {
                    Circle()
                        .fill(Color.white.opacity(state.strokeChoice == width ? 0.95 : 0.55))
                        .frame(width: dot, height: dot)
                        .frame(width: 24, height: 26)
                        .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(state.strokeChoice == width ? EditorPalette.selected : .clear))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(strokeName(width))
            }
        }
    }

    private func strokeName(_ width: CGFloat) -> String {
        switch width {
        case 2: return "Thin"
        case 3: return "Regular"
        case 5: return "Bold"
        default: return "Heavy"
        }
    }

    private var undoRedo: some View {
        HStack(spacing: 2) {
            ToolbarIconButton(symbol: "arrow.uturn.backward", help: "Undo (⌘Z)", enabled: state.canUndo) { state.undo() }
            ToolbarIconButton(symbol: "arrow.uturn.forward", help: "Redo (⇧⌘Z)", enabled: state.canRedo) { state.redo() }
        }
    }

    // MARK: Background and actions

    private func backgroundControl(compact: Bool) -> some View {
        Button { showBackground.toggle() } label: {
            HStack(spacing: 6) {
                Image(systemName: "rectangle.inset.filled.on.rectangle")
                    .foregroundStyle(state.background.enabled ? Color.accentColor : .white.opacity(0.8))
                if !compact { Text("Background") }
            }
        }
        .buttonStyle(ToolbarPillStyle(active: state.background.enabled))
        .help("Background, padding, and shadow")
        .popover(isPresented: $showBackground, arrowEdge: .bottom) {
            BackgroundPanel(state: state)
        }
    }

    private func actionButtons(compact: Bool) -> some View {
        HStack(spacing: 6) {
            dragChip(compact: compact)

            ToolbarIconButton(symbol: "pin", help: "Pin the result to the screen") { controller?.pinResult() }

            Button { controller?.copyResult() } label: {
                HStack(spacing: 5) {
                    Image(systemName: "doc.on.doc")
                    if !compact { Text("Copy") }
                }
            }
            .buttonStyle(ToolbarPillStyle())
            .help("Copy the result (⌘C)")

            Menu {
                Button("Save") { controller?.saveResult() }
                    .keyboardShortcut("s", modifiers: .command)
                Button("Save As…") { controller?.saveResultAs() }
            } label: {
                Image(systemName: "square.and.arrow.down")
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(.white.opacity(0.8))
                    .frame(width: 30, height: 28)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Save")

            Button { controller?.done() } label: {
                HStack(spacing: 5) {
                    Image(systemName: "checkmark")
                    Text("Done")
                }
            }
            .buttonStyle(ToolbarPillStyle(prominent: true))
            .help("Save the edits, copy the result, and put it back on the overlay (⌘Return)")
        }
    }

    /// Not a button: grab it and drop the edited image into Finder, Slack, a
    /// terminal, or an agent prompt. The result is written to the capture's
    /// file as the drag starts, so what lands is what the canvas shows.
    private func dragChip(compact: Bool) -> some View {
        HStack(spacing: 5) {
            Image(systemName: "hand.draw")
            if !compact { Text("Drag") }
        }
        .fixedSize()
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(.white.opacity(0.85))
        .padding(.horizontal, 10)
        .frame(height: 28)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
            .strokeBorder(Color.white.opacity(0.16), style: StrokeStyle(lineWidth: 1, dash: [3, 2.5])))
        .contentShape(Rectangle())
        .dragOut(dragHandle) {
            DragPayload(fileURL: { controller?.persistResult() },
                        preview: { controller?.resultPreview() })
        }
        .help("Drag the edited image into any app or terminal")
    }
}

/// An icon button with a hover state, for tools and small actions.
struct ToolbarIconButton: View {
    let symbol: String
    let help: String
    var selected = false
    var enabled = true
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white.opacity(!enabled ? 0.25 : selected ? 1 : 0.68))
                .frame(width: 30, height: 28)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(selected ? EditorPalette.selected : hovering && enabled ? EditorPalette.control : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .onHover { hovering = $0 }
        .help(help)
    }
}

/// Neutral pill for secondary actions, accent filled for the one primary
/// action, so Done is always the obvious way out.
struct ToolbarPillStyle: ButtonStyle {
    var prominent = false
    var active = false

    func makeBody(configuration: Configuration) -> some View {
        PillBody(configuration: configuration, prominent: prominent, active: active)
    }

    private struct PillBody: View {
        let configuration: Configuration
        let prominent: Bool
        let active: Bool
        @State private var hovering = false

        var body: some View {
            configuration.label
                .font(.system(size: 12, weight: prominent ? .semibold : .medium))
                .foregroundStyle(.white.opacity(prominent ? 1 : 0.88))
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, 11)
                .frame(height: 28)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(fill))
                .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(Color.white.opacity(prominent ? 0.16 : 0), lineWidth: 0.5))
                .opacity(configuration.isPressed ? 0.8 : 1)
                .scaleEffect(configuration.isPressed ? 0.97 : 1)
                .contentShape(Rectangle())
                .onHover { hovering = $0 }
        }

        private var fill: Color {
            if prominent { return Color.accentColor.opacity(hovering ? 0.9 : 1) }
            if active { return Color.accentColor.opacity(hovering ? 0.26 : 0.2) }
            return hovering ? EditorPalette.controlHover : EditorPalette.control
        }
    }
}

// MARK: Status bar

/// Size of the result, what the current tool does, and the zoom level.
struct EditorStatusBar: View {
    static let height: CGFloat = 28

    @ObservedObject var state: EditorState
    let zoom: CGFloat

    var body: some View {
        HStack(spacing: 10) {
            Text(sizeText)
                .monospacedDigit()
            Spacer(minLength: 12)
            HStack(spacing: 10) {
                Text(hint)
                    .lineLimit(1)
                if state.tool == .crop, state.cropDraft != nil {
                    // Lives here rather than in the toolbar, so the toolbar
                    // keeps one width and never has to make room mid crop.
                    Button("Cancel") { state.cropDraft = nil }
                        .buttonStyle(.plain)
                        .foregroundStyle(.white.opacity(0.7))
                    Button("Apply Crop") { state.applyCrop() }
                        .buttonStyle(.plain)
                        .foregroundStyle(Color.accentColor)
                        .fontWeight(.semibold)
                }
            }
            Spacer(minLength: 12)
            Text("\(Int((zoom * state.captureScale * 100).rounded()))%")
                .monospacedDigit()
                .help("Shown at this size of the capture's actual points")
        }
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(.white.opacity(0.45))
        .padding(.horizontal, 14)
        .frame(height: EditorStatusBar.height)
        .background(EditorPalette.bar)
    }

    private var sizeText: String {
        let pad = state.background.enabled ? state.background.padding * state.captureScale * 2 : 0
        let width = Int(state.pixelWidth + pad), height = Int(state.pixelHeight + pad)
        return "\(width) × \(height) px" + (state.annotations.isEmpty ? "" : "  ·  \(state.annotations.count) mark\(state.annotations.count == 1 ? "" : "s")")
    }

    private var hint: String {
        switch state.tool {
        case .select: return state.selectedID == nil ? "Click a mark to select it" : "Drag to move  ·  handles resize  ·  ⌫ deletes"
        case .arrow: return "Drag to draw an arrow"
        case .line: return "Drag to draw a line"
        case .rect: return "Drag to draw a rectangle"
        case .ellipse: return "Drag to draw an ellipse"
        case .freehand: return "Draw freely"
        case .highlight: return "Drag across what matters to highlight it"
        case .text: return "Click to place text  ·  Return to finish"
        case .counter: return "Click to drop number \(state.counterNext)"
        case .redact: return "Drag over anything private to pixelate it"
        case .crop: return state.cropDraft == nil ? "Drag to choose the crop" : "Return applies  ·  Esc cancels"
        }
    }
}

// MARK: Background panel

struct BackgroundPanel: View {
    @ObservedObject var state: EditorState

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Toggle("Show background", isOn: $state.background.enabled)
                .toggleStyle(.switch)
                .controlSize(.small)

            HStack(spacing: 8) {
                ForEach(0..<BackgroundConfig.presets.count, id: \.self) { index in
                    let colors = BackgroundConfig.presets[index]
                    Button {
                        state.background.presetIndex = index
                        state.background.enabled = true
                    } label: {
                        RoundedRectangle(cornerRadius: 6)
                            .fill(LinearGradient(colors: colors.map { Color(nsColor: $0) },
                                                 startPoint: .topLeading, endPoint: .bottomTrailing))
                            .frame(width: 34, height: 26)
                            .overlay(
                                RoundedRectangle(cornerRadius: 6)
                                    .strokeBorder(state.background.presetIndex == index ? Color.white : Color.white.opacity(0.15),
                                                  lineWidth: state.background.presetIndex == index ? 2 : 1)
                            )
                    }
                    .buttonStyle(.plain)
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Padding").font(.system(size: 11)).foregroundStyle(.secondary)
                Slider(value: $state.background.padding, in: 16...160)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Corner radius").font(.system(size: 11)).foregroundStyle(.secondary)
                Slider(value: $state.background.cornerRadius, in: 0...32)
            }
            Toggle("Shadow", isOn: $state.background.shadow)
                .toggleStyle(.switch)
                .controlSize(.small)
        }
        .padding(16)
        .frame(width: 300)
    }
}
