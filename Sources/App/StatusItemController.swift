import AppKit

/// Menu bar presence: icon, menu, and recording timer.
final class StatusItemController: NSObject, NSMenuDelegate {
    private let statusItem: NSStatusItem
    private let menu = NSMenu()
    private var recordingTimer: Timer?

    override init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        applyIdleIcon()
        menu.delegate = self
        statusItem.menu = menu
        statusItem.button?.target = self
        statusItem.button?.action = #selector(statusButtonClicked(_:))
        statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        NotificationCenter.default.addObserver(self, selector: #selector(recordingStateChanged),
                                               name: .snaplineRecordingStateChanged, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(shortcutsChanged),
                                               name: .snaplineShortcutsChanged, object: nil)
    }

    /// The Snapline mark, drawn for menu bar sizes. Falls back to the stock symbol if the
    /// bundled vector is ever missing.
    private static let idleIcon: NSImage? = {
        if let url = Bundle.main.url(forResource: "MenuBarIcon", withExtension: "pdf"),
           let image = NSImage(contentsOf: url) {
            image.size = NSSize(width: 18, height: 18)
            image.isTemplate = true
            image.accessibilityDescription = "Snapline"
            return image
        }
        let fallback = NSImage(systemSymbolName: "camera.viewfinder", accessibilityDescription: "Snapline")
        fallback?.isTemplate = true
        return fallback
    }()

    private func applyIdleIcon() {
        guard let button = statusItem.button else { return }
        let image = Self.idleIcon
        button.image = image
        button.imagePosition = .imageLeading
        button.title = ""
        button.contentTintColor = nil
    }

    private func applyRecordingIcon(elapsed: TimeInterval) {
        guard let button = statusItem.button else { return }
        let image = NSImage(systemSymbolName: "stop.circle.fill", accessibilityDescription: "Stop recording")
        image?.isTemplate = false
        button.image = image
        button.contentTintColor = .systemRed
        let minutes = Int(elapsed) / 60
        let seconds = Int(elapsed) % 60
        button.title = String(format: " %d:%02d", minutes, seconds)
        button.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
    }

    @objc private func recordingStateChanged() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if RecordingEngine.shared.isRecording {
                self.applyRecordingIcon(elapsed: 0)
                let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
                    guard let started = RecordingEngine.shared.startedAt else { return }
                    self?.applyRecordingIcon(elapsed: Date().timeIntervalSince(started))
                }
                // Common mode keeps the timer ticking while a menu is open.
                RunLoop.main.add(timer, forMode: .common)
                self.recordingTimer = timer
                // Detach the menu so a click reaches statusButtonClicked and stops the recording.
                self.statusItem.menu = nil
            } else {
                self.recordingTimer?.invalidate()
                self.recordingTimer = nil
                self.applyIdleIcon()
                self.statusItem.menu = self.menu
            }
        }
    }

    /// Only fires while recording (otherwise the attached menu takes the click): a left click
    /// stops the recording in one step, a right click still opens the full menu.
    @objc private func statusButtonClicked(_ sender: NSStatusBarButton) {
        let recording = RecordingEngine.shared.isRecording
        if recording && NSApp.currentEvent?.type != .rightMouseUp {
            CaptureCoordinator.shared.toggleRecording()
            return
        }
        statusItem.menu = menu
        sender.performClick(nil)
        statusItem.menu = RecordingEngine.shared.isRecording ? nil : menu
    }

    @objc private func shortcutsChanged() {
        // Menu rebuilds lazily through menuNeedsUpdate.
    }

    // MARK: Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let settings = SettingsStore.shared

        if RecordingEngine.shared.isRecording {
            let stop = item("Stop Recording", #selector(act(_:)), tag: MenuAction.stopRecording)
            stop.image = tinted("stop.circle.fill", color: .systemRed)
            menu.addItem(stop)
            menu.addItem(.separator())
        }

        func addCapture(_ title: String, _ action: ActionID, _ menuAction: MenuAction, symbol: String) {
            let entry = item(title, #selector(act(_:)), tag: menuAction)
            entry.image = template(symbol)
            if let shortcut = settings.shortcut(for: action) {
                entry.keyEquivalent = shortcut.keyEquivalentCharacter
                entry.keyEquivalentModifierMask = shortcut.modifierFlags
            }
            menu.addItem(entry)
        }

        addCapture("Capture Area", .captureArea, .captureArea, symbol: "rectangle.dashed")
        addCapture("Capture Fullscreen", .captureFullscreen, .captureFullscreen, symbol: "rectangle.inset.filled")
        addCapture("Capture Window", .captureWindow, .captureWindow, symbol: "macwindow")
        addCapture("Capture Previous Area", .capturePreviousArea, .capturePreviousArea, symbol: "arrow.counterclockwise")

        let timed = item("Timed Capture", #selector(act(_:)), tag: .timedCapture)
        timed.image = template("timer")
        menu.addItem(timed)

        menu.addItem(.separator())

        if !RecordingEngine.shared.isRecording {
            addCapture("Record Screen", .toggleRecording, .toggleRecording, symbol: "record.circle")
        }
        addCapture("Capture Text", .captureText, .captureText, symbol: "text.viewfinder")

        menu.addItem(.separator())

        addCapture("Pin from Clipboard", .pinFromClipboard, .pinFromClipboard, symbol: "pin")

        addCapture("Capture History", .showHistory, .history, symbol: "clock.arrow.circlepath")

        let folder = item("Open Captures Folder", #selector(act(_:)), tag: .openFolder)
        folder.image = template("folder")
        menu.addItem(folder)

        menu.addItem(.separator())

        let desktopHidden = isDesktopHidden()
        let desktop = item(desktopHidden ? "Show Desktop Icons" : "Hide Desktop Icons", #selector(act(_:)), tag: .toggleDesktopIcons)
        desktop.image = template(desktopHidden ? "eye" : "eye.slash")
        menu.addItem(desktop)

        menu.addItem(.separator())

        let prefs = item("Settings", #selector(act(_:)), tag: .settings)
        prefs.keyEquivalent = ","
        prefs.keyEquivalentModifierMask = [.command]
        prefs.image = template("gearshape")
        menu.addItem(prefs)

        let keys = item("Customize Shortcuts", #selector(act(_:)), tag: .shortcuts)
        keys.image = template("keyboard")
        menu.addItem(keys)

        let updates = NSMenuItem(title: "Check for Updates", action: #selector(UpdateController.checkForUpdates), keyEquivalent: "")
        updates.target = UpdateController.shared
        updates.image = template("arrow.triangle.2.circlepath")
        updates.keepImageVisible()
        menu.addItem(updates)

        let quit = item("Quit Snapline", #selector(act(_:)), tag: .quit)
        quit.keyEquivalent = "q"
        quit.keyEquivalentModifierMask = [.command]
        menu.addItem(quit)
    }

    private enum MenuAction: Int {
        case captureArea = 1, captureFullscreen, captureWindow, capturePreviousArea
        case timedCapture, toggleRecording, stopRecording, captureText, pinFromClipboard
        case openFolder, toggleDesktopIcons, settings, shortcuts, quit, history
    }

    private func item(_ title: String, _ selector: Selector, tag: MenuAction) -> NSMenuItem {
        let entry = NSMenuItem(title: title, action: selector, keyEquivalent: "")
        entry.target = self
        entry.tag = tag.rawValue
        entry.keepImageVisible()
        return entry
    }

    private func template(_ name: String) -> NSImage? {
        let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)
        image?.isTemplate = true
        return image
    }

    private func tinted(_ name: String, color: NSColor) -> NSImage? {
        guard let base = NSImage(systemSymbolName: name, accessibilityDescription: nil) else { return nil }
        let config = NSImage.SymbolConfiguration(paletteColors: [color])
        return base.withSymbolConfiguration(config)
    }

    @objc private func act(_ sender: NSMenuItem) {
        guard let menuAction = MenuAction(rawValue: sender.tag) else { return }
        let coordinator = CaptureCoordinator.shared
        switch menuAction {
        case .captureArea: coordinator.captureArea()
        case .captureFullscreen: coordinator.captureFullscreen()
        case .captureWindow: coordinator.captureWindow()
        case .capturePreviousArea: coordinator.capturePreviousArea()
        case .timedCapture: coordinator.captureTimed()
        case .toggleRecording, .stopRecording: coordinator.toggleRecording()
        case .captureText: coordinator.captureText()
        case .pinFromClipboard: coordinator.pinFromClipboard()
        case .openFolder: NSWorkspace.shared.open(SettingsStore.shared.saveDirectoryURL)
        case .toggleDesktopIcons: toggleDesktopIcons()
        case .settings: SettingsWindowController.show()
        case .shortcuts: SettingsWindowController.show(tab: "shortcuts")
        case .history: HistoryPanelController.shared.toggle()
        case .quit: NSApp.terminate(nil)
        }
    }

    // MARK: Desktop icons

    private func isDesktopHidden() -> Bool {
        let result = UserDefaults(suiteName: "com.apple.finder")?.object(forKey: "CreateDesktop")
        if let flag = result as? Bool { return !flag }
        if let text = result as? String { return text == "false" || text == "0" }
        return false
    }

    private func toggleDesktopIcons() {
        let hide = !isDesktopHidden()
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/defaults")
        task.arguments = ["write", "com.apple.finder", "CreateDesktop", "-bool", hide ? "false" : "true"]
        try? task.run()
        task.waitUntilExit()
        let restart = Process()
        restart.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        restart.arguments = ["Finder"]
        try? restart.run()
    }
}

private extension NSMenuItem {
    /// macOS 27 hides menu item images by default; keep the CleanShot style icon column.
    /// The property only exists in the macOS 27 SDK (Swift 6.4 toolchains), so older SDKs
    /// compile the call away instead of failing the build.
    func keepImageVisible() {
        #if compiler(>=6.4)
        if #available(macOS 27.0, *) {
            preferredImageVisibility = .visible
        }
        #endif
    }
}
