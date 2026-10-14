import Foundation

/// One value from an app's UserDefaults, as the editor shows it.
enum DefaultsValue: Equatable {
    case string(String)
    case integer(Int)
    case real(Double)
    case bool(Bool)
    case date(Date)
    case data(Int)
    case array(Int)
    case dictionary(Int)

    init(_ value: Any) {
        switch value {
        case let number as NSNumber where CFGetTypeID(number) == CFBooleanGetTypeID(): self = .bool(number.boolValue)
        case let number as NSNumber where CFNumberIsFloatType(number): self = .real(number.doubleValue)
        case let number as NSNumber: self = .integer(number.intValue)
        case let string as String: self = .string(string)
        case let date as Date: self = .date(date)
        case let data as Data: self = .data(data.count)
        case let array as [Any]: self = .array(array.count)
        case let dictionary as [String: Any]: self = .dictionary(dictionary.count)
        default: self = .string(String(describing: value))
        }
    }

    var typeName: String {
        switch self {
        case .string: "String"
        case .integer: "Integer"
        case .real: "Number"
        case .bool: "Boolean"
        case .date: "Date"
        case .data: "Data"
        case .array: "Array"
        case .dictionary: "Dictionary"
        }
    }

    var summary: String {
        switch self {
        case .string(let text): text
        case .integer(let number): String(number)
        case .real(let number): String(number)
        case .bool(let flag): flag ? "YES" : "NO"
        case .date(let date): date.formatted(date: .abbreviated, time: .standard)
        case .data(let bytes): "\(bytes) bytes"
        case .array(let count): "\(count) item\(count == 1 ? "" : "s")"
        case .dictionary(let count): "\(count) key\(count == 1 ? "" : "s")"
        }
    }

    var isEditable: Bool {
        switch self {
        case .string, .integer, .real, .bool: true
        default: false
        }
    }

    /// The flags `defaults write` takes for this value.
    var arguments: [String]? {
        switch self {
        case .string(let text): ["-string", text]
        case .integer(let number): ["-int", String(number)]
        case .real(let number): ["-float", String(number)]
        case .bool(let flag): ["-bool", flag ? "YES" : "NO"]
        default: nil
        }
    }

    /// Reads typed text back as a value of the same type, or nil when it doesn't fit.
    func replaced(with text: String) -> DefaultsValue? {
        switch self {
        case .string: .string(text)
        case .integer: Int(text.trimmingCharacters(in: .whitespaces)).map(DefaultsValue.integer)
        case .real: Double(text.trimmingCharacters(in: .whitespaces)).map(DefaultsValue.real)
        case .bool: ["yes", "true", "1"].contains(text.lowercased()) ? .bool(true) : ["no", "false", "0"].contains(text.lowercased()) ? .bool(false) : nil
        default: nil
        }
    }
}

/// An app's UserDefaults, read and changed through the device's own `defaults` tool. The tool is given the
/// preferences file in the app's container, so the device's preferences daemon stays in charge and the app sees
/// changes as it runs.
enum AppDefaults {
    /// The app's own defaults, or with `group` the shared defaults of one of its App Groups.
    static func domain(_ bundleID: String, udid: String, group: (id: String, url: URL)? = nil) async throws -> String {
        if let group { return group.url.appending(path: "Library/Preferences/\(group.id)").path }
        return try await AppActions.dataContainer(bundleID, on: udid).appending(path: "Library/Preferences/\(bundleID)").path
    }

    static func parse(_ plist: Data) -> [(key: String, value: DefaultsValue)] {
        guard let dictionary = (try? PropertyListSerialization.propertyList(from: plist, format: nil)) as? [String: Any] else { return [] }
        return dictionary.map { ($0.key, DefaultsValue($0.value)) }.sorted { $0.key.localizedStandardCompare($1.key) == .orderedAscending }
    }

    static func load(_ bundleID: String, udid: String, group: (id: String, url: URL)? = nil) async throws -> [(key: String, value: DefaultsValue)] {
        let domain = try await domain(bundleID, udid: udid, group: group)
        return parse(try await Simctl.run(["spawn", udid, "defaults", "export", domain, "-"]))
    }

    static func write(_ value: DefaultsValue, for key: String, bundleID: String, udid: String, group: (id: String, url: URL)? = nil) async throws {
        guard let arguments = value.arguments else { return }
        let domain = try await domain(bundleID, udid: udid, group: group)
        try await Simctl.run(["spawn", udid, "defaults", "write", domain, key] + arguments)
    }

    static func delete(_ key: String?, bundleID: String, udid: String, group: (id: String, url: URL)? = nil) async throws {
        let domain = try await domain(bundleID, udid: udid, group: group)
        do {
            try await Simctl.run(["spawn", udid, "defaults", "delete", domain] + (key.map { [$0] } ?? []))
        } catch let error as SimctlError where error.message.contains("not found") || error.message.contains("does not exist") {
            return
        }
    }
}
