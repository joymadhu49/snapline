import AppKit
import SwiftUI

final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    static let shared = SettingsWindowController()

    private init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 470),
                              styleMask: [.titled, .closable, .miniaturizable],
                              backing: .buffered, defer: false)
        window.title = "Snapline Settings"
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)
        window.delegate = self
        window.contentView = NSHostingView(rootView: SettingsRootView())
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    static func show(tab: String? = nil) {
        if let tab {
            UserDefaults.standard.set(tab, forKey: "settingsSelectedTab")
        }
        shared.window?.center()
        shared.showWindow(nil)
        shared.window?.orderFrontRegardless()
        shared.window?.makeKey()
        NSApp.activate(ignoringOtherApps: true)
    }
}

struct SettingsRootView: View {
    @ObservedObject private var settings = SettingsStore.shared
    @AppStorage("settingsSelectedTab") private var selectedTab = "general"

    var body: some View {
        TabView(selection: $selectedTab) {
            generalTab
                .tabItem { Label("General", systemImage: "gearshape") }
                .tag("general")
            outputTab
                .tabItem { Label("Output", systemImage: "folder") }
                .tag("output")
            recordingTab
                .tabItem { Label("Recording", systemImage: "record.circle") }
                .tag("recording")
            shortcutsTab
                .tabItem { Label("Shortcuts", systemImage: "keyboard") }
                .tag("shortcuts")
            aboutTab
                .tabItem { Label("About", systemImage: "info.circle") }
                .tag("about")
        }
        .frame(width: 520, height: 470)
    }

    // MARK: General

    private var generalTab: some View {
        Form {
            Section {
                Toggle("Launch at login", isOn: $settings.launchAtLogin)
                Toggle("Play capture sounds", isOn: $settings.playSounds)
                Toggle("Show quick access overlay after capture", isOn: $settings.showQuickAccess)
                Picker("Overlay holds", selection: $settings.overlayMaxCards) {
                    Text("As many as fit the screen").tag(0)
                    Text("3 cards").tag(3)
                    Text("5 cards").tag(5)
                    Text("8 cards").tag(8)
                    Text("10 cards").tag(10)
                }
                .disabled(!settings.showQuickAccess)
                Picker("Overlay size", selection: $settings.overlaySize) {
                    Text("Small").tag("small")
                    Text("Medium").tag("medium")
                    Text("Large").tag("large")
                }
                .disabled(!settings.showQuickAccess)
            }
            Section("Area selection") {
                Toggle("Show pixel magnifier", isOn: $settings.showMagnifier)
            }
            Section("After a capture") {
                Toggle("Copy image to clipboard", isOn: $settings.copyAfterCapture)
                Toggle("Save image to disk", isOn: $settings.saveAfterCapture)
                Toggle("Open the editor", isOn: $settings.openEditorAfterCapture)
            }
            Section("Timed capture") {
                Picker("Self timer delay", selection: $settings.selfTimerSeconds) {
                    Text("3 seconds").tag(3)
                    Text("5 seconds").tag(5)
                    Text("10 seconds").tag(10)
                }
            }
        }
        .formStyle(.grouped)
    }

    // MARK: Output

    private var outputTab: some View {
        Form {
            Section("Save location") {
                HStack {
                    Text(settings.saveDirectoryURL.path)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Reveal") {
                        NSWorkspace.shared.open(settings.saveDirectoryURL)
                    }
                    Button("Change") { pickFolder() }
                }
                Text("Captures are filed into Screenshots, Recordings, and GIFs inside this folder.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Section("Image format") {
                Picker("Format", selection: $settings.imageFormat) {
                    ForEach(ImageFormat.allCases, id: \.self) { format in
                        Text(format.title).tag(format)
                    }
                }
                if settings.imageFormat == .jpg {
                    VStack(alignment: .leading) {
                        Text("JPG quality \(Int(settings.jpgQuality * 100)) percent")
                        Slider(value: $settings.jpgQuality, in: 0.5...1.0)
                    }
                }
                Toggle("Downscale retina captures to 1x", isOn: $settings.downscaleRetina)
            }
            Section("Window captures") {
                Toggle("Add a soft shadow behind captured windows", isOn: $settings.windowShadow)
            }
        }
        .formStyle(.grouped)
    }

    private func pickFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.directoryURL = settings.saveDirectoryURL
        if panel.runModal() == .OK, let url = panel.url {
            settings.saveDirectoryPath = url.path
        }
    }

    // MARK: Recording

    private var recordingTab: some View {
        Form {
            Section {
                Picker("Frame rate", selection: $settings.recordFPS) {
                    Text("30 fps").tag(30)
                    Text("60 fps").tag(60)
                }
                Toggle("Show mouse cursor", isOn: $settings.recordShowCursor)
                Toggle("Count in for 3 seconds before recording", isOn: $settings.recordCountIn)
            }
            Section("Audio") {
                Toggle("Record system audio", isOn: $settings.recordSystemAudio)
                Toggle("Record microphone", isOn: $settings.recordMicrophone)
                if #unavailable(macOS 15.0) {
                    Text("Microphone recording needs macOS 15 or newer.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Section("GIF export") {
                if GIFExporter.isAvailable {
                    Text("GIF export is available through ffmpeg. Use the GIF button on the overlay after a recording.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Install ffmpeg with Homebrew to enable GIF export.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }

    // MARK: Shortcuts

    private var shortcutsTab: some View {
        Form {
            Section("Global shortcuts") {
                ForEach(ActionID.allCases, id: \.self) { action in
                    HStack {
                        Text(action.title)
                        Spacer()
                        ShortcutRecorder(action: action)
                            .frame(width: 170, height: 26)
                    }
                }
            }
            Section {
                HStack {
                    Text("Click a field, then press the new keys. Press Delete while recording to remove a shortcut.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Restore Defaults") {
                        settings.resetShortcutsToDefaults()
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    // MARK: About

    private var aboutTab: some View {
        VStack(spacing: 10) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 84, height: 84)
            Text("Snapline")
                .font(.system(size: 22, weight: .semibold))
            Text("Version \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0")")
                .foregroundStyle(.secondary)
            Text("Professional screen capture for your workflow.\nCaptures, annotations, recordings, and text recognition all stay on this Mac.")
                .multilineTextAlignment(.center)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .padding(.top, 6)
            Spacer()
        }
        .padding(.top, 40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
