import AppKit
import SwiftUI

/// Click to record a new global shortcut for an action.
struct ShortcutRecorder: NSViewRepresentable {
    let action: ActionID

    func makeNSView(context: Context) -> RecorderControl {
        RecorderControl(action: action)
    }

    func updateNSView(_ nsView: RecorderControl, context: Context) {
        nsView.refresh()
    }
}

final class RecorderControl: NSView {
    let action: ActionID
    private var isRecording = false
    private var monitor: Any?
    private var conflict = false

    init(action: ActionID) {
        self.action = action
        super.init(frame: NSRect(x: 0, y: 0, width: 170, height: 26))
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.borderWidth = 1
        refresh()
        NotificationCenter.default.addObserver(self, selector: #selector(shortcutsChanged),
                                               name: .snaplineShortcutsChanged, object: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    deinit {
        stopRecording()
        NotificationCenter.default.removeObserver(self)
    }

    override var intrinsicContentSize: NSSize { NSSize(width: 170, height: 26) }

    @objc private func shortcutsChanged() {
        refresh()
    }

    func refresh() {
        needsDisplay = true
        layer?.borderColor = isRecording
            ? NSColor.controlAccentColor.cgColor
            : NSColor.white.withAlphaComponent(0.18).cgColor
        layer?.backgroundColor = NSColor.white.withAlphaComponent(isRecording ? 0.1 : 0.05).cgColor
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let text: String
        let color: NSColor
        if conflict {
            text = "Another app owns this shortcut"
            color = .systemRed
        } else if isRecording {
            text = "Type shortcut, Esc to cancel"
            color = .secondaryLabelColor
        } else if let shortcut = SettingsStore.shared.shortcut(for: action) {
            text = shortcut.displayString
            color = .labelColor
        } else {
            text = "Record Shortcut"
            color = .secondaryLabelColor
        }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: conflict ? 10 : 12, weight: .medium),
            .foregroundColor: color
        ]
        let size = text.size(withAttributes: attributes)
        text.draw(at: CGPoint(x: (bounds.width - size.width) / 2,
                              y: (bounds.height - size.height) / 2),
                  withAttributes: attributes)
    }

    override func mouseDown(with event: NSEvent) {
        if isRecording {
            stopRecording()
        } else {
            startRecording()
        }
        refresh()
    }

    private func startRecording() {
        isRecording = true
        conflict = false
        window?.makeFirstResponder(self)
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.isRecording else { return event }
            if event.keyCode == 53 { // Escape cancels
                self.stopRecording()
                self.refresh()
                return nil
            }
            if event.keyCode == 51 { // Delete clears the shortcut
                SettingsStore.shared.setShortcut(nil, for: self.action)
                self.stopRecording()
                self.refresh()
                return nil
            }
            guard let shortcut = Shortcut(event: event) else {
                NSSound.beep()
                return nil
            }
            // Probe availability without our own bindings holding the combo.
            HotkeyCenter.shared.unregisterAll()
            let available = HotkeyCenter.shared.canRegister(shortcut)
            if available {
                SettingsStore.shared.setShortcut(shortcut, for: self.action)
                self.stopRecording()
            } else {
                HotkeyCenter.shared.reloadAll(from: SettingsStore.shared)
                self.conflict = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) { [weak self] in
                    self?.conflict = false
                    self?.refresh()
                }
                self.stopRecording()
            }
            self.refresh()
            return nil
        }
        refresh()
    }

    private func stopRecording() {
        isRecording = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}
