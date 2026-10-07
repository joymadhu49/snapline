import AppKit

/// A finished still capture ready for delivery.
struct Capture {
    var image: CGImage
    var scale: CGFloat
    /// Set only when the capture was written to the user's capture folder.
    var savedURL: URL?
    /// A file that exists on disk right now, saved folder or internal cache.
    /// Drag out and paste as path both rely on this never being nil.
    var fileURL: URL?
}

/// Central orchestrator for every capture flow.
final class CaptureCoordinator {
    static let shared = CaptureCoordinator()

    private var countdown: CountdownHUD?

    /// A capture hotkey during a running countdown cancels it instead of stacking flows.
    private func cancelCountdownIfRunning() -> Bool {
        guard let countdown else { return false }
        countdown.cancel()
        self.countdown = nil
        Toast.show("Countdown canceled")
        return true
    }

    // MARK: Action dispatch

    func perform(_ action: ActionID) {
        switch action {
        case .captureArea: captureArea()
        case .captureFullscreen: captureFullscreen()
        case .captureWindow: captureWindow()
        case .capturePreviousArea: capturePreviousArea()
        case .captureText: captureText()
        case .toggleRecording: toggleRecording()
        case .pinFromClipboard: pinFromClipboard()
        case .showHistory: HistoryPanelController.shared.toggle()
        }
    }

    // MARK: Still captures

    func captureArea() {
        guard !cancelCountdownIfRunning() else { return }
        guard CaptureEngine.ensurePermission() else { return }
        guard SelectionOverlayController.current == nil else { return }
        let controller = SelectionOverlayController(purpose: .still) { [weak self] result in
            self?.handleStillSelection(result)
        }
        controller.begin()
    }

    /// The only flow where the overlay picks windows. Area capture stays a pure
    /// marquee so a drag can never come back as a window instead.
    func captureWindow() {
        guard !cancelCountdownIfRunning() else { return }
        guard CaptureEngine.ensurePermission() else { return }
        guard SelectionOverlayController.current == nil else { return }
        let controller = SelectionOverlayController(purpose: .window) { [weak self] result in
            self?.handleStillSelection(result)
        }
        controller.begin()
    }

    func captureFullscreen() {
        guard !cancelCountdownIfRunning() else { return }
        guard CaptureEngine.ensurePermission() else { return }
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        guard let screen else { return }
        Task { @MainActor in
            do {
                let image = try await CaptureEngine.captureDisplay(screen)
                self.rememberArea(screen.frame, on: screen)
                self.deliver(image: image, scale: screen.backingScaleFactor)
            } catch {
                NSLog("Snapline fullscreen capture failed: \(error)")
            }
        }
    }

    func captureTimed() {
        guard !cancelCountdownIfRunning() else { return }
        guard CaptureEngine.ensurePermission() else { return }
        guard SelectionOverlayController.current == nil else { return }
        let controller = SelectionOverlayController(purpose: .timed) { [weak self] result in
            guard let self else { return }
            guard case let .rect(globalRect, screen) = result else {
                if case let .window(info) = result { self.captureWindowInfo(info) }
                return
            }
            let seconds = SettingsStore.shared.selfTimerSeconds
            let hud = CountdownHUD(seconds: seconds, on: screen) { [weak self] in
                self?.countdown = nil
                self?.captureGlobalRect(globalRect, on: screen)
            }
            self.countdown = hud
            hud.start()
        }
        controller.begin()
    }

    func capturePreviousArea() {
        guard !cancelCountdownIfRunning() else { return }
        guard CaptureEngine.ensurePermission() else { return }
        guard let stored = storedArea() else {
            Toast.show("No previous area yet")
            return
        }
        captureGlobalRect(stored.rect, on: stored.screen)
    }

    private func handleStillSelection(_ result: SelectionResult) {
        switch result {
        case let .frozenRect(image, globalRect, screen, scale):
            rememberArea(globalRect, on: screen)
            deliver(image: image, scale: scale)
        case let .rect(globalRect, screen):
            rememberArea(globalRect, on: screen)
            captureGlobalRect(globalRect, on: screen)
        case let .window(info):
            captureWindowInfo(info)
        case .cancelled:
            break
        }
    }

    private func captureGlobalRect(_ globalRect: CGRect, on screen: NSScreen) {
        let local = CGRect(x: globalRect.origin.x - screen.frame.origin.x,
                           y: screen.frame.maxY - globalRect.maxY,
                           width: globalRect.width, height: globalRect.height)
        Task { @MainActor in
            do {
                let image = try await CaptureEngine.captureRect(local, on: screen)
                self.deliver(image: image, scale: screen.backingScaleFactor)
            } catch {
                NSLog("Snapline area capture failed: \(error)")
            }
        }
    }

    private func captureWindowInfo(_ info: WindowInfo) {
        Task { @MainActor in
            do {
                var image = try await CaptureEngine.captureWindow(windowID: info.windowID)
                if SettingsStore.shared.windowShadow {
                    image = CaptureEngine.addShadow(to: image)
                }
                let screen = NSScreen.screens.first { $0.frame.intersects(info.frame) } ?? NSScreen.main
                self.deliver(image: image, scale: screen?.backingScaleFactor ?? 2)
            } catch {
                NSLog("Snapline window capture failed: \(error)")
            }
        }
    }

    // MARK: OCR

    func captureText() {
        guard !cancelCountdownIfRunning() else { return }
        guard CaptureEngine.ensurePermission() else { return }
        guard SelectionOverlayController.current == nil else { return }
        let controller = SelectionOverlayController(purpose: .ocr) { result in
            guard case let .frozenRect(image, _, _, _) = result else { return }
            OCRService.recognizeText(in: image) { text in
                if let text {
                    let pasteboard = NSPasteboard.general
                    pasteboard.clearContents()
                    pasteboard.setString(text, forType: .string)
                    SoundFX.capture()
                    Toast.show("Text copied to clipboard")
                } else {
                    Toast.show("No text found")
                }
            }
        }
        controller.begin()
    }

    // MARK: Recording

    func toggleRecording() {
        if RecordingEngine.shared.isRecording {
            RecordingEngine.shared.stop()
            return
        }
        guard !RecordingEngine.shared.isStarting else { return }
        guard !cancelCountdownIfRunning() else { return }
        guard CaptureEngine.ensurePermission() else { return }
        guard SelectionOverlayController.current == nil else { return }
        let controller = SelectionOverlayController(purpose: .record) { [weak self] result in
            guard let self else { return }
            var target: (CGRect, NSScreen)?
            switch result {
            case let .rect(rect, screen): target = (rect, screen)
            case let .window(info):
                if let screen = NSScreen.screens.first(where: { $0.frame.intersects(info.frame) }) {
                    target = (info.frame.intersection(screen.frame), screen)
                }
            case .cancelled, .frozenRect: break
            }
            guard let (rect, screen) = target else { return }
            let begin = {
                RecordingEngine.shared.start(globalRect: rect, screen: screen) { url in
                    self.handleFinishedRecording(url)
                }
            }
            if SettingsStore.shared.recordCountIn {
                let hud = CountdownHUD(seconds: 3, on: screen) { [weak self] in
                    self?.countdown = nil
                    begin()
                }
                self.countdown = hud
                hud.start()
            } else {
                begin()
            }
        }
        // The toggles on the bar under the recording area are the same settings
        // as Settings > Recording, so a change sticks for the next recording too.
        let settings = SettingsStore.shared
        controller.recordOptions = RecordOptions(systemAudio: settings.recordSystemAudio,
                                                 microphone: settings.recordMicrophone,
                                                 showCursor: settings.recordShowCursor)
        controller.onRecordOptionsChanged = { options in
            settings.recordSystemAudio = options.systemAudio
            settings.recordMicrophone = options.microphone
            settings.recordShowCursor = options.showCursor
        }
        controller.begin()
    }

    private func handleFinishedRecording(_ url: URL?) {
        guard let url else {
            Toast.show("Recording failed")
            return
        }
        HistoryStore.shared.add(url)
        if SettingsStore.shared.showQuickAccess {
            QuickAccessCenter.shared.showVideo(url: url)
        } else {
            Toast.show("Recording saved")
        }
    }

    // MARK: Pinning

    func pinFromClipboard() {
        let pasteboard = NSPasteboard.general
        guard let image = NSImage(pasteboard: pasteboard), image.isValid else {
            Toast.show("No image on the clipboard")
            return
        }
        PinWindowController.pin(nsImage: image)
    }

    // MARK: Delivery

    /// Mouse up to card in one frame or two. The sound plays on release, the
    /// card thumbnail and optional downscale are prepared off the main thread,
    /// and the single PNG encode, the file write, and the clipboard follow in
    /// the background without holding up the card's slide in.
    func deliver(image rawImage: CGImage, scale: CGFloat) {
        SoundFX.capture()
        let settings = SettingsStore.shared
        let showCard = settings.showQuickAccess
        let cardSize = QuickAccessPanel.cardSize
        DispatchQueue.global(qos: .userInteractive).async {
            let image = ImageWriter.applyRetinaDownscale(rawImage, scale: scale)
            let thumbnail = showCard ? ImageWriter.thumbnail(for: image, covering: cardSize) : nil
            DispatchQueue.main.async {
                // After downscaling, one image pixel equals one point again.
                let effectiveScale: CGFloat = image === rawImage ? scale : 1
                self.present(image, scale: effectiveScale, thumbnail: thumbnail)
            }
        }
    }

    private func present(_ image: CGImage, scale: CGFloat, thumbnail: CGImage?) {
        let settings = SettingsStore.shared
        // Every capture gets a file even when saving is off, otherwise there is
        // no path to drag into another app or paste into a terminal later. The
        // name is fixed now and the bytes follow; anything that needs the file
        // before then waits on ImageWriter.waitForPendingWrites.
        let save = settings.saveAfterCapture
        let fileURL = ImageWriter.writeInBackground(image, scale: scale, saveToFolder: save,
                                                    copy: settings.copyAfterCapture) { written in
            if let written { HistoryStore.shared.add(written) }
        }
        let capture = Capture(image: image, scale: scale, savedURL: save ? fileURL : nil, fileURL: fileURL)
        if settings.showQuickAccess {
            QuickAccessCenter.shared.show(capture: capture, copiedToClipboard: settings.copyAfterCapture,
                                          thumbnail: thumbnail)
        }
        if settings.openEditorAfterCapture {
            EditorWindowController.open(capture: capture)
        }
    }

    // MARK: Previous area persistence

    private func rememberArea(_ globalRect: CGRect, on screen: NSScreen) {
        let dict: [String: Double] = [
            "x": globalRect.origin.x, "y": globalRect.origin.y,
            "w": globalRect.width, "h": globalRect.height
        ]
        UserDefaults.standard.set(dict, forKey: "previousArea")
    }

    private func storedArea() -> (rect: CGRect, screen: NSScreen)? {
        guard let dict = UserDefaults.standard.dictionary(forKey: "previousArea") as? [String: Double] else {
            return nil
        }
        let rect = CGRect(x: dict["x"] ?? 0, y: dict["y"] ?? 0, width: dict["w"] ?? 0, height: dict["h"] ?? 0)
        guard rect.width >= 4, rect.height >= 4 else { return nil }
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(CGPoint(x: rect.midX, y: rect.midY)) }) else {
            return nil
        }
        return (rect, screen)
    }
}
