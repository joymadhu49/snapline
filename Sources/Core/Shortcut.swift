import AppKit
import Carbon.HIToolbox

/// Every user triggerable action that can carry a global shortcut.
enum ActionID: String, CaseIterable, Codable {
    case captureArea
    case captureFullscreen
    case captureWindow
    case capturePreviousArea
    case captureText
    case toggleRecording
    case pinFromClipboard
    case showHistory

    var title: String {
        switch self {
        case .captureArea: return "Capture Area"
        case .captureFullscreen: return "Capture Fullscreen"
        case .captureWindow: return "Capture Window"
        case .capturePreviousArea: return "Capture Previous Area"
        case .captureText: return "Capture Text"
        case .toggleRecording: return "Record Screen"
        case .pinFromClipboard: return "Pin from Clipboard"
        case .showHistory: return "Capture History"
        }
    }

    var defaultShortcut: Shortcut? {
        switch self {
        case .captureArea: return Shortcut(keyCode: UInt32(kVK_ANSI_4), carbonModifiers: UInt32(optionKey | shiftKey))
        case .captureFullscreen: return Shortcut(keyCode: UInt32(kVK_ANSI_3), carbonModifiers: UInt32(optionKey | shiftKey))
        case .captureWindow: return Shortcut(keyCode: UInt32(kVK_ANSI_5), carbonModifiers: UInt32(optionKey | shiftKey))
        case .capturePreviousArea: return Shortcut(keyCode: UInt32(kVK_ANSI_8), carbonModifiers: UInt32(optionKey | shiftKey))
        case .captureText: return Shortcut(keyCode: UInt32(kVK_ANSI_7), carbonModifiers: UInt32(optionKey | shiftKey))
        case .toggleRecording: return Shortcut(keyCode: UInt32(kVK_ANSI_6), carbonModifiers: UInt32(optionKey | shiftKey))
        case .pinFromClipboard: return nil
        case .showHistory: return Shortcut(keyCode: UInt32(kVK_ANSI_9), carbonModifiers: UInt32(optionKey | shiftKey))
        }
    }
}

/// A recorded global keyboard shortcut stored as Carbon key code plus modifiers.
struct Shortcut: Codable, Equatable {
    var keyCode: UInt32
    var carbonModifiers: UInt32

    init(keyCode: UInt32, carbonModifiers: UInt32) {
        self.keyCode = keyCode
        self.carbonModifiers = carbonModifiers
    }

    init?(event: NSEvent) {
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        guard !flags.intersection([.command, .option, .control]).isEmpty else { return nil }
        var carbon: UInt32 = 0
        if flags.contains(.command) { carbon |= UInt32(cmdKey) }
        if flags.contains(.option) { carbon |= UInt32(optionKey) }
        if flags.contains(.control) { carbon |= UInt32(controlKey) }
        if flags.contains(.shift) { carbon |= UInt32(shiftKey) }
        self.keyCode = UInt32(event.keyCode)
        self.carbonModifiers = carbon
    }

    var modifierFlags: NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        if carbonModifiers & UInt32(cmdKey) != 0 { flags.insert(.command) }
        if carbonModifiers & UInt32(optionKey) != 0 { flags.insert(.option) }
        if carbonModifiers & UInt32(controlKey) != 0 { flags.insert(.control) }
        if carbonModifiers & UInt32(shiftKey) != 0 { flags.insert(.shift) }
        return flags
    }

    /// Human readable form such as "⌥⇧4".
    var displayString: String {
        var parts = ""
        if carbonModifiers & UInt32(controlKey) != 0 { parts += "⌃" }
        if carbonModifiers & UInt32(optionKey) != 0 { parts += "⌥" }
        if carbonModifiers & UInt32(shiftKey) != 0 { parts += "⇧" }
        if carbonModifiers & UInt32(cmdKey) != 0 { parts += "⌘" }
        return parts + Shortcut.keyName(for: keyCode)
    }

    /// Character usable as an NSMenuItem key equivalent, empty when the key has none.
    var keyEquivalentCharacter: String {
        let name = Shortcut.keyName(for: keyCode)
        if name.count == 1 { return name.lowercased() }
        switch Int(keyCode) {
        case kVK_Space: return " "
        case kVK_Return: return "\r"
        case kVK_Tab: return "\t"
        case kVK_Escape: return "\u{1b}"
        case kVK_Delete: return "\u{8}"
        case kVK_LeftArrow: return String(UnicodeScalar(NSLeftArrowFunctionKey)!)
        case kVK_RightArrow: return String(UnicodeScalar(NSRightArrowFunctionKey)!)
        case kVK_UpArrow: return String(UnicodeScalar(NSUpArrowFunctionKey)!)
        case kVK_DownArrow: return String(UnicodeScalar(NSDownArrowFunctionKey)!)
        default: return ""
        }
    }

    static func keyName(for keyCode: UInt32) -> String {
        switch Int(keyCode) {
        case kVK_Space: return "Space"
        case kVK_Return: return "Return"
        case kVK_Tab: return "Tab"
        case kVK_Escape: return "Esc"
        case kVK_Delete: return "Delete"
        case kVK_ForwardDelete: return "Fwd Delete"
        case kVK_Home: return "Home"
        case kVK_End: return "End"
        case kVK_PageUp: return "Page Up"
        case kVK_PageDown: return "Page Down"
        case kVK_LeftArrow: return "Left"
        case kVK_RightArrow: return "Right"
        case kVK_UpArrow: return "Up"
        case kVK_DownArrow: return "Down"
        case kVK_F1: return "F1"
        case kVK_F2: return "F2"
        case kVK_F3: return "F3"
        case kVK_F4: return "F4"
        case kVK_F5: return "F5"
        case kVK_F6: return "F6"
        case kVK_F7: return "F7"
        case kVK_F8: return "F8"
        case kVK_F9: return "F9"
        case kVK_F10: return "F10"
        case kVK_F11: return "F11"
        case kVK_F12: return "F12"
        default: break
        }
        // Translate through the current keyboard layout.
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let layoutData = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else {
            return "?"
        }
        let data = Unmanaged<CFData>.fromOpaque(layoutData).takeUnretainedValue() as Data
        var deadKeyState: UInt32 = 0
        var length = 0
        var chars = [UniChar](repeating: 0, count: 4)
        let status = data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) -> OSStatus in
            let layout = bytes.bindMemory(to: UCKeyboardLayout.self).baseAddress!
            return UCKeyTranslate(layout, UInt16(keyCode), UInt16(kUCKeyActionDisplay), 0,
                                  UInt32(LMGetKbdType()), OptionBits(kUCKeyTranslateNoDeadKeysBit),
                                  &deadKeyState, chars.count, &length, &chars)
        }
        guard status == noErr, length > 0 else { return "?" }
        return String(utf16CodeUnits: chars, count: length).uppercased()
    }
}
