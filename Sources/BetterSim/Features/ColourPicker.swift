import AppKit

enum ColourFormat: String, CaseIterable, Identifiable {
    case hex = "Hex"
    case swiftUI = "SwiftUI"
    case uiKit = "UIKit"

    var id: String { rawValue }

    func text(red: Double, green: Double, blue: Double, alpha: Double) -> String {
        let channels = [red, green, blue].map { String(format: "%.3f", locale: Locale(identifier: "en_US_POSIX"), $0) }
        switch self {
        case .hex:
            let bytes = [red, green, blue].map { Int(($0 * 255).rounded()) }
            return String(format: "#%02X%02X%02X", bytes[0], bytes[1], bytes[2])
        case .swiftUI:
            return "Color(red: \(channels[0]), green: \(channels[1]), blue: \(channels[2]))"
        case .uiKit:
            return "UIColor(red: \(channels[0]), green: \(channels[1]), blue: \(channels[2]), alpha: \(String(format: "%.2f", locale: Locale(identifier: "en_US_POSIX"), alpha)))"
        }
    }
}

/// Picks a colour from anywhere on screen with the system magnifier, which needs no permission, and copies it as code.
enum ColourPicker {
    @MainActor
    static func pick(as format: ColourFormat, done: @escaping @MainActor (String) -> Void) {
        NSColorSampler().show { picked in
            guard let colour = picked?.usingColorSpace(.sRGB) else { return }
            let text = format.text(
                red: colour.redComponent, green: colour.greenComponent, blue: colour.blueComponent, alpha: colour.alphaComponent
            )
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            MainActor.assumeIsolated { done(text) }
        }
    }
}
