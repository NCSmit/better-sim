import AppKit

/// Global keyboard shortcuts for the actions people repeat most, which work from any app.
@MainActor
final class Shortcuts: ObservableObject {
    enum Action: String, CaseIterable, Identifiable {
        case screenshot = "Take Screenshot"
        case recordMP4 = "Record MP4"
        case recordGIF = "Record GIF"
        case togglePanel = "Show or Hide Panel"

        var id: String { rawValue }
    }

    @Published private(set) var shortcuts: [Action: Shortcut] = [:]
    private var hotkeys: [Action: Hotkey] = [:]
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard, perform: @escaping @MainActor (Action) -> Void) {
        self.defaults = defaults
        let saved = defaults.dictionary(forKey: "shortcuts") as? [String: [UInt32]] ?? [:]
        for action in Action.allCases {
            let hotkey = Hotkey { perform(action) }
            hotkeys[action] = hotkey
            if let pair = saved[action.rawValue], pair.count == 2 {
                let shortcut = Shortcut(keyCode: pair[0], modifiers: pair[1])
                if hotkey.register(shortcut) { shortcuts[action] = shortcut }
            }
        }
    }

    func set(_ shortcut: Shortcut?, for action: Action) -> Bool {
        guard hotkeys[action]?.register(shortcut) == true else { return false }
        shortcuts[action] = shortcut
        defaults.set(
            Dictionary(uniqueKeysWithValues: shortcuts.map { ($0.key.rawValue, [$0.value.keyCode, $0.value.modifiers]) }),
            forKey: "shortcuts"
        )
        return true
    }

    /// Lets a shortcut be recorded again without it firing.
    func pause(_ paused: Bool) {
        for (action, hotkey) in hotkeys {
            _ = hotkey.register(paused ? nil : shortcuts[action])
        }
    }
}
