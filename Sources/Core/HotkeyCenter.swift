import AppKit
import Carbon.HIToolbox

/// Registers Carbon global hotkeys and dispatches them to action handlers.
final class HotkeyCenter {
    static let shared = HotkeyCenter()

    var handler: ((ActionID) -> Void)?

    private var hotKeyRefs: [ActionID: EventHotKeyRef] = [:]
    private var idToAction: [UInt32: ActionID] = [:]
    private var nextID: UInt32 = 1
    private var eventHandlerRef: EventHandlerRef?

    private init() {
        installHandler()
    }

    private func installHandler() {
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let callback: EventHandlerUPP = { _, event, userData in
            guard let event, let userData else { return noErr }
            var hotKeyID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            let center = Unmanaged<HotkeyCenter>.fromOpaque(userData).takeUnretainedValue()
            center.dispatch(id: hotKeyID.id)
            return noErr
        }
        let selfPtr = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        InstallEventHandler(GetEventDispatcherTarget(), callback, 1, &eventType, selfPtr, &eventHandlerRef)
    }

    private func dispatch(id: UInt32) {
        guard let action = idToAction[id] else { return }
        DispatchQueue.main.async { [weak self] in
            self?.handler?(action)
        }
    }

    /// Re-registers all shortcuts from the settings store. Call on launch and after edits.
    func reloadAll(from settings: SettingsStore) {
        unregisterAll()
        for action in ActionID.allCases {
            if let shortcut = settings.shortcut(for: action) {
                _ = register(shortcut, for: action)
            }
        }
    }

    /// Returns false when the system refuses the combination (owned by another app).
    @discardableResult
    func register(_ shortcut: Shortcut, for action: ActionID) -> Bool {
        unregister(action)
        let id = nextID
        nextID += 1
        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: OSType(0x534E_4150), id: id) // "SNAP"
        let status = RegisterEventHotKey(shortcut.keyCode, shortcut.carbonModifiers, hotKeyID,
                                         GetEventDispatcherTarget(), 0, &ref)
        guard status == noErr, let ref else { return false }
        hotKeyRefs[action] = ref
        idToAction[id] = action
        return true
    }

    func unregister(_ action: ActionID) {
        if let ref = hotKeyRefs.removeValue(forKey: action) {
            UnregisterEventHotKey(ref)
        }
        idToAction = idToAction.filter { $0.value != action }
    }

    func unregisterAll() {
        for (_, ref) in hotKeyRefs { UnregisterEventHotKey(ref) }
        hotKeyRefs.removeAll()
        idToAction.removeAll()
    }

    /// Probes whether a combination can be registered right now without keeping it.
    func canRegister(_ shortcut: Shortcut) -> Bool {
        var ref: EventHotKeyRef?
        let probeID = EventHotKeyID(signature: OSType(0x534E_5052), id: 0xFFFF)
        let status = RegisterEventHotKey(shortcut.keyCode, shortcut.carbonModifiers, probeID,
                                         GetEventDispatcherTarget(), 0, &ref)
        if status == noErr, let ref {
            UnregisterEventHotKey(ref)
            return true
        }
        return false
    }
}
