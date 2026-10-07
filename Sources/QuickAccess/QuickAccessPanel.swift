import AppKit
import SwiftUI
import AVFoundation
import ImageIO

/// Manages the stack of floating quick access cards in the bottom left corner.
/// The newest capture is always the top card. The card whose content currently
/// sits on the clipboard shows an "On clipboard" chip; clicking any thumbnail
/// copies that capture again.
final class QuickAccessCenter {
    static let shared = QuickAccessCenter()

    private var panels: [QuickAccessPanel] = []
    /// The display the whole stack sits on. It starts where the pointer is and
    /// then follows the pointer between displays, so the cards are always at
    /// hand to drag into an app on the display being worked on.
    private var anchorScreen: NSScreen?
    private var followTimer: Timer?
    private var pendingScreen: NSScreen?
    private var pendingSince = Date.distantPast
    private let margin: CGFloat = 18
    private let spacing: CGFloat = 12

    /// How many cards the stack may hold: the Settings choice, but never more
    /// than physically fit between the bottom margin and the top of the screen.
    /// 0 in Settings means "as many as fit".
    private var maxPanels: Int {
        let chosen = SettingsStore.shared.overlayMaxCards
        let fit = fitCount()
        return chosen <= 0 ? fit : min(chosen, fit)
    }

    private func fitCount() -> Int {
        guard let screen = anchorScreen ?? NSScreen.main ?? NSScreen.screens.first else { return 4 }
        let available = screen.visibleFrame.height - margin * 2
        let card = QuickAccessPanel.cardSize.height
        guard available >= card else { return 1 }
        return max(1, Int((available - card) / (card + spacing)) + 1)
    }

    private(set) var clipboardOwner: UUID?

    func markClipboardOwner(_ id: UUID?) {
        clipboardOwner = id
        NotificationCenter.default.post(name: .snaplineClipboardOwnerChanged, object: nil)
    }

    func show(capture: Capture, copiedToClipboard: Bool, thumbnail: CGImage? = nil) {
        let panel = QuickAccessPanel(content: .image(capture), thumbnail: thumbnail)
        addPanel(panel)
        if copiedToClipboard {
            markClipboardOwner(panel.id)
        }
    }

    func showVideo(url: URL) {
        addPanel(QuickAccessPanel(content: .video(url)))
    }

    /// An edited capture takes over the card that stood for the original file,
    /// so the overlay always shows what the file now contains and a drag out
    /// of the card carries the edits with it.
    func showEdited(_ capture: Capture) {
        if let url = capture.fileURL ?? capture.savedURL,
           let existing = panels.first(where: { $0.matches(url) }) {
            existing.orderOut(nil)
            panels.removeAll { $0 === existing }
        }
        show(capture: capture, copiedToClipboard: true)
    }

    /// Brings a capture from the history back as a floating card, so an older
    /// shot can be worked with exactly like one that was just taken. A capture
    /// that is already on the overlay is pulsed rather than stacked twice.
    func restore(url: URL) {
        if let existing = panels.first(where: { $0.matches(url) }) {
            existing.flash()
            return
        }
        switch url.pathExtension.lowercased() {
        case "mp4", "mov":
            showVideo(url: url)
        default:
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
                Toast.show("Could not open that capture")
                return
            }
            var scale: CGFloat = 1
            if let rep = NSImage(contentsOf: url)?.representations.first, rep.size.width > 0 {
                scale = CGFloat(image.width) / rep.size.width
            }
            show(capture: Capture(image: image, scale: max(1, scale), savedURL: url, fileURL: url),
                 copiedToClipboard: false)
        }
    }

    private func addPanel(_ panel: QuickAccessPanel) {
        if panels.isEmpty {
            let mouse = NSEvent.mouseLocation
            anchorScreen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        }
        panel.center = self
        panels.append(panel)
        startFollowingPointer()
        while panels.count > maxPanels {
            let oldest = panels.removeFirst()
            oldest.orderOut(nil)
        }
        layout(animated: true)

        // Slides in from beyond the screen edge, the way CleanShot's overlay
        // does, so a new capture reads as arriving rather than blinking in.
        let target = panel.frame.origin
        panel.setFrameOrigin(NSPoint(x: target.x - panel.frame.width - margin, y: target.y))
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.3
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.25, 1)
            panel.animator().alphaValue = 1
            // NSWindow only animates its frame through setFrame, not setFrameOrigin.
            panel.animator().setFrame(NSRect(origin: target, size: panel.frame.size), display: true)
        }
    }

    /// The card itself scales and fades out in SwiftUI first; by the time this
    /// runs there is nothing left to see, so it drops the window and glides the
    /// rest of the stack down into the gap.
    func remove(_ panel: QuickAccessPanel) {
        guard panels.contains(where: { $0 === panel }) else { return }
        panels.removeAll { $0 === panel }
        if clipboardOwner == panel.id {
            markClipboardOwner(nil)
        }
        if panels.isEmpty {
            anchorScreen = nil
            stopFollowingPointer()
        }
        panel.orderOut(nil)
        layout(animated: true)
    }

    // MARK: Following the pointer across displays

    /// Checks which display the pointer is on a few times a second while any
    /// card is up; cheap, and it needs no event monitoring permissions.
    private func startFollowingPointer() {
        guard followTimer == nil else { return }
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in self?.followPointer() }
        timer.tolerance = 0.05
        RunLoop.main.add(timer, forMode: .common)
        followTimer = timer
    }

    private func stopFollowingPointer() {
        followTimer?.invalidate()
        followTimer = nil
        pendingScreen = nil
    }

    /// Moves the stack once the pointer has settled on another display for a
    /// moment, so just passing through does not make it jump. Never while a
    /// button is held: dragging a card over to an app on the other display
    /// must not pull the stack away from under the drag.
    private func followPointer() {
        guard !panels.isEmpty, NSEvent.pressedMouseButtons == 0 else {
            pendingScreen = nil
            return
        }
        let mouse = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }),
              screen != anchorScreen else {
            pendingScreen = nil
            return
        }
        if pendingScreen != screen {
            pendingScreen = screen
            pendingSince = Date()
            return
        }
        guard Date().timeIntervalSince(pendingSince) >= 0.25 else { return }
        pendingScreen = nil
        moveStack(to: screen)
    }

    /// Fades the cards out, then lets them rise into the same corner of the new display.
    private func moveStack(to screen: NSScreen) {
        anchorScreen = screen
        let moving = panels
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.12
            moving.forEach { $0.animator().alphaValue = 0 }
        }, completionHandler: { [weak self] in
            guard let self else { return }
            self.layout()
            for panel in moving where self.panels.contains(where: { $0 === panel }) {
                let target = panel.frame
                panel.setFrameOrigin(NSPoint(x: target.minX, y: target.minY - 16))
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.26
                    context.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.25, 1)
                    panel.animator().alphaValue = 1
                    panel.animator().setFrame(target, display: true)
                }
            }
        })
    }

    /// Oldest card sits at the bottom, the newest capture ends up on top of the stack.
    func layout(animated: Bool = false) {
        guard let screen = anchorScreen ?? NSScreen.main ?? NSScreen.screens.first else { return }
        var y = screen.visibleFrame.minY + margin
        for panel in panels {
            let origin = NSPoint(x: screen.visibleFrame.minX + margin, y: y)
            if animated, panel.isVisible {
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.22
                    context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                    panel.animator().setFrame(NSRect(origin: origin, size: panel.frame.size), display: true)
                }
            } else {
                panel.setFrameOrigin(origin)
            }
            y += panel.frame.size.height + spacing
        }
    }
}

enum QAContent {
    case image(Capture)
    case video(URL)
}

final class QuickAccessPanel: NSPanel {
    let id = UUID()
    weak var center: QuickAccessCenter?
    /// The file this card stands for, used to keep one capture to one card.
    private(set) var sourceURL: URL?

    /// One size for every card. A stack of cards that each took the shape of
    /// their capture looked ragged, so the shot fills a fixed tile instead.
    /// Settings > General > "Overlay size"; medium matches CleanShot's default
    /// footprint, the old 260 point card is roughly large.
    static var cardSize: CGSize {
        switch UserDefaults.standard.string(forKey: "overlaySize") ?? "medium" {
        case "small": return CGSize(width: 168, height: 105)
        case "large": return CGSize(width: 248, height: 155)
        default: return CGSize(width: 200, height: 125)
        }
    }

    init(content: QAContent, thumbnail: CGImage? = nil) {
        let size = QuickAccessPanel.cardSize
        super.init(contentRect: NSRect(origin: .zero, size: size),
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isReleasedWhenClosed = false
        // Dragging the card has to carry the capture out to another app, so the
        // window must not swallow the gesture to move itself.
        isMovableByWindowBackground = false

        switch content {
        case .image(let capture): sourceURL = capture.fileURL ?? capture.savedURL
        case .video(let url): sourceURL = url
        }

        let hosting = NSHostingView(rootView: QuickAccessCard(content: content, thumbnail: thumbnail, panel: self))
        hosting.frame = NSRect(origin: .zero, size: size)
        hosting.autoresizingMask = [.width, .height]
        contentView = hosting
    }

    func matches(_ url: URL) -> Bool {
        sourceURL?.standardizedFileURL == url.standardizedFileURL
    }

    /// Draws the eye to a card that is already on screen instead of adding a
    /// second copy of the same capture.
    func flash() {
        orderFrontRegardless()
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.12
            animator().alphaValue = 0.35
        }, completionHandler: { [weak self] in
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.18
                self?.animator().alphaValue = 1
            }
        })
    }

    func dismiss() {
        center?.remove(self)
    }

    override var canBecomeKey: Bool { false }
}

private struct QuickAccessCard: View {
    let content: QAContent
    weak var panel: QuickAccessPanel?

    @State private var hovering = false
    @State private var savedURL: URL?
    @State private var copied = false
    @State private var gifState: GifState = .idle
    @State private var thumbnail: NSImage?
    @State private var ownsClipboard = false
    @State private var dragHandle = DragOutHandle()
    @State private var leaving = false

    enum GifState { case idle, working, done }

    init(content: QAContent, thumbnail prepared: CGImage?, panel: QuickAccessPanel?) {
        self.content = content
        self.panel = panel
        if case .image(let capture) = content {
            // A card-sized bitmap, not the full capture: the card only ever
            // shows 260 points of it, and the full frame costs GPU upload time
            // right while the card is sliding in.
            let small = prepared ?? ImageWriter.thumbnail(for: capture.image, covering: QuickAccessPanel.cardSize)
            // Downsampled bitmaps are 2x; one left at full size keeps the capture's own scale.
            let factor = small === capture.image ? max(1, capture.scale) : 2
            _thumbnail = State(initialValue: NSImage(cgImage: small,
                                                     size: NSSize(width: CGFloat(small.width) / factor,
                                                                  height: CGFloat(small.height) / factor)))
        }
    }

    static let radius: CGFloat = 10
    /// Fixed when the card is made, so a Settings change only affects new cards.
    private let size = QuickAccessPanel.cardSize

    private var isVideo: Bool {
        if case .video = content { return true }
        return false
    }

    var body: some View {
        ZStack {
            artwork
                .contentShape(Rectangle())
                .onTapGesture { restoreToClipboard() }
                .dragOut(dragHandle) {
                    DragPayload(fileURL: { fileURL() }, preview: { thumbnail },
                                onDropCompleted: { close() })
                }
                .help("Click to copy, drag into any app or terminal")

            if hovering {
                // The shot dims so the white controls read on any capture.
                Color.black.opacity(0.42)
                    .clipShape(RoundedRectangle(cornerRadius: QuickAccessCard.radius))
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }

            chrome
        }
        .frame(width: size.width, height: size.height)
        .scaleEffect(leaving ? 0.84 : 1)
        .opacity(leaving ? 0 : 1)
        .environment(\.colorScheme, .dark)
        .onHover { setHovering($0) }
        .onAppear {
            loadVideoThumbnail()
            refreshOwnership()
        }
        .onReceive(NotificationCenter.default.publisher(for: .snaplineClipboardOwnerChanged)) { _ in
            refreshOwnership()
        }
    }

    private func setHovering(_ inside: Bool) {
        withAnimation(.easeOut(duration: 0.12)) { hovering = inside }
        // The window shadow traces the visible pixels, so it has to be recomputed
        // whenever the hover chrome changes the card's silhouette.
        DispatchQueue.main.async { panel?.invalidateShadow() }
    }

    /// Shrinks and fades the card away before the window goes, so closing it
    /// reads as the capture leaving rather than the overlay blinking out. The
    /// window shadow goes first, otherwise it hangs around the empty space.
    private func close() {
        guard !leaving else { return }
        panel?.hasShadow = false
        panel?.invalidateShadow()
        withAnimation(.easeIn(duration: 0.19)) { leaving = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.19) { panel?.dismiss() }
    }

    private func refreshOwnership() {
        ownsClipboard = QuickAccessCenter.shared.clipboardOwner == panel?.id
    }

    // MARK: Artwork

    /// The capture is the card: it fills a fixed tile, with a hairline edge so
    /// a light shot does not dissolve into a light desktop, and the window
    /// shadow separating it from whatever is behind.
    private var artwork: some View {
        ZStack {
            Color.black.opacity(0.45)

            if let thumbnail {
                Image(nsImage: thumbnail)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            }

            if isVideo && !hovering {
                Image(systemName: "play.circle.fill")
                    .font(.system(size: 24))
                    .foregroundStyle(.white.opacity(0.92), .black.opacity(0.35))
            }
        }
        .frame(width: size.width, height: size.height)
        .clipShape(RoundedRectangle(cornerRadius: QuickAccessCard.radius))
        .overlay(
            RoundedRectangle(cornerRadius: QuickAccessCard.radius)
                .strokeBorder(Color.white.opacity(0.14), lineWidth: 0.5)
        )
    }

    // MARK: Hover chrome

    /// CleanShot's layout: the two things you do most, Copy and Save, as
    /// labelled buttons in the middle, and the rest as small round buttons
    /// tucked into the corners, all only while the pointer is over the card.
    private var chrome: some View {
        ZStack {
            if hovering {
                centerActions.transition(.opacity)
                corners.transition(.opacity)
            } else if ownsClipboard || copied {
                VStack {
                    HStack {
                        chip(copied ? "Copied" : "On clipboard")
                        Spacer(minLength: 0)
                    }
                    Spacer(minLength: 0)
                }
                .padding(6)
                .allowsHitTesting(false)
                .transition(.opacity)
            }
        }
    }

    @ViewBuilder
    private var centerActions: some View {
        VStack(spacing: 6) {
            switch content {
            case .image(let capture):
                actionPill(copied ? "Copied" : "Copy") { restoreToClipboard() }
                actionPill(isSaved ? "Show in Finder" : "Save") {
                    if let url = capture.savedURL ?? savedURL {
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    } else if let url = ImageWriter.save(capture.image, scale: capture.scale) {
                        savedURL = url
                        HistoryStore.shared.add(url)
                        Toast.show("Saved")
                    }
                }
            case .video(let url):
                actionPill(copied ? "Copied" : "Copy") { restoreToClipboard() }
                if GIFExporter.isAvailable {
                    actionPill(gifState == .working ? "Exporting…" : gifState == .done ? "GIF Saved" : "Save as GIF") {
                        guard gifState == .idle else { return }
                        gifState = .working
                        GIFExporter.export(mp4URL: url) { gifURL in
                            gifState = gifURL == nil ? .idle : .done
                            if let gifURL {
                                HistoryStore.shared.add(gifURL)
                                Toast.show("GIF saved")
                            }
                        }
                    }
                }
                actionPill("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            }
        }
    }

    private var corners: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                cornerButton("xmark", help: "Close") { close() }
                Spacer(minLength: 0)
                if case .image(let capture) = content {
                    cornerButton("pin.fill", help: "Pin to screen") {
                        PinWindowController.pin(cgImage: capture.image, scale: capture.scale)
                        close()
                    }
                }
            }
            Spacer(minLength: 0)
            HStack(spacing: 0) {
                switch content {
                case .image(let capture):
                    cornerButton("pencil", help: "Annotate") {
                        EditorWindowController.open(capture: Capture(image: capture.image,
                                                                     scale: capture.scale,
                                                                     savedURL: capture.savedURL ?? savedURL,
                                                                     fileURL: fileURL()))
                        close()
                    }
                case .video(let url):
                    cornerButton("play.fill", help: "Play") { NSWorkspace.shared.open(url) }
                }
                Spacer(minLength: 0)
            }
        }
        .padding(6)
    }

    private var isSaved: Bool {
        if case .image(let capture) = content { return capture.savedURL != nil || savedURL != nil }
        return true
    }

    private func actionPill(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            // One width for every pill, so the stack reads as a single block
            // instead of a ragged pair; it narrows with the small card size.
            Text(title)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(Color.black.opacity(0.86))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .padding(.horizontal, 8)
                .frame(width: min(108, size.width - 68), height: 24)
                .background(Capsule().fill(Color.white.opacity(0.95)))
                .shadow(color: .black.opacity(0.22), radius: 3, y: 1)
                .contentShape(Capsule())
        }
        .buttonStyle(PressableButtonStyle())
    }

    private func cornerButton(_ system: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: system)
                .font(.system(size: 9.5, weight: .bold))
                .foregroundStyle(Color.black.opacity(0.8))
                .frame(width: 22, height: 22)
                .background(Circle().fill(Color.white.opacity(0.95)))
                .shadow(color: .black.opacity(0.22), radius: 2, y: 1)
                .contentShape(Circle())
        }
        .buttonStyle(PressableButtonStyle())
        .help(help)
    }

    /// Neutral glass rather than a coloured badge, so the chip never competes
    /// with the capture underneath it.
    private func chip(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 9.5, weight: .semibold))
            .foregroundStyle(.white.opacity(0.95))
            .padding(.horizontal, 7)
            .padding(.vertical, 3.5)
            .background(Capsule().fill(.ultraThinMaterial))
            .background(Capsule().fill(Color.black.opacity(0.45)))
    }

    // MARK: Actions

    private func restoreToClipboard() {
        switch content {
        case .image(let capture):
            ImageWriter.copyToClipboard(capture.image, scale: capture.scale, fileURL: fileURL())
        case .video(let url):
            ImageWriter.copyFileToClipboard(url)
        }
        QuickAccessCenter.shared.markClipboardOwner(panel?.id)
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { copied = false }
    }

    /// The path this card hands to a drag or a paste. Captures always have one
    /// by the time the card appears; this only re-creates a file that was moved.
    private func fileURL() -> URL? {
        switch content {
        case .video(let url):
            return url
        case .image(let capture):
            // A drag in the first instant after a capture can beat the background write.
            ImageWriter.waitForPendingWrites()
            for candidate in [capture.fileURL, capture.savedURL, savedURL] {
                if let candidate, FileManager.default.fileExists(atPath: candidate.path) { return candidate }
            }
            return ImageWriter.persistentFile(for: capture.image, scale: capture.scale)
        }
    }

    private func loadVideoThumbnail() {
        guard case .video(let url) = content, thumbnail == nil else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 720, height: 720)
            let cg = try? generator.copyCGImage(at: .zero, actualTime: nil)
            DispatchQueue.main.async {
                guard let cg else { return }
                thumbnail = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
            }
        }
    }
}

extension Notification.Name {
    static let snaplineClipboardOwnerChanged = Notification.Name("snaplineClipboardOwnerChanged")
}

/// A quick squeeze on press, so the overlay's buttons feel physical.
private struct PressableButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.93 : 1)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }
}
