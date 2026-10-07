import AppKit

/// A floating always on top screenshot reference window.
/// Drag anywhere to move, resize from edges, scroll to change opacity, double click to close.
final class PinWindowController {
    private static var controllers: [PinWindowController] = []

    private let window: PinWindow

    static func pin(cgImage: CGImage, scale: CGFloat) {
        let nsImage = NSImage(cgImage: cgImage,
                              size: NSSize(width: CGFloat(cgImage.width) / scale,
                                           height: CGFloat(cgImage.height) / scale))
        pin(nsImage: nsImage)
    }

    static func pin(nsImage: NSImage) {
        let controller = PinWindowController(image: nsImage)
        controllers.append(controller)
        controller.window.makeKeyAndOrderFront(nil)
    }

    static func closeAll() {
        controllers.forEach { $0.window.orderOut(nil) }
        controllers.removeAll()
    }

    private init(image: NSImage) {
        let screen = NSScreen.main ?? NSScreen.screens[0]
        var size = image.size
        let maxSide = min(screen.visibleFrame.width, screen.visibleFrame.height) * 0.6
        if size.width > maxSide || size.height > maxSide {
            let ratio = min(maxSide / size.width, maxSide / size.height)
            size = NSSize(width: size.width * ratio, height: size.height * ratio)
        }
        let origin = NSPoint(x: screen.visibleFrame.midX - size.width / 2,
                             y: screen.visibleFrame.midY - size.height / 2)
        window = PinWindow(contentRect: NSRect(origin: origin, size: size), image: image)
        window.onClose = { [weak self] in
            guard let self else { return }
            PinWindowController.controllers.removeAll { $0 === self }
        }
    }
}

final class PinWindow: NSWindow {
    var onClose: (() -> Void)?

    init(contentRect: NSRect, image: NSImage) {
        super.init(contentRect: contentRect,
                   styleMask: [.borderless, .resizable],
                   backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isMovableByWindowBackground = true
        isReleasedWhenClosed = false
        contentAspectRatio = contentRect.size
        minSize = NSSize(width: 80, height: 60)

        let view = PinImageView(frame: NSRect(origin: .zero, size: contentRect.size))
        view.image = image
        view.pinWindow = self
        contentView = view
    }

    override var canBecomeKey: Bool { true }

    func closePin() {
        orderOut(nil)
        onClose?()
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 || (event.modifierFlags.contains(.command) && event.charactersIgnoringModifiers == "w") {
            closePin()
        } else {
            super.keyDown(with: event)
        }
    }
}

private final class PinImageView: NSView {
    var image: NSImage? { didSet { needsDisplay = true } }
    weak var pinWindow: PinWindow?

    override func draw(_ dirtyRect: NSRect) {
        guard let image else { return }
        let path = NSBezierPath(roundedRect: bounds, xRadius: 9, yRadius: 9)
        path.addClip()
        image.draw(in: bounds, from: .zero, operation: .sourceOver, fraction: 1)
        NSColor.white.withAlphaComponent(0.18).setStroke()
        let border = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 8.5, yRadius: 8.5)
        border.lineWidth = 1
        border.stroke()
    }

    override func scrollWheel(with event: NSEvent) {
        guard let window = pinWindow else { return }
        let delta = event.deltaY * 0.02
        window.alphaValue = min(1, max(0.25, window.alphaValue + delta))
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            pinWindow?.closePin()
        } else {
            super.mouseDown(with: event)
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        menu.addItem(withTitle: "Copy", action: #selector(copyImage), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Save", action: #selector(saveImage), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Close Pin", action: #selector(closePin), keyEquivalent: "").target = self
        return menu
    }

    @objc private func copyImage() {
        guard let image else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([image])
    }

    @objc private func saveImage() {
        guard let image, let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let cg = rep.cgImage else { return }
        let scale = image.size.width > 0 ? CGFloat(cg.width) / image.size.width : 1
        if let url = ImageWriter.save(cg, scale: scale) {
            HistoryStore.shared.add(url)
            Toast.show("Pin saved")
        }
    }

    @objc private func closePin() {
        pinWindow?.closePin()
    }
}
