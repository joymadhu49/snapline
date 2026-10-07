import AppKit
import Combine
import ServiceManagement

enum CaptureKind {
    case screenshot, recording, gif

    var folderName: String {
        switch self {
        case .screenshot: return "Screenshots"
        case .recording: return "Recordings"
        case .gif: return "GIFs"
        }
    }
}

enum ImageFormat: String, CaseIterable, Codable {
    case png, jpg
    var title: String { self == .png ? "PNG" : "JPG" }
    var fileExtension: String { rawValue }
}

/// UserDefaults backed app settings, observable by SwiftUI.
final class SettingsStore: ObservableObject {
    static let shared = SettingsStore()

    private let defaults = UserDefaults.standard

    // MARK: General
    @Published var launchAtLogin: Bool { didSet { save("launchAtLogin", launchAtLogin); applyLoginItem() } }
    @Published var playSounds: Bool { didSet { save("playSounds", playSounds) } }
    @Published var showQuickAccess: Bool { didSet { save("showQuickAccess", showQuickAccess) } }
    /// Cards the quick access overlay may stack. 0 means as many as fit the screen.
    @Published var overlayMaxCards: Int { didSet { save("overlayMaxCards", overlayMaxCards) } }
    /// small, medium, or large. QuickAccessPanel reads the key directly.
    @Published var overlaySize: String { didSet { save("overlaySize", overlaySize) } }
    @Published var copyAfterCapture: Bool { didSet { save("copyAfterCapture", copyAfterCapture) } }
    @Published var saveAfterCapture: Bool { didSet { save("saveAfterCapture", saveAfterCapture) } }
    @Published var openEditorAfterCapture: Bool { didSet { save("openEditorAfterCapture", openEditorAfterCapture) } }
    /// Pixel magnifier beside the pointer during area selection. The overlay reads the key directly.
    @Published var showMagnifier: Bool { didSet { save("showMagnifier", showMagnifier) } }

    // MARK: Output
    @Published var saveDirectoryPath: String { didSet { save("saveDirectoryPath", saveDirectoryPath) } }
    @Published var imageFormat: ImageFormat { didSet { save("imageFormat", imageFormat.rawValue) } }
    @Published var jpgQuality: Double { didSet { save("jpgQuality", jpgQuality) } }
    @Published var downscaleRetina: Bool { didSet { save("downscaleRetina", downscaleRetina) } }
    @Published var windowShadow: Bool { didSet { save("windowShadow", windowShadow) } }
    @Published var selfTimerSeconds: Int { didSet { save("selfTimerSeconds", selfTimerSeconds) } }

    // MARK: Recording
    @Published var recordFPS: Int { didSet { save("recordFPS", recordFPS) } }
    @Published var recordSystemAudio: Bool { didSet { save("recordSystemAudio", recordSystemAudio) } }
    @Published var recordMicrophone: Bool { didSet { save("recordMicrophone", recordMicrophone) } }
    @Published var recordCountIn: Bool { didSet { save("recordCountIn", recordCountIn) } }
    @Published var recordShowCursor: Bool { didSet { save("recordShowCursor", recordShowCursor) } }

    // MARK: Shortcuts
    @Published private(set) var shortcuts: [String: Shortcut]

    /// The root capture folder. Created on demand: an earlier build fell back to
    /// the Desktop whenever the folder was missing, which is how captures ended
    /// up loose all over it.
    var saveDirectoryURL: URL {
        let url = URL(fileURLWithPath: (saveDirectoryPath as NSString).expandingTildeInPath, isDirectory: true)
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
            return url
        }
        if (try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)) != nil {
            return url
        }
        return FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
    }

    /// One subfolder per kind, so screenshots, recordings, and GIFs stay apart
    /// instead of piling into a single list.
    func directory(for kind: CaptureKind) -> URL {
        let url = saveDirectoryURL.appendingPathComponent(kind.folderName, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private init() {
        launchAtLogin = defaults.object(forKey: "launchAtLogin") as? Bool ?? false
        playSounds = defaults.object(forKey: "playSounds") as? Bool ?? true
        showQuickAccess = defaults.object(forKey: "showQuickAccess") as? Bool ?? true
        overlayMaxCards = defaults.object(forKey: "overlayMaxCards") as? Int ?? 0
        overlaySize = defaults.string(forKey: "overlaySize") ?? "medium"
        copyAfterCapture = defaults.object(forKey: "copyAfterCapture") as? Bool ?? true
        saveAfterCapture = defaults.object(forKey: "saveAfterCapture") as? Bool ?? true
        openEditorAfterCapture = defaults.object(forKey: "openEditorAfterCapture") as? Bool ?? false
        showMagnifier = defaults.object(forKey: "showMagnifier") as? Bool ?? false
        saveDirectoryPath = SettingsStore.resolvedSaveDirectoryPath(defaults)
        imageFormat = ImageFormat(rawValue: defaults.string(forKey: "imageFormat") ?? "png") ?? .png
        jpgQuality = defaults.object(forKey: "jpgQuality") as? Double ?? 0.9
        downscaleRetina = defaults.object(forKey: "downscaleRetina") as? Bool ?? false
        windowShadow = defaults.object(forKey: "windowShadow") as? Bool ?? true
        selfTimerSeconds = defaults.object(forKey: "selfTimerSeconds") as? Int ?? 5
        recordFPS = defaults.object(forKey: "recordFPS") as? Int ?? 60
        recordSystemAudio = defaults.object(forKey: "recordSystemAudio") as? Bool ?? true
        recordMicrophone = defaults.object(forKey: "recordMicrophone") as? Bool ?? false
        recordCountIn = defaults.object(forKey: "recordCountIn") as? Bool ?? true
        recordShowCursor = defaults.object(forKey: "recordShowCursor") as? Bool ?? true

        if let data = defaults.data(forKey: "shortcuts"),
           let decoded = try? JSONDecoder().decode([String: Shortcut].self, from: data) {
            shortcuts = decoded
        } else {
            var initial: [String: Shortcut] = [:]
            for action in ActionID.allCases {
                if let def = action.defaultShortcut { initial[action.rawValue] = def }
            }
            shortcuts = initial
        }
    }

    /// Builds up to and including 1.0 saved to the Desktop. Move that one case
    /// across to the tidy folder the first time this build runs, and leave a
    /// deliberately chosen folder alone.
    private static func resolvedSaveDirectoryPath(_ defaults: UserDefaults) -> String {
        let organized = "~/Pictures/Snapline"
        guard let stored = defaults.string(forKey: "saveDirectoryPath") else { return organized }
        guard !defaults.bool(forKey: "didOrganizeSaveDirectory") else { return stored }
        defaults.set(true, forKey: "didOrganizeSaveDirectory")
        let desktop = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first?.path
        let expanded = (stored as NSString).expandingTildeInPath
        guard stored == "~/Desktop" || expanded == desktop else { return stored }
        defaults.set(organized, forKey: "saveDirectoryPath")
        return organized
    }

    // MARK: Shortcut access

    func shortcut(for action: ActionID) -> Shortcut? {
        shortcuts[action.rawValue]
    }

    func setShortcut(_ shortcut: Shortcut?, for action: ActionID) {
        if let shortcut {
            // One combination can belong to only one action.
            for (key, existing) in shortcuts where existing == shortcut && key != action.rawValue {
                shortcuts.removeValue(forKey: key)
            }
            shortcuts[action.rawValue] = shortcut
        } else {
            shortcuts.removeValue(forKey: action.rawValue)
        }
        persistShortcuts()
    }

    func resetShortcutsToDefaults() {
        var fresh: [String: Shortcut] = [:]
        for action in ActionID.allCases {
            if let def = action.defaultShortcut { fresh[action.rawValue] = def }
        }
        shortcuts = fresh
        persistShortcuts()
    }

    private func persistShortcuts() {
        if let data = try? JSONEncoder().encode(shortcuts) {
            defaults.set(data, forKey: "shortcuts")
        }
        HotkeyCenter.shared.reloadAll(from: self)
        NotificationCenter.default.post(name: .snaplineShortcutsChanged, object: nil)
    }

    // MARK: Helpers

    private func save(_ key: String, _ value: Any) {
        defaults.set(value, forKey: key)
    }

    private func applyLoginItem() {
        do {
            if launchAtLogin {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            NSLog("Snapline login item error: \(error.localizedDescription)")
        }
    }
}

extension Notification.Name {
    static let snaplineShortcutsChanged = Notification.Name("snaplineShortcutsChanged")
    static let snaplineRecordingStateChanged = Notification.Name("snaplineRecordingStateChanged")
}
