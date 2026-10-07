import AppKit

/// Large centered countdown before timed captures and recordings.
final class CountdownHUD {
    private var window: NSWindow?
    private var remaining: Int
    private let screen: NSScreen
    private let onFinish: () -> Void
    private var timer: Timer?
    private let label = NSTextField(labelWithString: "")

    init(seconds: Int, on screen: NSScreen, onFinish: @escaping () -> Void) {
        self.remaining = max(1, seconds)
        self.screen = screen
        self.onFinish = onFinish
    }

    func start() {
        let size: CGFloat = 140
        let rect = NSRect(x: screen.frame.midX - size / 2,
                          y: screen.frame.midY - size / 2,
                          width: size, height: size)
        let window = NSWindow(contentRect: rect, styleMask: .borderless, backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.level = .screenSaver
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.isReleasedWhenClosed = false

        let container = NSView(frame: NSRect(origin: .zero, size: rect.size))
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.72).cgColor
        container.layer?.cornerRadius = 28

        label.font = NSFont.monospacedDigitSystemFont(ofSize: 64, weight: .semibold)
        label.textColor = .white
        label.alignment = .center
        label.stringValue = "\(remaining)"
        label.frame = NSRect(x: 0, y: (size - 80) / 2, width: size, height: 80)
        container.addSubview(label)

        window.contentView = container
        window.orderFrontRegardless()
        self.window = window

        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// Stops the countdown without firing the completion.
    func cancel() {
        timer?.invalidate()
        timer = nil
        window?.orderOut(nil)
        window = nil
    }

    private func tick() {
        remaining -= 1
        if remaining <= 0 {
            timer?.invalidate()
            timer = nil
            window?.orderOut(nil)
            window = nil
            // Let the HUD leave the screen before the capture fires.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [onFinish] in
                onFinish()
            }
        } else {
            label.stringValue = "\(remaining)"
        }
    }
}

/// Small transient confirmation pill near the bottom of the screen.
enum Toast {
    static func show(_ message: String, on screen: NSScreen? = nil) {
        let screen = screen ?? NSScreen.main ?? NSScreen.screens.first!
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: .medium),
            .foregroundColor: NSColor.white
        ]
        let size = message.size(withAttributes: attributes)
        let width = size.width + 36
        let height: CGFloat = 36
        let rect = NSRect(x: screen.frame.midX - width / 2,
                          y: screen.frame.minY + 120,
                          width: width, height: height)
        let window = NSWindow(contentRect: rect, styleMask: .borderless, backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.level = .screenSaver
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.isReleasedWhenClosed = false

        let container = NSView(frame: NSRect(origin: .zero, size: rect.size))
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.78).cgColor
        container.layer?.cornerRadius = height / 2

        let label = NSTextField(labelWithString: message)
        label.font = attributes[.font] as? NSFont
        label.textColor = .white
        label.alignment = .center
        label.frame = NSRect(x: 0, y: (height - size.height) / 2 - 1, width: width, height: size.height + 2)
        container.addSubview(label)
        window.contentView = container
        window.orderFrontRegardless()

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.25
                window.animator().alphaValue = 0
            }, completionHandler: {
                window.orderOut(nil)
            })
        }
    }
}
