import AppKit
import ScreenCaptureKit

enum CaptureError: Error, LocalizedError {
    case permissionDenied
    case displayNotFound
    case windowNotFound
    case captureFailed

    var errorDescription: String? {
        switch self {
        case .permissionDenied: return "Screen recording permission is required."
        case .displayNotFound: return "The display could not be found."
        case .windowNotFound: return "The window could not be found."
        case .captureFailed: return "The capture failed."
        }
    }
}

/// Pixels and display geometry captured together before selection starts.
struct FrozenDisplay {
    let image: CGImage
    let frame: CGRect

    var scale: CGFloat { CGFloat(image.width) / frame.width }

    func crop(globalRect: CGRect) throws -> CGImage {
        let local = globalRect.intersection(frame)
        guard !local.isNull, !local.isEmpty else { throw CaptureError.captureFailed }
        // Use actual bitmap dimensions, including displays with different scales.
        let scaleY = CGFloat(image.height) / frame.height
        let pixels = CGRect(x: (local.minX - frame.minX) * scale,
                            y: (frame.maxY - local.maxY) * scaleY,
                            width: local.width * scale, height: local.height * scaleY).integral
        let bounded = pixels.intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard !bounded.isEmpty, let crop = image.cropping(to: bounded) else {
            throw CaptureError.captureFailed
        }
        return crop
    }
}

/// Still image capture through ScreenCaptureKit.
enum CaptureEngine {

    static func ensurePermission() -> Bool {
        if CGPreflightScreenCaptureAccess() { return true }
        CGRequestScreenCaptureAccess()
        DispatchQueue.main.async { showPermissionAlert() }
        return false
    }

    private static func showPermissionAlert() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Allow Screen Recording"
        alert.informativeText = "Snapline needs Screen Recording access to capture your screen. Enable Snapline in System Settings, then relaunch the app."
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Later")
        if alert.runModal() == .alertFirstButtonReturn {
            let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
            NSWorkspace.shared.open(url)
        }
    }

    static func shareableContent() async throws -> SCShareableContent {
        try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
    }

    static func scDisplay(for screen: NSScreen, in content: SCShareableContent) -> SCDisplay? {
        guard let screenNumber = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            return nil
        }
        return content.displays.first { $0.displayID == CGDirectDisplayID(screenNumber.uint32Value) }
    }

    /// Captures a full display at native pixel resolution, excluding Snapline's own
    /// floating UI (quick access cards, pins, toasts) from the result.
    static func captureDisplay(_ screen: NSScreen, showCursor: Bool = false) async throws -> CGImage {
        let content = try await shareableContent()
        return try await captureDisplay(screen, in: content, showCursor: showCursor)
    }

    /// Discover content once and request all displays concurrently, before any
    /// overlay windows exist. No stream or continuous background recording is kept.
    static func freezeDisplays(_ screens: [NSScreen]) async throws -> [NSScreen: FrozenDisplay] {
        let content = try await shareableContent()
        return try await withThrowingTaskGroup(of: (Int, FrozenDisplay).self) { group in
            for (index, screen) in screens.enumerated() {
                guard let display = scDisplay(for: screen, in: content) else { throw CaptureError.displayNotFound }
                let frame = screen.frame
                let scale = screen.backingScaleFactor
                group.addTask {
                    let image = try await captureDisplay(display, scale: scale, in: content, showCursor: false)
                    return (index, FrozenDisplay(image: image, frame: frame))
                }
            }
            var result: [NSScreen: FrozenDisplay] = [:]
            for try await (index, snapshot) in group { result[screens[index]] = snapshot }
            return result
        }
    }

    private static func captureDisplay(_ screen: NSScreen, in content: SCShareableContent,
                                       showCursor: Bool) async throws -> CGImage {
        guard let display = scDisplay(for: screen, in: content) else { throw CaptureError.displayNotFound }
        return try await captureDisplay(display, scale: screen.backingScaleFactor, in: content, showCursor: showCursor)
    }

    /// The selection overlay is already on screen while the display freezes, so
    /// Snapline's own windows must never be in the frame. Excluding the app also
    /// covers windows opened after the content list was taken; the per window
    /// list is the fallback if the app entry is ever missing.
    private static func excludingSelf(_ display: SCDisplay, in content: SCShareableContent) -> SCContentFilter {
        let myPID = ProcessInfo.processInfo.processIdentifier
        if let myApp = content.applications.first(where: { $0.processID == myPID }) {
            return SCContentFilter(display: display, excludingApplications: [myApp], exceptingWindows: [])
        }
        let mine = content.windows.filter { $0.owningApplication?.processID == myPID }
        return SCContentFilter(display: display, excludingWindows: mine)
    }

    /// The first ScreenCaptureKit screenshot after launch costs several times a
    /// warm one while the framework spins up. A throwaway tiny capture at launch
    /// moves that cost out of the first real shortcut press.
    static func prewarm() {
        guard CGPreflightScreenCaptureAccess() else { return }
        Task.detached(priority: .utility) {
            guard let content = try? await shareableContent(), let display = content.displays.first else { return }
            let config = SCStreamConfiguration()
            config.width = 16
            config.height = 16
            config.showsCursor = false
            _ = try? await SCScreenshotManager.captureImage(contentFilter: excludingSelf(display, in: content),
                                                            configuration: config)
        }
    }

    private static func captureDisplay(_ display: SCDisplay, scale: CGFloat, in content: SCShareableContent,
                                       showCursor: Bool) async throws -> CGImage {
        let filter = excludingSelf(display, in: content)
        let config = SCStreamConfiguration()
        config.width = Int(CGFloat(display.width) * scale)
        config.height = Int(CGFloat(display.height) * scale)
        config.showsCursor = showCursor
        config.captureResolution = .best
        guard let image = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config) else {
            throw CaptureError.captureFailed
        }
        return image
    }

    /// Captures a rectangle given in that screen's local top left origin point space.
    static func captureRect(_ rectInScreen: CGRect, on screen: NSScreen, showCursor: Bool = false) async throws -> CGImage {
        let full = try await captureDisplay(screen, showCursor: showCursor)
        let scale = screen.backingScaleFactor
        let pixelRect = CGRect(x: rectInScreen.origin.x * scale,
                               y: rectInScreen.origin.y * scale,
                               width: rectInScreen.width * scale,
                               height: rectInScreen.height * scale).integral
        let bounded = pixelRect.intersection(CGRect(x: 0, y: 0, width: full.width, height: full.height))
        guard !bounded.isEmpty, let cropped = full.cropping(to: bounded) else { throw CaptureError.captureFailed }
        return cropped
    }

    /// Captures a single window cleanly, independent of overlap, without the system shadow.
    static func captureWindow(windowID: CGWindowID) async throws -> CGImage {
        let content = try await shareableContent()
        guard let window = content.windows.first(where: { $0.windowID == windowID }) else {
            throw CaptureError.windowNotFound
        }
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let config = SCStreamConfiguration()
        let scale = NSScreen.screens.first(where: { $0.frame.intersects(flipped(window.frame)) })?.backingScaleFactor
            ?? NSScreen.main?.backingScaleFactor ?? 2
        config.width = Int(window.frame.width * scale)
        config.height = Int(window.frame.height * scale)
        config.showsCursor = false
        config.captureResolution = .best
        config.ignoreShadowsSingleWindow = true
        config.backgroundColor = .clear
        guard let image = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config) else {
            throw CaptureError.captureFailed
        }
        return image
    }

    /// Converts a CG top left origin global rect to AppKit bottom left origin space.
    static func flipped(_ cgRect: CGRect) -> CGRect {
        guard let primary = NSScreen.screens.first else { return cgRect }
        return CGRect(x: cgRect.origin.x,
                      y: primary.frame.maxY - cgRect.origin.y - cgRect.height,
                      width: cgRect.width,
                      height: cgRect.height)
    }

    /// Draws a soft drop shadow behind a window image on a transparent canvas.
    static func addShadow(to image: CGImage) -> CGImage {
        let margin = 60
        let width = image.width + margin * 2
        let height = image.height + margin * 2
        guard let context = CGContext(data: nil, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return image
        }
        context.setShadow(offset: CGSize(width: 0, height: -14),
                          blur: 36,
                          color: CGColor(red: 0, green: 0, blue: 0, alpha: 0.45))
        context.draw(image, in: CGRect(x: margin, y: margin, width: image.width, height: image.height))
        return context.makeImage() ?? image
    }
}
