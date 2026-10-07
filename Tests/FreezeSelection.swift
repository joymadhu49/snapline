import AppKit
import QuartzCore

@main
struct FreezeSelectionTest {
    static func require(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else { print("FAIL: \(message)"); exit(1) }
    }

    static func pixels(_ image: CGImage) -> [UInt8] {
        let context = CGContext(data: nil, width: image.width, height: image.height,
                                bitsPerComponent: 8, bytesPerRow: image.width * 4,
                                space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return Array(UnsafeBufferPointer(start: context.data!.assumingMemoryBound(to: UInt8.self),
                                        count: image.width * image.height * 4))
    }

    @MainActor static func main() async throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        if CommandLine.arguments.contains("--fixture") {
            await fixture()
            return
        }
        testCropGeometry()
        guard CGPreflightScreenCaptureAccess() else {
            print("SKIP: Screen Recording access is required for integration tests")
            exit(77)
        }
        // A separate process models a notification or video frame changing
        // underneath the selector. Snapline excludes its own windows.
        let child = Process()
        child.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
        child.arguments = ["--fixture"]
        let commands = Pipe(), events = Pipe()
        child.standardInput = commands
        child.standardOutput = events
        try child.run()
        defer { if child.isRunning { child.terminate() } }
        require(!events.fileHandleForReading.availableData.isEmpty, "fixture did not start")
        try await Task.sleep(nanoseconds: 150_000_000)

        let screen = NSScreen.screens[0]
        let region = CGRect(x: screen.frame.midX - 80, y: screen.frame.midY + 60, width: 160, height: 80)
        var delivered: SelectionResult?
        var completionCount = 0
        let controller = SelectionOverlayController(purpose: .still) {
            delivered = $0
            completionCount += 1
        }
        let start = Date()
        controller.begin()
        // The overlay goes up on the shortcut itself; the frozen frame lands under it.
        let overlayWindow = NSApp.windows.first { $0 is OverlayWindow && $0.isVisible && $0.screen == screen }
        require(overlayWindow != nil, "overlay did not appear immediately on the shortcut")
        print("Overlay visible in \(Int(Date().timeIntervalSince(start) * 1000)) ms")
        var window: NSWindow?
        for _ in 0..<200 {
            window = NSApp.windows.first { $0 is OverlayWindow && $0.isVisible && $0.screen == screen }
            if window?.contentView?.layer?.sublayers?.first?.contents != nil { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        guard let window, let view = window.contentView,
              let contents = view.layer?.sublayers?.first?.contents else {
            controller.finish(.cancelled)
            print("FAIL: selected area is live/transparent; no frozen screen was displayed")
            exit(1)
        }
        let original = contents as! CGImage
        print("Freeze ready in \(Int(Date().timeIntervalSince(start) * 1000)) ms")
        let expected = try FrozenDisplay(image: original, frame: screen.frame).crop(globalRect: region)
        let originalBytes = pixels(expected)
        require(originalBytes[0] > 200 && originalBytes[2] < 30, "fixture's initial red frame was not captured")

        commands.fileHandleForWriting.write(Data("change\n".utf8))
        require(!events.fileHandleForReading.availableData.isEmpty, "fixture did not change")
        try await Task.sleep(nanoseconds: 200_000_000)
        let local = CGRect(x: region.minX - screen.frame.minX, y: screen.frame.maxY - region.maxY,
                           width: region.width, height: region.height)
        let live = try await CaptureEngine.captureRect(local, on: screen)
        let liveBytes = pixels(live)
        require(liveBytes[2] > 200 && liveBytes[0] < 30, "live content must change to blue beneath the overlay")
        let stillDisplayed = view.layer!.sublayers!.first!.contents as! CGImage
        let displayedCrop = try FrozenDisplay(image: stillDisplayed, frame: screen.frame).crop(globalRect: region)
        require(pixels(displayedCrop) == originalBytes,
                "overlay changed with the live desktop")

        // The magnifier zooms the frozen frame, not the live desktop: parked
        // over the fixture it must still show red after the window went blue.
        if UserDefaults.standard.object(forKey: "showMagnifier") as? Bool ?? true {
            let pointer = CGPoint(x: region.midX, y: region.midY)
            controller.pointerMoved(to: pointer)
            CATransaction.flush()
            let loupeContext = CGContext(data: nil, width: Int(view.bounds.width), height: Int(view.bounds.height),
                                         bitsPerComponent: 8, bytesPerRow: 0,
                                         space: CGColorSpaceCreateDeviceRGB(),
                                         bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            view.layer!.render(in: loupeContext)
            let local = CGPoint(x: pointer.x - screen.frame.minX, y: pointer.y - screen.frame.minY)
            let center = CGPoint(x: local.x + 22 + 60, y: local.y - 22 - 60)
            let loupeBytes = loupeContext.data!.assumingMemoryBound(to: UInt8.self)
            let loupeOffset = (loupeContext.height - 1 - Int(center.y)) * loupeContext.bytesPerRow + Int(center.x) * 4
            require(loupeBytes[loupeOffset] > 200 && loupeBytes[loupeOffset + 2] < 30,
                    "magnifier does not show the frozen pixels under the pointer")
            print("PASS: magnifier shows the frozen pixels under the pointer")
        }

        controller.dragBegan(at: region.origin)
        controller.dragChanged(to: CGPoint(x: region.maxX, y: region.maxY))
        CATransaction.flush()
        let context = CGContext(data: nil, width: Int(view.bounds.width), height: Int(view.bounds.height),
                                bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        view.layer!.render(in: context)
        let bytes = context.data!.assumingMemoryBound(to: UInt8.self)
        let x = Int(region.midX - screen.frame.minX + 10)
        let y = Int(region.midY - screen.frame.minY + 10)
        let offset = y * context.bytesPerRow + x * 4
        require(bytes[offset + 3] == 255, "selected area is transparent")
        // Bitmap rows run from the top; AppKit and the layer use bottom left coordinates.
        let displayOffset = (context.height - 1 - y) * context.bytesPerRow + x * 4
        require(bytes[displayOffset] > 200 && bytes[displayOffset + 2] < 30,
                "displayed snapshot is flipped or moved relative to the selection")
        controller.dragEnded(in: window)
        guard case let .frozenRect(image, rect, _, scale) = delivered else {
            print("FAIL: selection did not deliver frozen pixels"); exit(1)
        }
        require(rect == region, "selection geometry changed")
        require(scale == CGFloat(original.width) / screen.frame.width, "incorrect output scale")
        require(pixels(image) == originalBytes, "saved crop must contain the original red frame, not the later blue frame")
        require(SelectionOverlayController.current == nil, "selection session leaked")
        controller.finish(.cancelled)
        require(completionCount == 1, "completion delivered twice")
        print("PASS: changing live content stays frozen on screen and in the saved crop")

        var cancellations = 0
        let cancelled = SelectionOverlayController(purpose: .still) { result in
            if case .cancelled = result { cancellations += 1 }
        }
        cancelled.begin()
        let duplicate = SelectionOverlayController(purpose: .still) { _ in
            require(false, "duplicate shortcut started a second selection")
        }
        duplicate.begin()
        require(SelectionOverlayController.current === cancelled, "duplicate replaced pending selection")
        cancelled.finish(.cancelled)
        try await Task.sleep(nanoseconds: 400_000_000)
        require(cancellations == 1 && SelectionOverlayController.current == nil, "pending cancellation failed")
        require(!NSApp.windows.contains { $0 is OverlayWindow && $0.isVisible }, "cancelled capture reopened its overlay")
        print("PASS: cancellation during preparation and repeated shortcuts")

        var ocrResult: SelectionResult?
        let ocr = SelectionOverlayController(purpose: .ocr) { ocrResult = $0 }
        ocr.begin()
        for _ in 0..<200 {
            if NSApp.windows.contains(where: { $0 is OverlayWindow && $0.isVisible }) { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        // Return uses this same full screen selection path.
        // Finishing before the frames land is allowed; delivery waits for them.
        ocr.finish(.rect(screen.frame, screen))
        for _ in 0..<200 where ocrResult == nil {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        require(!NSApp.windows.contains { $0 is OverlayWindow && $0.isVisible }, "overlay lingered after a fast release")
        guard case let .frozenRect(ocrImage, _, _, _) = ocrResult else {
            print("FAIL: OCR/full screen selection did not deliver frozen pixels"); exit(1)
        }
        require(ocrImage.width == original.width && ocrImage.height == original.height,
                "full screen frozen selection has incorrect dimensions")
        let changedDisplay = SelectionOverlayController(purpose: .still) { _ in }
        changedDisplay.begin()
        NotificationCenter.default.post(name: NSApplication.didChangeScreenParametersNotification, object: NSApp)
        require(SelectionOverlayController.current == nil, "display changes must cancel stale geometry")
        print("PASS: OCR, full screen selection and display changes")

        for purpose in [OverlayPurpose.record, .timed, .window] {
            let liveSelector = SelectionOverlayController(purpose: purpose) { _ in }
            liveSelector.begin()
            let liveView = NSApp.windows.first { $0 is OverlayWindow && $0.isVisible }!.contentView!
            require(liveView.layer?.sublayers?.first?.contents == nil, "live mode unexpectedly froze")
            liveSelector.finish(.cancelled)
        }
        print("PASS: recording, timer and dedicated window selection remain live")
    }

    static func testCropGeometry() {
        // Top row red, bottom row green. Image pixels have a top left origin;
        // display geometry is AppKit, and can have negative/offset origins.
        let data = Data([255, 0, 0, 255, 255, 0, 0, 255,
                         0, 255, 0, 255, 0, 255, 0, 255])
        let image = CGImage(width: 2, height: 2, bitsPerComponent: 8, bitsPerPixel: 32,
                            bytesPerRow: 8, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                            provider: CGDataProvider(data: data as CFData)!, decode: nil,
                            shouldInterpolate: false, intent: .defaultIntent)!
        for scale: CGFloat in [1, 2] {
            let frame = CGRect(x: -100, y: 300, width: 2 / scale, height: 2 / scale)
            let snapshot = FrozenDisplay(image: image, frame: frame)
            let top = try! snapshot.crop(globalRect: CGRect(x: -100, y: frame.maxY - 1 / scale,
                                                          width: 2 / scale, height: 1 / scale))
            require(top.width == 2 && top.height == 1 && pixels(top)[0] == 255, "top crop flipped or incorrectly scaled")
            let bottom = try! snapshot.crop(globalRect: CGRect(x: -100, y: 300, width: 2 / scale, height: 1 / scale))
            require(pixels(bottom)[1] == 255, "bottom crop flipped")
            let bounded = try! snapshot.crop(globalRect: frame.insetBy(dx: -20, dy: -20))
            require(bounded.width == 2 && bounded.height == 2, "cross display crop not bounded")
            do {
                _ = try snapshot.crop(globalRect: CGRect(x: 0, y: 0, width: 5, height: 5))
                require(false, "offscreen crop should fail")
            } catch {}
        }
        print("PASS: crop orientation, mixed scales, offset displays and bounds")
    }

    @MainActor static func fixture() async {
        let screen = NSScreen.screens[0]
        let window = NSWindow(contentRect: CGRect(x: screen.frame.midX - 120, y: screen.frame.midY + 20,
                                                  width: 240, height: 160),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.backgroundColor = .red
        window.level = .floating
        window.isReleasedWhenClosed = false
        window.orderFrontRegardless()
        print("ready"); fflush(stdout)
        DispatchQueue.global().async {
            _ = readLine()
            DispatchQueue.main.async {
                window.backgroundColor = .blue
                print("changed"); fflush(stdout)
            }
        }
        let parent = getppid()
        while getppid() == parent { try? await Task.sleep(nanoseconds: 200_000_000) }
    }
}
