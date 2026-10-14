import AppKit
import ApplicationServices
import Carbon.HIToolbox

/// Taps, swipes and typing, sent the way a mouse and keyboard reach the Simulator. Posting events needs the same
/// Accessibility access as reading the screen.
@MainActor
enum DeviceInput {
    static func tap(_ point: CGPoint, on target: DeviceTarget) async throws {
        let location = try await prepare(target, at: [point]).first ?? .zero
        await withCursorRestored {
            postMouse(.mouseMoved, at: location)
            postMouse(.leftMouseDown, at: location)
            await pause(0.06)
            postMouse(.leftMouseUp, at: location)
        }
    }

    static func swipe(from start: CGPoint, to end: CGPoint, duration: Double, on target: DeviceTarget) async throws {
        let locations = try await prepare(target, at: [start, end])
        let from = locations[0]
        let to = locations[1]
        let steps = max(2, Int(duration * 60))
        await withCursorRestored {
            postMouse(.mouseMoved, at: from)
            postMouse(.leftMouseDown, at: from)
            for step in 1...steps {
                await pause(duration / Double(steps))
                let progress = Double(step) / Double(steps)
                postMouse(.leftMouseDragged, at: CGPoint(x: from.x + (to.x - from.x) * progress, y: from.y + (to.y - from.y) * progress))
            }
            postMouse(.leftMouseUp, at: to)
        }
    }

    /// Types with the keys that make each character on the Mac's keyboard layout. The Simulator hands key codes to
    /// the device, which reads them with the same layout, so a character with no key can't be typed this way.
    static func type(_ text: String, on target: DeviceTarget) async throws {
        guard let layout = KeyboardLayout.current() else {
            throw AgentFailure(.failed, "BetterSim couldn't read your Mac's keyboard layout.")
        }
        let strokes = try text.map { character in
            guard let stroke = layout.keystroke(for: character) else {
                throw AgentFailure(.usage, "BetterSim can't type “\(character)”, because no key on your Mac's keyboard layout makes it.")
            }
            return (character, stroke)
        }
        try await bringToFront(target)
        let source = CGEventSource(stateID: .hidSystemState)
        for (character, stroke) in strokes {
            if stroke.shift { postShift(source, down: true, to: target.simulator) }
            postKey(source, stroke, character, down: true, to: target.simulator)
            await pause(0.012)
            postKey(source, stroke, character, down: false, to: target.simulator)
            if stroke.shift { postShift(source, down: false, to: target.simulator) }
            await pause(0.012)
        }
    }

    /// Brings the device's window to the front and works out where each device point is on the Mac, refusing points
    /// that would land on another window.
    private static func prepare(_ target: DeviceTarget, at points: [CGPoint]) async throws -> [CGPoint] {
        let size = target.screen.size
        if let outside = points.first(where: { !target.screen.contains($0) }) {
            throw AgentFailure(.usage, "\(Format.point(outside)) is outside the screen, which is \(Format.number(size.width)) by \(Format.number(size.height)) points.")
        }
        try await bringToFront(target)
        let locations = points.map(target.screen.screenPoint)
        for location in locations {
            var displays: UInt32 = 0
            guard CGGetDisplaysWithPoint(location, 0, nil, &displays) == .success, displays > 0 else {
                throw AgentFailure(.noWindow, "Part of \(target.device.name)'s screen is off the edge of your displays. Move the Simulator window fully on screen, then try again.")
            }
            if let owner = coveringApp(at: location, simulator: target.simulator) {
                throw AgentFailure(.noWindow, "\(owner) is covering the Simulator there. Move it out of the way, then try again.")
            }
        }
        return locations
    }

    static func bringToFront(_ target: DeviceTarget) async throws {
        if isInFront(target) { return }
        let app = AXUIElementCreateApplication(target.simulator)
        AXUIElementSetAttributeValue(app, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
        let windows = AXTree.elements(app, kAXWindowsAttribute)
        if let window = windows.first(where: { AXTree.frame(of: $0).map { AXTree.distance($0, target.window.frame) < 4 } ?? false }) {
            AXUIElementPerformAction(window, kAXRaiseAction as CFString)
            AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
        }
        for _ in 0..<20 {
            await pause(0.05)
            if isInFront(target) {
                await pause(0.1)
                return
            }
        }
        throw AgentFailure(.noWindow, "The Simulator didn't come to the front. Click \(target.device.name)'s window once, then try again.")
    }

    private static func isInFront(_ target: DeviceTarget) -> Bool {
        NSWorkspace.shared.frontmostApplication?.processIdentifier == target.simulator
            && SimulatorWindows.windows().first?.id == target.window.id
    }

    /// The app whose ordinary window is in front of the Simulator at `point`. Floating panels are ignored, because
    /// many of them let clicks through.
    static func coveringApp(at point: CGPoint, simulator: pid_t) -> String? {
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        for window in windows {
            guard window[kCGWindowLayer as String] as? Int == 0,
                  (window[kCGWindowAlpha as String] as? Double ?? 1) > 0,
                  let bounds = window[kCGWindowBounds as String],
                  let frame = CGRect(dictionaryRepresentation: bounds as! CFDictionary),
                  frame.contains(point)
            else { continue }
            guard window[kCGWindowOwnerPID as String] as? pid_t != simulator else { return nil }
            return window[kCGWindowOwnerName as String] as? String ?? "Another window"
        }
        return nil
    }

    /// Puts the pointer back where the person left it once the events are sent.
    private static func withCursorRestored(_ body: () async -> Void) async {
        let original = CGEvent(source: nil)?.location
        await body()
        if let original {
            CGWarpMouseCursorPosition(original)
            CGAssociateMouseAndMouseCursorPosition(1)
        }
    }

    private static func postMouse(_ type: CGEventType, at point: CGPoint) {
        let event = CGEvent(mouseEventSource: CGEventSource(stateID: .hidSystemState), mouseType: type, mouseCursorPosition: point, mouseButton: .left)
        event?.setIntegerValueField(.mouseEventClickState, value: 1)
        event?.post(tap: .cghidEventTap)
    }

    private static func postKey(_ source: CGEventSource?, _ stroke: KeyboardLayout.Keystroke, _ character: Character, down: Bool, to pid: pid_t) {
        guard let event = CGEvent(keyboardEventSource: source, virtualKey: stroke.keyCode, keyDown: down) else { return }
        event.flags = stroke.shift ? .maskShift : []
        let units = Array(String(character).utf16)
        event.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
        event.postToPid(pid)
    }

    /// The Simulator follows modifier keys through their own events, so Shift is pressed and released around a key.
    private static func postShift(_ source: CGEventSource?, down: Bool, to pid: pid_t) {
        guard let event = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_Shift), keyDown: down) else { return }
        event.type = .flagsChanged
        event.flags = down ? .maskShift : []
        event.postToPid(pid)
    }

    /// Waits without throwing, so a button that went down always comes back up.
    private static func pause(_ seconds: Double) async {
        try? await Task.sleep(for: .seconds(seconds))
    }
}

/// Which key, with or without Shift, makes each character on a keyboard layout.
struct KeyboardLayout: Sendable {
    struct Keystroke: Equatable, Sendable {
        let keyCode: CGKeyCode
        let shift: Bool
    }

    /// The main block, then the extra keys on ISO and JIS keyboards. Keypad keys are left out, because the device
    /// reads them as keypad keys.
    static let typingKeys: [CGKeyCode] = Array(0...50) + [93, 94]

    private var keystrokes: [Character: Keystroke] = [:]

    /// `translate` gives the text a key makes, with or without Shift. Keys without Shift win over keys with it.
    init(translate: (CGKeyCode, Bool) -> String?) {
        for shift in [false, true] {
            for code in Self.typingKeys {
                guard let text = translate(code, shift), text.count == 1, let character = text.first,
                      keystrokes[character] == nil
                else { continue }
                keystrokes[character] = Keystroke(keyCode: code, shift: shift)
            }
        }
        for newline in ["\n", "\r", "\r\n"] as [Character] {
            keystrokes[newline] = Keystroke(keyCode: CGKeyCode(kVK_Return), shift: false)
        }
        keystrokes["\t"] = Keystroke(keyCode: CGKeyCode(kVK_Tab), shift: false)
        keystrokes[" "] = Keystroke(keyCode: CGKeyCode(kVK_Space), shift: false)
    }

    func keystroke(for character: Character) -> Keystroke? {
        keystrokes[character]
    }

    @MainActor
    static func current() -> KeyboardLayout? {
        let sources = [TISCopyCurrentKeyboardLayoutInputSource(), TISCopyCurrentASCIICapableKeyboardLayoutInputSource()]
            .compactMap { $0?.takeRetainedValue() }
        guard let data = sources.lazy.compactMap(layoutData).first else { return nil }
        return KeyboardLayout { code, shift in translate(code, shift: shift, layout: data) }
    }

    private static func layoutData(_ source: TISInputSource) -> CFData? {
        guard let pointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        return Unmanaged<CFData>.fromOpaque(pointer).takeUnretainedValue()
    }

    private static func translate(_ code: CGKeyCode, shift: Bool, layout: CFData) -> String? {
        var deadKeyState: UInt32 = 0
        var characters = [UniChar](repeating: 0, count: 4)
        var length = 0
        let modifiers = shift ? UInt32((shiftKey >> 8) & 0xFF) : 0
        let status = CFDataGetBytePtr(layout).withMemoryRebound(to: UCKeyboardLayout.self, capacity: 1) {
            UCKeyTranslate(
                $0, code, UInt16(kUCKeyActionDown), modifiers, UInt32(LMGetKbdType()),
                OptionBits(kUCKeyTranslateNoDeadKeysMask), &deadKeyState, characters.count, &length, &characters
            )
        }
        guard status == noErr, length > 0 else { return nil }
        return String(utf16CodeUnits: characters, count: length)
    }
}

enum Format {
    static func number(_ value: Double) -> String {
        guard value.isFinite else { return "\(value)" }
        let rounded = (value * 10).rounded() / 10
        return rounded == rounded.rounded() ? String(Int(rounded)) : String(format: "%.1f", locale: Locale(identifier: "en_US_POSIX"), rounded)
    }

    static func number(_ value: CGFloat) -> String {
        number(Double(value))
    }

    static func point(_ point: CGPoint) -> String {
        "\(number(point.x)), \(number(point.y))"
    }
}
