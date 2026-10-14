import CoreGraphics
import Foundation

/// One accessibility element on the device screen, in device points.
struct AuditElement: Equatable, Sendable {
    let role: String
    let label: String
    let frame: CGRect

    var isInteractive: Bool {
        DeviceElements.interactiveRoles.contains(role)
    }

    var isText: Bool { role == "AXStaticText" }
}

/// Checks the screen for common accessibility problems, the way Apple's accessibility audits do, from outside the app.
enum AccessibilityAudit {
    struct Finding: Identifiable, Equatable {
        enum Severity: Int, Comparable {
            case warning, error

            static func < (a: Severity, b: Severity) -> Bool { a.rawValue < b.rawValue }
        }

        let id = UUID()
        let severity: Severity
        let title: String
        let detail: String
        let element: AuditElement

        static func == (a: Finding, b: Finding) -> Bool {
            a.severity == b.severity && a.title == b.title && a.element == b.element
        }
    }

    static let minimumTarget: CGFloat = 44
    static let minimumContrast = 4.5

    /// `screenshot` is the device screen at `scale` pixels per point, used for the contrast check.
    static func run(_ elements: [AuditElement], screenshot: CGImage? = nil, scale: CGFloat = 3) -> [Finding] {
        var findings: [Finding] = []
        for element in elements where element.isInteractive {
            let label = element.label.trimmingCharacters(in: .whitespacesAndNewlines)
            if label.isEmpty {
                findings.append(Finding(
                    severity: .error,
                    title: "\(name(of: element.role)) has no label",
                    detail: "VoiceOver can't say what this control does. Add an accessibility label.",
                    element: element
                ))
            }
            if element.frame.width < minimumTarget || element.frame.height < minimumTarget {
                findings.append(Finding(
                    severity: .warning,
                    title: "Small tap target",
                    detail: "\(Int(element.frame.width.rounded())) × \(Int(element.frame.height.rounded())) pt. Apple recommends at least 44 × 44 pt.",
                    element: element
                ))
            }
        }
        let controls = elements.filter { $0.isInteractive && !$0.label.isEmpty }
        for (label, group) in Dictionary(grouping: controls, by: \.label) where group.count > 1 {
            findings.append(Finding(
                severity: .warning,
                title: "\(group.count) controls are called \"\(label)\"",
                detail: "VoiceOver users can't tell them apart. Give each one its own label or hint.",
                element: group[0]
            ))
        }
        if let screenshot {
            for element in elements where element.isText && element.frame.width >= 4 && element.frame.height >= 4 {
                guard let ratio = contrast(in: element.frame, of: screenshot, scale: scale), ratio < minimumContrast else { continue }
                findings.append(Finding(
                    severity: .warning,
                    title: "Low text contrast",
                    detail: String(format: "About %.1f:1. Text needs at least 4.5:1 to be easy to read.", ratio),
                    element: element
                ))
            }
        }
        return findings.sorted { $0.severity == $1.severity ? $0.element.frame.minY < $1.element.frame.minY : $0.severity > $1.severity }
    }

    /// Estimates text contrast from the pixels under the text: the darkest and lightest tenths stand in for the
    /// text and its background.
    static func contrast(in frame: CGRect, of image: CGImage, scale: CGFloat) -> Double? {
        let pixels = CGRect(x: frame.minX * scale, y: frame.minY * scale, width: frame.width * scale, height: frame.height * scale)
            .integral
            .intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard pixels.width >= 2, pixels.height >= 2, let crop = image.cropping(to: pixels) else { return nil }
        let width = crop.width
        let height = crop.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.draw(crop, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }
        var luminances = [Double]()
        luminances.reserveCapacity(width * height)
        for index in stride(from: 0, to: bytes.count, by: 4) {
            luminances.append(luminance(red: bytes[index], green: bytes[index + 1], blue: bytes[index + 2]))
        }
        luminances.sort()
        let dark = luminances[luminances.count / 10]
        let light = luminances[luminances.count * 9 / 10]
        return (light + 0.05) / (dark + 0.05)
    }

    static func luminance(red: UInt8, green: UInt8, blue: UInt8) -> Double {
        func channel(_ value: UInt8) -> Double {
            let c = Double(value) / 255
            return c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(red) + 0.7152 * channel(green) + 0.0722 * channel(blue)
    }

    static func name(of role: String) -> String {
        switch role {
        case "AXButton": "Button"
        case "AXLink": "Link"
        case "AXTextField", "AXSearchField": "Text field"
        case "AXSlider": "Slider"
        case "AXSwitch", "AXCheckBox": "Switch"
        default: "Control"
        }
    }
}
