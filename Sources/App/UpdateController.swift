import AppKit
import Combine
import Sparkle

/// Owns Sparkle. Updates come from the appcast attached to the newest GitHub release, and
/// every archive is checked against the EdDSA key in Info.plist before it is installed.
///
/// The update check is the only network request Snapline makes. It sends nothing about
/// your captures, and system profiling is left off.
@MainActor
final class UpdateController: NSObject, ObservableObject {
    static let shared = UpdateController()

    @Published private(set) var canCheckForUpdates = false
    @Published var automaticallyChecks = false {
        didSet {
            guard automaticallyChecks != updater.automaticallyChecksForUpdates else { return }
            updater.automaticallyChecksForUpdates = automaticallyChecks
        }
    }
    @Published private(set) var lastCheck: Date?

    private var controller: SPUStandardUpdaterController!
    private var observations: [NSKeyValueObservation] = []

    private var updater: SPUUpdater { controller.updater }

    private override init() {
        super.init()
        controller = SPUStandardUpdaterController(startingUpdater: false,
                                                  updaterDelegate: nil,
                                                  userDriverDelegate: self)
    }

    /// Called once from launch. A development build without a feed would only log errors,
    /// so the updater is started for the shipped app alone.
    func start() {
        guard Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") != nil else { return }
        controller.startUpdater()

        automaticallyChecks = updater.automaticallyChecksForUpdates
        lastCheck = updater.lastUpdateCheckDate
        observations = [
            updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] updater, _ in
                let value = updater.canCheckForUpdates
                Task { @MainActor in self?.canCheckForUpdates = value }
            },
            updater.observe(\.lastUpdateCheckDate, options: [.new]) { [weak self] updater, _ in
                let value = updater.lastUpdateCheckDate
                Task { @MainActor in self?.lastCheck = value }
            }
        ]
    }

    @objc func checkForUpdates() {
        // A menu bar app is never frontmost on its own, and Sparkle's window would open
        // behind whatever the user was working in.
        NSApp.activate(ignoringOtherApps: true)
        controller.checkForUpdates(nil)
    }
}

extension UpdateController: NSMenuItemValidation {
    /// Greys out the menu items while a check is already running, or in a build with no feed.
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        canCheckForUpdates
    }
}

extension UpdateController: SPUStandardUserDriverDelegate {
    /// Snapline has no Dock icon and is rarely frontmost. Declaring gentle reminders lets
    /// Sparkle show a scheduled update without yanking focus from whatever the user is
    /// typing into, instead of warning that a background app cannot present one well.
    nonisolated var supportsGentleScheduledUpdateReminders: Bool { true }

    nonisolated func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool,
                                                               forUpdate update: SUAppcastItem,
                                                               state: SPUUserUpdateState) {
        guard handleShowingUpdate, state.userInitiated else { return }
        Task { @MainActor in NSApp.activate(ignoringOtherApps: true) }
    }
}
