import AppKit
import SwiftUI

@MainActor
final class SettingsWindow {
    private var window: NSWindow?
    private let preferences: Preferences
    private let shortcuts: Shortcuts

    init(preferences: Preferences, shortcuts: Shortcuts) {
        self.preferences = preferences
        self.shortcuts = shortcuts
    }

    func show() {
        if window == nil {
            let host = NSHostingController(rootView: SettingsView(preferences: preferences, shortcuts: shortcuts))
            let window = NSWindow(contentViewController: host)
            window.title = "BetterSim Settings"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.center()
            self.window = window
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }
}

struct SettingsView: View {
    @ObservedObject var preferences: Preferences
    @ObservedObject var shortcuts: Shortcuts
    @State private var trusted = AccessibilityScreenFinder.isTrusted

    var body: some View {
        Form {
            Section("Captures") {
                LabeledContent("Save to") {
                    HStack {
                        Text(preferences.saveFolder.path(percentEncoded: false)).lineLimit(1).truncationMode(.middle)
                        Button("Change…") { preferences.chooseSaveFolder() }
                    }
                }
                Toggle("Copy new captures to the clipboard", isOn: $preferences.copiesCaptures)
                Toggle("Show a thumbnail after each capture", isOn: $preferences.showsThumbnail)
                Toggle("Show touches in recordings", isOn: $preferences.showsTouches)
                Toggle("Record at 120 fps with sound (needs Screen Recording)", isOn: $preferences.highFrameRate)
                Toggle("Trim recordings before saving", isOn: $preferences.trimsRecordings)
                Toggle("Save for App Store Connect", isOn: $preferences.appStoreMode)
                Toggle("Put screenshots in a device frame", isOn: $preferences.framesScreenshots)
                Picker("Screenshot background", selection: $preferences.background) {
                    ForEach(ScreenshotBackground.allCases) { Text($0.rawValue).tag($0) }
                }
                Picker("Screenshot ratio", selection: $preferences.ratio) {
                    ForEach(ScreenshotRatio.allCases) { Text($0.rawValue).tag($0) }
                }
                TextField("Screenshot title", text: $preferences.screenshotTitle)
                Picker("GIF width", selection: $preferences.gifWidth) {
                    ForEach([320.0, 480, 640, 800], id: \.self) { Text("\(Int($0)) pixels").tag($0) }
                }
            }
            Section("Panel") {
                Picker("Dock the panel", selection: $preferences.panelSide) {
                    ForEach(PanelSide.allCases) { Text($0.rawValue).tag($0) }
                }
                Text("Automatic docks on the right, and moves to the left when there's no room or another tool's panel is already there.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Shortcuts") {
                ForEach(Shortcuts.Action.allCases) { action in
                    ShortcutRecorder(
                        title: action.rawValue,
                        shortcut: shortcuts.shortcuts[action],
                        setShortcut: { shortcuts.set($0, for: action) },
                        pauseShortcut: { shortcuts.pause($0) }
                    )
                }
            }
            Section("Permissions") {
                LabeledContent("Accessibility") {
                    if trusted {
                        Label("Allowed", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    } else {
                        Button("Allow…") { AccessibilityScreenFinder.requestAccess() }
                    }
                }
                Text("Lines overlays up with the device screen exactly, and lets BetterSim shake the device, send memory warnings and slow animations.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section {
                LabeledContent("Version", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev")
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .fixedSize(horizontal: false, vertical: true)
        .onReceive(Timer.publish(every: 2, on: .main, in: .common).autoconnect()) { _ in
            trusted = AccessibilityScreenFinder.isTrusted
        }
    }
}
