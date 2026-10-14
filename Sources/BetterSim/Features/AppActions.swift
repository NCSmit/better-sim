import Foundation

enum AppActions {
    static func launch(_ bundleID: String, on udid: String) async throws {
        try await Simctl.run(["launch", udid, bundleID])
    }

    static func terminate(_ bundleID: String, on udid: String) async {
        _ = try? await Simctl.run(["terminate", udid, bundleID])
    }

    static func relaunch(_ bundleID: String, on udid: String) async throws {
        try await Simctl.run(["launch", "--terminate-running-process", udid, bundleID])
    }

    /// Relaunches the app as if the device were set to another language, without changing the device itself.
    static func relaunch(_ bundleID: String, on udid: String, in language: Language) async throws {
        try await Simctl.run([
            "launch", "--terminate-running-process", udid, bundleID,
            "-AppleLanguages", "(\(language.code))", "-AppleLocale", language.locale,
        ])
    }

    static func relaunch(_ bundleID: String, on udid: String, inTimeZone timeZone: String) async throws {
        try await Simctl.run(["launch", "--terminate-running-process", udid, bundleID], environment: ["SIMCTL_CHILD_TZ": timeZone])
    }

    static func install(_ app: URL, on udid: String) async throws {
        try await Simctl.run(["install", udid, app.path])
    }

    static func addMedia(_ files: [URL], on udid: String) async throws {
        try await Simctl.run(["addmedia", udid] + files.map(\.path))
    }

    static func trustCertificate(_ file: URL, on udid: String) async throws {
        try await Simctl.run(["keychain", udid, "add-root-cert", file.path])
    }

    static func resetKeychain(on udid: String) async throws {
        try await Simctl.run(["keychain", udid, "reset"])
    }

    static func restart(_ udid: String) async throws {
        _ = try? await Simctl.run(["shutdown", udid])
        try await Simctl.run(["boot", udid])
    }

    static func appBundle(_ bundleID: String, on udid: String) async throws -> URL {
        URL(filePath: try await Simctl.output(["get_app_container", udid, bundleID, "app"]))
    }

    static func dataContainer(_ bundleID: String, on udid: String) async throws -> URL {
        URL(filePath: try await Simctl.output(["get_app_container", udid, bundleID, "data"]))
    }

    static func resetPermissions(_ bundleID: String, on udid: String) async throws {
        try await Simctl.run(["privacy", udid, "reset", "all", bundleID])
    }

    static func setPermission(_ action: PermissionAction, _ service: String, for bundleID: String, on udid: String) async throws {
        try await Simctl.run(["privacy", udid, action.rawValue, service, bundleID])
    }

    /// Copies the clipboard between the Mac and the device.
    static func syncPasteboard(toMac: Bool, udid: String) async throws {
        try await Simctl.run(toMac ? ["pbsync", udid, "host"] : ["pbsync", "host", udid])
    }

    /// Deletes all of the app's UserDefaults. The app is stopped first, so it can't write them straight back.
    static func clearDefaults(_ bundleID: String, on udid: String) async throws {
        await terminate(bundleID, on: udid)
        try await AppDefaults.delete(nil, bundleID: bundleID, udid: udid)
    }

    static func uninstall(_ bundleID: String, on udid: String) async throws {
        try await Simctl.run(["uninstall", udid, bundleID])
    }

    static func open(_ link: String, on udid: String) async throws {
        try await Simctl.run(["openurl", udid, link])
    }

    static func push(_ payload: Data, to bundleID: String, on udid: String) async throws {
        try await Simctl.run(["push", udid, bundleID, "-"], input: payload)
    }
}

enum PermissionAction: String, CaseIterable {
    case grant, revoke, reset
}

enum Permissions {
    static let services: [(id: String, name: String)] = [
        ("all", "All"),
        ("location", "Location"),
        ("location-always", "Location (Always)"),
        ("photos", "Photos"),
        ("photos-add", "Add Photos"),
        ("contacts", "Contacts"),
        ("calendar", "Calendar"),
        ("reminders", "Reminders"),
        ("microphone", "Microphone"),
        ("media-library", "Media Library"),
        ("motion", "Motion"),
        ("siri", "Siri"),
    ]
}

struct Language: Hashable, Identifiable, Sendable {
    let code: String
    let locale: String
    var id: String { code }

    var name: String {
        Locale.current.localizedString(forIdentifier: code) ?? code
    }

    static let common: [Language] = [
        ("en", "en_US"), ("en-GB", "en_GB"), ("nl", "nl_NL"), ("de", "de_DE"), ("fr", "fr_FR"), ("es", "es_ES"),
        ("it", "it_IT"), ("pt-BR", "pt_BR"), ("da", "da_DK"), ("sv", "sv_SE"), ("nb", "nb_NO"), ("fi", "fi_FI"),
        ("pl", "pl_PL"), ("tr", "tr_TR"), ("ru", "ru_RU"), ("ar", "ar_SA"), ("he", "he_IL"), ("hi", "hi_IN"),
        ("ja", "ja_JP"), ("ko", "ko_KR"), ("zh-Hans", "zh_CN"), ("zh-Hant", "zh_TW"),
    ].map { Language(code: $0.0, locale: $0.1) }
}

enum PushPayload {
    enum Problem: LocalizedError, Equatable {
        case notJSON
        case notAnObject
        case missingAPS
        case tooLarge(Int)

        var errorDescription: String? {
            switch self {
            case .notJSON: "The payload isn't valid JSON."
            case .notAnObject: "The payload must be a JSON object."
            case .missingAPS: "The payload needs an \"aps\" dictionary."
            case .tooLarge(let bytes): "The payload is \(bytes) bytes. Push notifications allow 4096."
            }
        }
    }

    static let limit = 4096

    static func validate(_ text: String) -> Result<Data, Problem> {
        let data = Data(text.utf8)
        guard let json = try? JSONSerialization.jsonObject(with: data) else { return .failure(.notJSON) }
        guard let object = json as? [String: Any] else { return .failure(.notAnObject) }
        guard object["aps"] is [String: Any] else { return .failure(.missingAPS) }
        guard data.count <= limit else { return .failure(.tooLarge(data.count)) }
        return .success(data)
    }

    static let templates: [(name: String, json: String)] = [
        ("Alert", """
        {
          "aps": {
            "alert": { "title": "Hello from BetterSim", "body": "This is a test notification." },
            "sound": "default"
          }
        }
        """),
        ("Badge", """
        {
          "aps": { "badge": 3 }
        }
        """),
        ("Silent", """
        {
          "aps": { "content-available": 1 }
        }
        """),
    ]
}

enum DeviceSettings {
    static let textSizes = [
        "extra-small", "small", "medium", "large", "extra-large", "extra-extra-large", "extra-extra-extra-large",
        "accessibility-medium", "accessibility-large", "accessibility-extra-large",
        "accessibility-extra-extra-large", "accessibility-extra-extra-extra-large",
    ]

    static let cleanStatusBar = [
        "--time", "9:41",
        "--dataNetwork", "wifi", "--wifiMode", "active", "--wifiBars", "3",
        "--cellularMode", "active", "--cellularBars", "4", "--operatorName", "",
        "--batteryState", "charged", "--batteryLevel", "100",
    ]

    static func appearance(_ udid: String) async -> String? {
        try? await Simctl.output(["ui", udid, "appearance"])
    }

    static func setAppearance(_ style: String, on udid: String) async throws {
        try await Simctl.run(["ui", udid, "appearance", style])
    }

    static func textSize(_ udid: String) async -> String? {
        try? await Simctl.output(["ui", udid, "content_size"])
    }

    static func setTextSize(_ size: String, on udid: String) async throws {
        try await Simctl.run(["ui", udid, "content_size", size])
    }

    static func increasedContrast(_ udid: String) async -> Bool {
        (try? await Simctl.output(["ui", udid, "increase_contrast"])) == "enabled"
    }

    static func setIncreasedContrast(_ on: Bool, on udid: String) async throws {
        try await Simctl.run(["ui", udid, "increase_contrast", on ? "enabled" : "disabled"])
    }

    static func hasStatusBarOverrides(_ listing: String) -> Bool {
        listing.split(separator: "\n").contains { line in
            let text = line.trimmingCharacters(in: .whitespaces)
            return !text.isEmpty && !text.hasPrefix("Current Status Bar Overrides") && !text.allSatisfy { $0 == "=" }
        }
    }

    static func statusBarIsClean(_ udid: String) async -> Bool {
        hasStatusBarOverrides((try? await Simctl.output(["status_bar", udid, "list"])) ?? "")
    }

    static func setCleanStatusBar(_ on: Bool, on udid: String) async throws {
        try await Simctl.run(on ? ["status_bar", udid, "override"] + cleanStatusBar : ["status_bar", udid, "clear"])
    }

    static func setStatusBar(_ style: StatusBarStyle, on udid: String) async throws {
        try await Simctl.run(["status_bar", udid, "override"] + style.arguments)
    }

    static func setLocation(_ coordinate: Coordinate, on udid: String) async throws {
        try await Simctl.run(["location", udid, "set", coordinate.argument])
    }

    static func clearLocation(on udid: String) async throws {
        try await Simctl.run(["location", udid, "clear"])
    }
}

struct Coordinate: Hashable, Codable, Sendable {
    let latitude: Double
    let longitude: Double

    var argument: String {
        String(format: "%.6f,%.6f", locale: Locale(identifier: "en_US_POSIX"), latitude, longitude)
    }

    init(latitude: Double, longitude: Double) {
        self.latitude = latitude
        self.longitude = longitude
    }

    /// Accepts "52.37, 4.89" and similar.
    init?(_ text: String) {
        let parts = text.split(whereSeparator: { $0 == "," || $0 == " " }).compactMap { Double($0) }
        guard parts.count == 2, (-90...90).contains(parts[0]), (-180...180).contains(parts[1]) else { return nil }
        self.init(latitude: parts[0], longitude: parts[1])
    }

    static let places: [(name: String, coordinate: Coordinate)] = [
        ("Apple Park", Coordinate(latitude: 37.334900, longitude: -122.009020)),
        ("Amsterdam", Coordinate(latitude: 52.373169, longitude: 4.890660)),
        ("London", Coordinate(latitude: 51.507351, longitude: -0.127758)),
        ("New York", Coordinate(latitude: 40.712776, longitude: -74.005974)),
        ("Tokyo", Coordinate(latitude: 35.676192, longitude: 139.650311)),
        ("Sydney", Coordinate(latitude: -33.868820, longitude: 151.209290)),
    ]
}

/// Accessibility settings simctl has no command for. The device keeps them in its com.apple.Accessibility
/// preferences, and posting the matching notification makes running apps pick a change up straight away.
enum AccessibilityToggle: String, CaseIterable, Identifiable, Sendable {
    case boldText = "Bold Text"
    case reduceMotion = "Reduce Motion"
    case reduceTransparency = "Reduce Transparency"
    case buttonShapes = "Button Shapes"
    case differentiateWithoutColour = "Differentiate Without Colour"

    var id: String { rawValue }

    var key: String {
        switch self {
        case .boldText: "EnhancedTextLegibilityEnabled"
        case .reduceMotion: "ReduceMotionEnabled"
        case .reduceTransparency: "EnhancedBackgroundContrastEnabled"
        case .buttonShapes: "ButtonShapesEnabled"
        case .differentiateWithoutColour: "DifferentiateWithoutColor"
        }
    }

    var notification: String {
        switch self {
        case .boldText: "com.apple.accessibility.cache.enhance.text.legibility"
        case .reduceMotion: "com.apple.accessibility.cache.reduce.motion"
        case .reduceTransparency: "com.apple.accessibility.cache.enhance.background.contrast"
        case .buttonShapes: "com.apple.accessibility.cache.button.shapes"
        case .differentiateWithoutColour: "com.apple.accessibility.cache.differentiate.without.color"
        }
    }

    static func enabled(in plist: Data) -> Set<AccessibilityToggle> {
        guard let settings = (try? PropertyListSerialization.propertyList(from: plist, format: nil)) as? [String: Any] else { return [] }
        return Set(allCases.filter { (settings[$0.key] as? NSNumber)?.boolValue == true })
    }

    static func enabled(on udid: String) async -> Set<AccessibilityToggle> {
        guard let plist = try? await Simctl.run(["spawn", udid, "defaults", "export", "com.apple.Accessibility", "-"]) else { return [] }
        return enabled(in: plist)
    }

    func set(_ on: Bool, on udid: String) async throws {
        try await Simctl.run(["spawn", udid, "defaults", "write", "com.apple.Accessibility", key, "-bool", on ? "YES" : "NO"])
        try await Simctl.run(["spawn", udid, "notifyutil", "-p", notification])
    }
}
