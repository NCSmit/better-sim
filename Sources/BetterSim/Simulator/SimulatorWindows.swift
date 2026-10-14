import AppKit
import ApplicationServices
import os

private let log = Logger(subsystem: "local.bettersim", category: "windows")

struct SimulatorWindow: Equatable {
    let id: CGWindowID
    /// Top-left origin, in global screen points, like CGWindowList and the Accessibility API.
    let frame: CGRect
}

enum SimulatorWindows {
    static let bundleID = "com.apple.iphonesimulator"

    static var app: NSRunningApplication? {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first
    }

    static var isFrontmost: Bool {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier == bundleID
    }

    /// The Simulator's on-screen windows, frontmost first. Reading frames needs no permission; titles would.
    static func windows() -> [SimulatorWindow] {
        guard let pid = app?.processIdentifier else { return [] }
        let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] ?? []
        return info.compactMap { window in
            guard window[kCGWindowOwnerPID as String] as? pid_t == pid,
                  window[kCGWindowLayer as String] as? Int == 0,
                  let number = window[kCGWindowNumber as String] as? CGWindowID,
                  let bounds = window[kCGWindowBounds as String],
                  let frame = CGRect(dictionaryRepresentation: bounds as! CFDictionary),
                  frame.width > 120, frame.height > 120
            else { return nil }
            return SimulatorWindow(id: number, frame: frame)
        }
    }

    /// The device the Simulator treats as current, which is the one in its frontmost device window.
    static var currentDeviceUDID: String? {
        CFPreferencesAppSynchronize(bundleID as CFString)
        return CFPreferencesCopyAppValue("CurrentDeviceUDID" as CFString, bundleID as CFString) as? String
    }

    /// Converts a top-left-origin rect to AppKit's bottom-left-origin global coordinates.
    @MainActor static func appKitFrame(_ rect: CGRect) -> NSRect {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        return NSRect(x: rect.minX, y: primaryHeight - rect.maxY, width: rect.width, height: rect.height)
    }
}

/// Asks the Simulator's accessibility tree where the device screen is. Exact, but only works once the user has
/// allowed BetterSim under Privacy & Security → Accessibility. Otherwise ScreenGeometry's estimate is used.
enum AccessibilityScreenFinder {
    static var isTrusted: Bool { AXIsProcessTrusted() }

    @MainActor static func requestAccess() {
        let prompt = "AXTrustedCheckOptionPrompt" as CFString
        _ = AXIsProcessTrustedWithOptions([prompt: true] as CFDictionary)
    }

    static func screenFrame(in window: CGRect, aspect: CGSize, pid: pid_t) -> CGRect? {
        guard isTrusted else { return nil }
        let app = AXUIElementCreateApplication(pid)
        let windows = value(app, kAXWindowsAttribute) as? [AXUIElement] ?? []
        guard let match = windows.first(where: { frame(of: $0).map { distance($0, window) < 4 } ?? false }) else {
            return nil
        }
        var best: CGRect?
        var tree: [String] = []
        visit(match, depth: 0) { element in
            guard let rect = frame(of: element) else { return }
            tree.append("\(value(element, kAXRoleAttribute) as? String ?? "?") \(rect.debugDescription)")
            guard rect.width > 40, rect.height > 40 else { return }
            let portrait = abs(rect.width / rect.height - aspect.width / aspect.height) < 0.01
            let landscape = abs(rect.width / rect.height - aspect.height / aspect.width) < 0.01
            if (portrait || landscape), rect.width * rect.height > (best.map { $0.width * $0.height } ?? 0) {
                best = rect
            }
        }
        log.info("accessibility tree for window \(window.debugDescription): \(tree.prefix(40).joined(separator: " | "))")
        if let best { log.info("accessibility screen \(best.debugDescription) in window \(window.debugDescription)") }
        return best
    }

    private static func visit(_ element: AXUIElement, depth: Int, _ body: (AXUIElement) -> Void) {
        body(element)
        guard depth < 8 else { return }
        for child in value(element, kAXChildrenAttribute) as? [AXUIElement] ?? [] {
            visit(child, depth: depth + 1, body)
        }
    }

    private static func value(_ element: AXUIElement, _ attribute: String) -> AnyObject? {
        var value: AnyObject?
        return AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success ? value : nil
    }

    private static func frame(of element: AXUIElement) -> CGRect? {
        guard let position = value(element, kAXPositionAttribute), let size = value(element, kAXSizeAttribute) else {
            return nil
        }
        var origin = CGPoint.zero
        var extent = CGSize.zero
        AXValueGetValue(position as! AXValue, .cgPoint, &origin)
        AXValueGetValue(size as! AXValue, .cgSize, &extent)
        return CGRect(origin: origin, size: extent)
    }

    private static func distance(_ a: CGRect, _ b: CGRect) -> CGFloat {
        abs(a.minX - b.minX) + abs(a.minY - b.minY) + abs(a.width - b.width) + abs(a.height - b.height)
    }
}
