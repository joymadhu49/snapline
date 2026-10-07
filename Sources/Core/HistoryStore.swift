import AppKit

/// Recent capture files, most recent first.
final class HistoryStore {
    static let shared = HistoryStore()
    private let key = "captureHistory"
    private let capacity = 200

    func add(_ url: URL) {
        var paths = UserDefaults.standard.stringArray(forKey: key) ?? []
        paths.removeAll { $0 == url.path }
        paths.insert(url.path, at: 0)
        if paths.count > capacity { paths = Array(paths.prefix(capacity)) }
        UserDefaults.standard.set(paths, forKey: key)
        notifyChanged()
    }

    func items() -> [URL] {
        let paths = UserDefaults.standard.stringArray(forKey: key) ?? []
        return paths.map { URL(fileURLWithPath: $0) }.filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// Drops the entry and sends the file to the Trash, so the history and the
    /// disk never disagree about what still exists.
    func delete(_ url: URL) {
        forget(url)
        NSWorkspace.shared.recycle([url])
    }

    /// Removes the entry only, for files that vanished behind our back.
    func forget(_ url: URL) {
        var paths = UserDefaults.standard.stringArray(forKey: key) ?? []
        paths.removeAll { $0 == url.path }
        UserDefaults.standard.set(paths, forKey: key)
        notifyChanged()
    }

    func clear() {
        UserDefaults.standard.set([String](), forKey: key)
        notifyChanged()
    }

    private func notifyChanged() {
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .snaplineHistoryChanged, object: nil)
        }
    }
}

extension Notification.Name {
    static let snaplineHistoryChanged = Notification.Name("snaplineHistoryChanged")
}
