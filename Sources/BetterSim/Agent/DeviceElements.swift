import ApplicationServices
import Foundation
import os

private let log = Logger(subsystem: "local.bettersim", category: "elements")

/// One accessibility element on the device screen, as the Simulator exposes it. The frame is in device points,
/// measured from the screen's top-left corner.
struct DeviceElement: Codable, Equatable, Sendable {
    struct Frame: Codable, Equatable, Sendable {
        var x: Double
        var y: Double
        var width: Double
        var height: Double

        init(_ rect: CGRect) {
            x = Self.rounded(rect.minX)
            y = Self.rounded(rect.minY)
            width = Self.rounded(rect.width)
            height = Self.rounded(rect.height)
        }

        var rect: CGRect { CGRect(x: x, y: y, width: width, height: height) }

        private static func rounded(_ value: CGFloat) -> Double { (Double(value) * 10).rounded() / 10 }
    }

    var role: String
    var label: String?
    var value: String?
    var identifier: String?
    var frame: Frame

    /// Where a tap lands on the element: the middle of the part that's on screen.
    func tapPoint(within size: CGSize) -> CGPoint {
        let visible = frame.rect.intersection(CGRect(origin: .zero, size: size))
        let rect = visible.isNull ? frame.rect : visible
        return CGPoint(x: rect.midX, y: rect.midY)
    }
}

enum DeviceElements {
    static let interactiveRoles: Set<String> = [
        "AXButton", "AXLink", "AXTextField", "AXSecureTextField", "AXSearchField", "AXTextArea", "AXCheckBox",
        "AXSwitch", "AXRadioButton", "AXSlider", "AXIncrementor", "AXPopUpButton", "AXMenuButton", "AXComboBox",
        "AXCell", "AXTab",
    ]

    /// Reads every element over the device screen, in the order the Simulator lists them, which is reading order.
    static func read(simulator pid: pid_t, window: CGRect, screen: DeviceScreen, limit: Int = 3000) throws -> [DeviceElement] {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 2)
        let windows = AXTree.elements(app, kAXWindowsAttribute)
        guard let root = windows.first(where: { AXTree.frame(of: $0).map { AXTree.distance($0, window) < 4 } ?? false }) else {
            throw AgentFailure(.noWindow, "BetterSim couldn't read the Simulator window. Make sure it's on screen.")
        }
        var found: [DeviceElement] = []
        var stack = [(element: root, depth: 0)]
        var visited = 0
        while let next = stack.popLast(), visited < limit {
            visited += 1
            let node = AXTree.node(next.element)
            if let element = deviceElement(node, on: screen) { found.append(element) }
            if next.depth < 64 { stack += node.children.reversed().map { ($0, next.depth + 1) } }
        }
        if found.isEmpty {
            found = hitTestedElements(app: app, screen: screen)
            log.info("the tree had no elements on the screen; hit testing found \(found.count)")
        }
        return found
    }

    /// Leaves out empty containers: keeps what has a label, value or identifier, or can be used.
    static func meaningful(_ elements: [DeviceElement]) -> [DeviceElement] {
        elements.filter { $0.label != nil || $0.value != nil || $0.identifier != nil || interactiveRoles.contains($0.role) }
    }

    /// The element someone means by `text`: an exact label, identifier or value first, then a label or value that
    /// contains it. Among equals, something that can be used wins, then the first in reading order.
    static func match(_ text: String, in elements: [DeviceElement]) -> DeviceElement? {
        let wanted = folded(text)
        guard !wanted.isEmpty else { return nil }
        let tiers: [(DeviceElement) -> Bool] = [
            { folded($0.label) == wanted },
            { $0.identifier == text },
            { folded($0.value) == wanted },
            { folded($0.label).contains(wanted) },
            { folded($0.value).contains(wanted) },
        ]
        for tier in tiers {
            let candidates = elements.filter(tier)
            if let best = candidates.first(where: { interactiveRoles.contains($0.role) }) ?? candidates.first { return best }
        }
        return nil
    }

    private static func folded(_ text: String?) -> String {
        (text ?? "")
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }

    /// Keeps elements that are on the screen, leaving out the window's own controls and the screen view itself.
    private static func deviceElement(_ node: AXTree.Node, on screen: DeviceScreen) -> DeviceElement? {
        guard let frame = node.frame, frame.width > 0, frame.height > 0,
              frame.intersects(screen.frame),
              frame.width <= screen.frame.width + 1, frame.height <= screen.frame.height + 1,
              AXTree.distance(frame, screen.frame) > 2
        else { return nil }
        return DeviceElement(
            role: node.role ?? "AXUnknown",
            label: node.label,
            value: node.value,
            identifier: node.identifier,
            frame: DeviceElement.Frame(screen.deviceRect(frame))
        )
    }

    /// Some elements only show up when the Simulator is asked what's at a point, so this samples the screen on a grid.
    private static func hitTestedElements(app: AXUIElement, screen: DeviceScreen, spacing: CGFloat = 24) -> [DeviceElement] {
        var seen: [AXUIElement] = []
        var found: [DeviceElement] = []
        for y in stride(from: spacing / 2, to: screen.size.height, by: spacing) {
            for x in stride(from: spacing / 2, to: screen.size.width, by: spacing) {
                let point = screen.screenPoint(CGPoint(x: x, y: y))
                var hit: AXUIElement?
                guard AXUIElementCopyElementAtPosition(app, Float(point.x), Float(point.y), &hit) == .success, let hit,
                      !seen.contains(where: { CFEqual($0, hit) })
                else { continue }
                seen.append(hit)
                if let element = deviceElement(AXTree.node(hit), on: screen) { found.append(element) }
            }
        }
        return found.sorted { ($0.frame.y, $0.frame.x) < ($1.frame.y, $1.frame.x) }
    }
}

/// Small wrappers around the Accessibility C API.
enum AXTree {
    struct Node {
        var role: String?
        var label: String?
        var value: String?
        var identifier: String?
        var frame: CGRect?
        var children: [AXUIElement] = []
    }

    private static let nodeAttributes = [
        kAXRoleAttribute, kAXDescriptionAttribute, kAXTitleAttribute, "AXLabel", kAXValueAttribute, "AXIdentifier",
        kAXPositionAttribute, kAXSizeAttribute, kAXChildrenAttribute,
    ]

    /// Reads everything about an element in one round trip, which matters for the Simulator's large trees, and falls
    /// back to one attribute at a time for elements that don't support that.
    static func node(_ element: AXUIElement) -> Node {
        var values: CFArray?
        let present: [AnyObject?]
        if AXUIElementCopyMultipleAttributeValues(element, nodeAttributes as CFArray, AXCopyMultipleAttributeOptions(rawValue: 0), &values) == .success,
           let list = values as? [AnyObject], list.count == nodeAttributes.count {
            present = list.map { isError($0) ? nil : $0 }
        } else {
            present = nodeAttributes.map { value(element, $0) }
        }
        let origin = present[6].flatMap(point)
        let extent = present[7].flatMap(size)
        return Node(
            role: present[0] as? String,
            label: present[1...3].lazy.compactMap { text($0) }.first,
            value: text(present[4]),
            identifier: text(present[5]),
            frame: origin.flatMap { origin in extent.map { CGRect(origin: origin, size: $0) } },
            children: present[8] as? [AXUIElement] ?? []
        )
    }

    static func value(_ element: AXUIElement, _ attribute: String) -> AnyObject? {
        var value: AnyObject?
        return AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success ? value : nil
    }

    static func elements(_ element: AXUIElement, _ attribute: String) -> [AXUIElement] {
        value(element, attribute) as? [AXUIElement] ?? []
    }

    static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        text(value(element, attribute))
    }

    static func frame(of element: AXUIElement) -> CGRect? {
        guard let origin = value(element, kAXPositionAttribute).flatMap(point),
              let extent = value(element, kAXSizeAttribute).flatMap(size)
        else { return nil }
        return CGRect(origin: origin, size: extent)
    }

    static func distance(_ a: CGRect, _ b: CGRect) -> CGFloat {
        abs(a.minX - b.minX) + abs(a.minY - b.minY) + abs(a.width - b.width) + abs(a.height - b.height)
    }

    private static func isError(_ value: AnyObject) -> Bool {
        CFGetTypeID(value) == AXValueGetTypeID() && AXValueGetType(value as! AXValue) == .axError
    }

    private static func point(_ value: AnyObject) -> CGPoint? {
        guard CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        return AXValueGetValue(value as! AXValue, .cgPoint, &point) ? point : nil
    }

    private static func size(_ value: AnyObject) -> CGSize? {
        guard CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var size = CGSize.zero
        return AXValueGetValue(value as! AXValue, .cgSize, &size) ? size : nil
    }

    private static func text(_ value: AnyObject?) -> String? {
        let string: String? = switch value {
        case let text as String: text
        case let attributed as NSAttributedString: attributed.string
        case let number as NSNumber: number.stringValue
        default: nil
        }
        let trimmed = string?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }
}
