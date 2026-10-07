import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItemController: StatusItemController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let settings = SettingsStore.shared

        HotkeyCenter.shared.handler = { action in
            CaptureCoordinator.shared.perform(action)
        }
        HotkeyCenter.shared.reloadAll(from: settings)

        statusItemController = StatusItemController()
        CaptureEngine.prewarm()
        UpdateController.shared.start()

        let launchedBefore = UserDefaults.standard.bool(forKey: "hasLaunchedBefore")
        if !launchedBefore {
            UserDefaults.standard.set(true, forKey: "hasLaunchedBefore")
            // First run: surface the settings window and request screen access early.
            SettingsWindowController.show()
            if !CGPreflightScreenCaptureAccess() {
                CGRequestScreenCaptureAccess()
            }
            Toast.show("Snapline lives in your menu bar")
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            SettingsWindowController.show()
        }
        return true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if RecordingEngine.shared.isRecording {
            // Finish the file properly before the process dies.
            RecordingEngine.shared.stopForTermination {
                NSApp.reply(toApplicationShouldTerminate: true)
            }
            return .terminateLater
        }
        return .terminateNow
    }

    func applicationWillTerminate(_ notification: Notification) {
        HotkeyCenter.shared.unregisterAll()
    }
}
