import Foundation

struct SimDevice: Identifiable, Hashable, Sendable {
    let udid: String
    let name: String
    let state: String
    let deviceTypeIdentifier: String
    let runtime: String

    var id: String { udid }
    var isBooted: Bool { state == "Booted" }
    var title: String { "\(name) · \(runtime)" }

    static func runtimeName(_ identifier: String) -> String {
        let name = identifier.components(separatedBy: "SimRuntime.").last ?? identifier
        let parts = name.split(separator: "-")
        guard let platform = parts.first, parts.count > 1 else { return name }
        let os = platform == "xrOS" ? "visionOS" : String(platform)
        return "\(os) \(parts.dropFirst().joined(separator: "."))"
    }

    static func parseList(_ data: Data) throws -> [SimDevice] {
        struct Entry: Decodable {
            let udid: String
            let name: String
            let state: String
            let deviceTypeIdentifier: String?
            let isAvailable: Bool?
        }
        let list = try JSONDecoder().decode([String: [String: [Entry]]].self, from: data)
        return (list["devices"] ?? [:])
            .flatMap { runtime, entries in
                entries.filter { $0.isAvailable != false }.map {
                    SimDevice(
                        udid: $0.udid,
                        name: $0.name,
                        state: $0.state,
                        deviceTypeIdentifier: $0.deviceTypeIdentifier ?? "",
                        runtime: runtimeName(runtime)
                    )
                }
            }
            .sorted { ($0.isBooted ? 0 : 1, $0.name, $0.runtime) < ($1.isBooted ? 0 : 1, $1.name, $1.runtime) }
    }

    static func all() async throws -> [SimDevice] {
        try parseList(try await Simctl.run(["list", "devices", "--json"]))
    }
}

struct InstalledApp: Identifiable, Hashable, Sendable {
    let bundleID: String
    let name: String
    let version: String?
    let build: String?
    let dataContainer: URL?
    let bundle: URL?

    var id: String { bundleID }

    static func parseList(_ data: Data) throws -> [InstalledApp] {
        let plist = try PropertyListSerialization.propertyList(from: data, format: nil)
        guard let apps = plist as? [String: [String: Any]] else { return [] }
        return apps.compactMap { bundleID, info in
            guard info["ApplicationType"] as? String == "User" else { return nil }
            let name = info["CFBundleDisplayName"] as? String ?? info["CFBundleName"] as? String ?? bundleID
            return InstalledApp(
                bundleID: bundleID,
                name: name,
                version: info["CFBundleShortVersionString"] as? String,
                build: info["CFBundleVersion"] as? String,
                dataContainer: (info["DataContainer"] as? String).flatMap(URL.init(string:)),
                bundle: (info["Path"] as? String).map { URL(filePath: $0) }
            )
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    static func all(on udid: String) async throws -> [InstalledApp] {
        try parseList(try await Simctl.run(["listapps", udid]))
    }

    var versionText: String {
        switch (version, build) {
        case let (version?, build?) where version != build: "Version \(version) (\(build))"
        case let (version?, _): "Version \(version)"
        case let (nil, build?): "Build \(build)"
        default: bundleID
        }
    }

    /// The largest home screen icon the app bundle carries as a plain PNG, which Xcode always copies in.
    var iconFile: URL? {
        guard let bundle,
              let files = try? FileManager.default.contentsOfDirectory(at: bundle, includingPropertiesForKeys: [.fileSizeKey])
        else { return nil }
        return files
            .filter { $0.lastPathComponent.hasPrefix("AppIcon") && $0.pathExtension == "png" && !$0.lastPathComponent.contains("~ipad") }
            .max { ($0.fileSize ?? 0) < ($1.fileSize ?? 0) }
    }
}

private extension URL {
    var fileSize: Int? { try? resourceValues(forKeys: [.fileSizeKey]).fileSize }
}
