import Foundation
import os

private let log = Logger(subsystem: "local.bettersim", category: "devices")

struct DeviceCtlError: LocalizedError, Equatable {
    let command: String
    let message: String

    var errorDescription: String? {
        message.isEmpty ? "devicectl \(command) failed." : message
    }
}

/// Runs `xcrun devicectl`. Apple only promises to keep its JSON output stable, so every call writes a JSON file and reads that.
enum DeviceCtl {
    // Like simctl, look devicectl up once instead of letting xcrun resolve the active Xcode on every call.
    static let executable: URL = {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(filePath: "/usr/bin/xcrun")
        process.arguments = ["--find", "devicectl"]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return URL(filePath: "/usr/bin/xcrun") }
        let path = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        process.waitUntilExit()
        return process.terminationStatus == 0 && !path.isEmpty ? URL(filePath: path) : URL(filePath: "/usr/bin/xcrun")
    }()

    static func arguments(
        _ command: [String],
        jsonOutput: URL,
        timeout: Int,
        viaXcrun: Bool = DeviceCtl.executable.lastPathComponent == "xcrun"
    ) -> [String] {
        // Before the subcommand, where `device process launch` can't mistake them for arguments to the app.
        (viaXcrun ? ["devicectl"] : []) + ["--json-output", jsonOutput.path, "--timeout", String(timeout)] + command
    }

    /// "device process launch", without the options that follow, for messages.
    static func name(of command: [String]) -> String {
        command.prefix { !$0.hasPrefix("-") }.joined(separator: " ")
    }

    /// Runs `command` and decodes the `result` it wrote, or throws the `error` it wrote instead.
    static func run<Value: Decodable>(_ command: [String], timeout: Int = 30, as type: Value.Type) async throws -> Value {
        try decode(type, from: try await run(command, timeout: timeout), command: name(of: command))
    }

    /// Returns the JSON devicectl wrote. Failed commands write one too, with the reason in it.
    static func run(_ command: [String], timeout: Int = 30) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(with: Result { try runBlocking(command, timeout: timeout) })
            }
        }
    }

    static func decode<Value: Decodable>(_ type: Value.Type, from json: Data, command: String) throws -> Value {
        let decoder = JSONDecoder()
        if let failure = (try? decoder.decode(FailureEnvelope.self, from: json))?.error {
            throw DeviceCtlError(command: command, message: failure.message)
        }
        let envelope: ResultEnvelope<Value>
        do {
            envelope = try decoder.decode(ResultEnvelope<Value>.self, from: json)
        } catch {
            log.error("could not read devicectl \(command, privacy: .public): \(error.localizedDescription, privacy: .public)")
            throw DeviceCtlError(command: command, message: "BetterSim couldn't read what devicectl \(command) returned.")
        }
        guard let result = envelope.result else { throw DeviceCtlError(command: command, message: "") }
        return result
    }

    /// The first line devicectl printed to standard error, for when it fails before writing its JSON file.
    static func firstError(in text: String) -> String {
        let line = text.split(separator: "\n").first { !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? ""
        return line.replacingOccurrences(of: "ERROR:", with: "").trimmingCharacters(in: .whitespaces)
    }

    private static func runBlocking(_ command: [String], timeout: Int) throws -> Data {
        let file = FileManager.default.temporaryDirectory.appending(path: "BetterSim-devicectl-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments(command, jsonOutput: file, timeout: timeout)
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        let errors = Pipe()
        process.standardError = errors
        try process.run()
        let errorText = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        if let json = try? Data(contentsOf: file), !json.isEmpty { return json }
        throw DeviceCtlError(command: name(of: command), message: firstError(in: errorText))
    }
}

private struct FailureEnvelope: Decodable {
    let error: DeviceCtlFailure?
}

private struct ResultEnvelope<Value: Decodable>: Decodable {
    let result: Value?
}

/// The `error` in devicectl's JSON: an NSError whose user info values are wrapped by type, with the cause one level down.
final class DeviceCtlFailure: Decodable, Sendable {
    struct Value: Decodable, Sendable {
        let string: String?
        let error: DeviceCtlFailure?
    }

    let userInfo: [String: Value]?

    private var summary: String? { userInfo?["NSLocalizedDescription"]?.string }
    private var underlying: DeviceCtlFailure? { userInfo?["NSUnderlyingError"]?.error }

    /// The top description, plus the root cause when that adds something, such as "The device is locked."
    var message: String {
        let summaries = sequence(first: self, next: \.underlying).compactMap(\.summary)
        guard let first = summaries.first else { return "" }
        guard let cause = summaries.last.map(Self.plainCause), !first.contains(cause) else { return first }
        return "\(first) \(cause)"
    }

    /// MobileDevice puts the readable part last, in brackets: "Error mounting image: 0xe80000e2 (kAMD…Locked: The device is locked.)".
    static func plainCause(_ text: String) -> String {
        guard text.hasSuffix(")"), let open = text.lastIndex(of: "(") else { return text }
        let inside = text[text.index(after: open)..<text.index(before: text.endIndex)]
        guard let colon = inside.range(of: ": ") else { return text }
        return String(inside[colon.upperBound...])
    }
}

/// The devicectl arguments for each action. `DeviceCtl` adds the output options.
enum DeviceCommand {
    static let listDevices = ["list", "devices"]

    static func apps(on device: String, bundleID: String? = nil) -> [String] {
        ["device", "info", "apps", "--device", device] + (bundleID.map { ["--bundle-id", $0] } ?? [])
    }

    static func processes(on device: String) -> [String] {
        ["device", "info", "processes", "--device", device]
    }

    /// Takes an .app or an .ipa.
    static func install(_ app: URL, on device: String) -> [String] {
        ["device", "install", "app", "--device", device, app.path]
    }

    /// Options go before the bundle ID, because everything after it is passed to the app as arguments.
    static func launch(_ bundleID: String, on device: String, payloadURL: String? = nil, terminatingExisting: Bool = false) -> [String] {
        var arguments = ["device", "process", "launch", "--device", device]
        if terminatingExisting { arguments.append("--terminate-existing") }
        if let payloadURL { arguments += ["--payload-url", payloadURL] }
        return arguments + [bundleID]
    }

    static func terminate(pid: Int, on device: String) -> [String] {
        ["device", "process", "terminate", "--device", device, "--pid", String(pid)]
    }
}

/// An iPhone or iPad that CoreDevice knows about.
struct PhysicalDevice: Identifiable, Hashable, Sendable {
    enum Connection: String, Sendable {
        case usb = "USB"
        case wifi = "Wi-Fi"
        case notPaired = "Not Paired"
        case offline = "Offline"

        var isReachable: Bool { self == .usb || self == .wifi }

        fileprivate var sortOrder: Int {
            switch self {
            case .usb: 0
            case .wifi: 1
            case .notPaired: 2
            case .offline: 3
            }
        }
    }

    /// CoreDevice's identifier, which devicectl's --device takes.
    let identifier: String
    let name: String
    /// The marketing name, such as "iPhone 16 Pro".
    let model: String
    /// Such as "iPhone17,1".
    let modelIdentifier: String
    let deviceType: String
    let osVersion: String
    /// The hardware UDID, used to find the device's screen among the Mac's capture devices.
    let udid: String?
    let connection: Connection

    var id: String { identifier }
    var osName: String { deviceType == "iPad" ? "iPadOS" : "iOS" }
    var symbol: String { deviceType == "iPad" ? "ipad" : "iphone" }
    var subtitle: String { osVersion.isEmpty ? model : "\(model) · \(osName) \(osVersion)" }

    static func connection(pairingState: String?, transportType: String?, tunnelState: String?) -> Connection {
        if let pairingState, pairingState != "paired" { return .notPaired }
        guard let transportType, tunnelState != "unavailable" else { return .offline }
        return transportType == "wired" ? .usb : .wifi
    }

    /// Reads `devicectl list devices` output, keeping real iPhones, iPads and iPod touches.
    static func parseList(_ json: Data) throws -> [PhysicalDevice] {
        try DeviceCtl.decode(DeviceListJSON.self, from: json, command: "list devices").devices
            .filter { $0.hardwareProperties?.platform == "iOS" && ($0.hardwareProperties?.reality ?? "physical") == "physical" }
            .map { entry in
                let hardware = entry.hardwareProperties
                let link = entry.connectionProperties
                return PhysicalDevice(
                    identifier: entry.identifier,
                    name: entry.deviceProperties?.name ?? hardware?.marketingName ?? entry.identifier,
                    model: hardware?.marketingName ?? hardware?.productType ?? "Unknown model",
                    modelIdentifier: hardware?.productType ?? "",
                    deviceType: hardware?.deviceType ?? "iPhone",
                    osVersion: entry.deviceProperties?.osVersionNumber ?? "",
                    udid: hardware?.udid,
                    connection: connection(pairingState: link?.pairingState, transportType: link?.transportType, tunnelState: link?.tunnelState)
                )
            }
            .sorted { ($0.connection.sortOrder, $0.name) < ($1.connection.sortOrder, $1.name) }
    }
}

private struct DeviceListJSON: Decodable {
    struct Device: Decodable {
        struct Hardware: Decodable {
            let deviceType: String?
            let marketingName: String?
            let platform: String?
            let productType: String?
            let reality: String?
            let udid: String?
        }

        struct Properties: Decodable {
            let name: String?
            let osVersionNumber: String?
        }

        struct Link: Decodable {
            let pairingState: String?
            let transportType: String?
            let tunnelState: String?
        }

        let identifier: String
        let hardwareProperties: Hardware?
        let deviceProperties: Properties?
        let connectionProperties: Link?
    }

    let devices: [Device]
}

struct DeviceApp: Identifiable, Hashable, Sendable {
    let bundleID: String
    let name: String
    let version: String?
    let build: String?
    /// Where the bundle is on the device, which is how its process is found to terminate it.
    let url: URL?
    let isDeveloperBuild: Bool

    var id: String { bundleID }

    var versionText: String {
        switch (version, build) {
        case let (version?, build?) where version != build: "Version \(version) (\(build))"
        case let (version?, _): "Version \(version)"
        case let (nil, build?): "Build \(build)"
        default: bundleID
        }
    }

    /// Reads `devicectl device info apps` output, with the apps you built yourself first.
    static func parseList(_ json: Data) throws -> [DeviceApp] {
        try DeviceCtl.decode(AppListJSON.self, from: json, command: "device info apps").apps
            .filter { $0.hidden != true && $0.appClip != true }
            .compactMap { app in
                guard let bundleID = app.bundleIdentifier else { return nil }
                return DeviceApp(
                    bundleID: bundleID,
                    name: app.name ?? bundleID,
                    version: app.version,
                    build: app.bundleVersion,
                    url: app.url.flatMap(URL.init(string:)),
                    isDeveloperBuild: app.builtByDeveloper ?? false
                )
            }
            .sorted { ($0.isDeveloperBuild ? 0 : 1, $0.name.lowercased()) < ($1.isDeveloperBuild ? 0 : 1, $1.name.lowercased()) }
    }
}

private struct AppListJSON: Decodable {
    struct App: Decodable {
        let bundleIdentifier: String?
        let name: String?
        let version: String?
        let bundleVersion: String?
        let url: String?
        let builtByDeveloper: Bool?
        let hidden: Bool?
        let appClip: Bool?
    }

    let apps: [App]
}

struct DeviceProcess: Hashable, Sendable {
    let pid: Int
    let executable: URL?

    static func parseList(_ json: Data) throws -> [DeviceProcess] {
        try DeviceCtl.decode(ProcessListJSON.self, from: json, command: "device info processes").runningProcesses.map {
            DeviceProcess(pid: $0.processIdentifier, executable: $0.executable.flatMap(URL.init(string:)))
        }
    }

    /// devicectl lists processes by executable path, and an app's own executable sits at the top of its bundle.
    /// Its extensions live deeper inside, so they're left alone.
    static func pids(of app: URL, in processes: [DeviceProcess]) -> [Int] {
        let bundle = devicePath(app)
        return processes.filter { process in
            guard let executable = process.executable else { return false }
            return devicePath(executable.deletingLastPathComponent()) == bundle
        }
        .map(\.pid)
    }

    /// Paths on the device come with and without /private in front, and folders end in a slash.
    static func devicePath(_ url: URL) -> String {
        var path = url.path(percentEncoded: false)
        if path.hasPrefix("/private/") { path.removeFirst("/private".count) }
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        return path
    }
}

private struct ProcessListJSON: Decodable {
    struct Process: Decodable {
        let processIdentifier: Int
        let executable: String?
    }

    let runningProcesses: [Process]
}

private struct InstallJSON: Decodable {
    struct App: Decodable {
        let bundleID: String?
    }

    let installedApplications: [App]?

    var bundleIDs: [String] { installedApplications?.compactMap(\.bundleID) ?? [] }
}

private struct LaunchJSON: Decodable {
    struct Process: Decodable {
        let processIdentifier: Int?
    }

    let process: Process?
}

/// Results whose contents don't matter, only whether devicectl reported an error instead.
private struct AnyResult: Decodable {}

enum PhysicalDevices {
    static let safari = "com.apple.mobilesafari"

    static func list() async throws -> [PhysicalDevice] {
        try PhysicalDevice.parseList(try await DeviceCtl.run(DeviceCommand.listDevices, timeout: 15))
    }

    static func apps(on device: String) async throws -> [DeviceApp] {
        try DeviceApp.parseList(try await DeviceCtl.run(DeviceCommand.apps(on: device), timeout: 60))
    }

    /// Returns the bundle ID of the installed app.
    @discardableResult
    static func install(_ app: URL, on device: String) async throws -> String? {
        try await DeviceCtl.run(DeviceCommand.install(app, on: device), timeout: 900, as: InstallJSON.self).bundleIDs.first
    }

    /// With a `payloadURL` the app opens that link as it launches, the way a deep link would open it.
    static func launch(_ bundleID: String, on device: String, payloadURL: String? = nil, terminatingExisting: Bool = false) async throws {
        let command = DeviceCommand.launch(bundleID, on: device, payloadURL: payloadURL, terminatingExisting: terminatingExisting)
        _ = try await DeviceCtl.run(command, timeout: 60, as: LaunchJSON.self)
    }

    /// devicectl only terminates processes by ID, so this finds the app's process first. Returns how many it stopped.
    @discardableResult
    static func terminate(_ bundleID: String, on device: String) async throws -> Int {
        let apps = try DeviceApp.parseList(try await DeviceCtl.run(DeviceCommand.apps(on: device, bundleID: bundleID), timeout: 60))
        guard let bundle = apps.first(where: { $0.bundleID == bundleID })?.url else {
            throw DeviceCtlError(command: "device process terminate", message: "\(bundleID) isn't installed on this device.")
        }
        let processes = try DeviceProcess.parseList(try await DeviceCtl.run(DeviceCommand.processes(on: device)))
        let pids = DeviceProcess.pids(of: bundle, in: processes)
        for pid in pids {
            _ = try await DeviceCtl.run(DeviceCommand.terminate(pid: pid, on: device), as: AnyResult.self)
        }
        return pids.count
    }
}

/// A Simulator device type. Each names the model identifier of the real device it imitates.
struct SimulatorDeviceType: Decodable, Hashable, Sendable {
    let identifier: String
    let name: String
    let modelIdentifier: String?
    let bundlePath: String

    static func parseList(_ data: Data) throws -> [SimulatorDeviceType] {
        struct List: Decodable {
            let devicetypes: [SimulatorDeviceType]
        }
        return try JSONDecoder().decode(List.self, from: data).devicetypes
    }

    static func all() async throws -> [SimulatorDeviceType] {
        try parseList(try await Simctl.run(["list", "devicetypes", "--json"]))
    }

    /// The device type that looks like a real device. Memory variants share a model identifier, so the one with the
    /// device's own name wins, then the plainest name. Wi-Fi and cellular iPads have different identifiers but only
    /// one device type, so the marketing name is the fallback.
    static func matching(_ modelIdentifier: String, model: String, in types: [SimulatorDeviceType]) -> SimulatorDeviceType? {
        let isNamedLikeDevice = { (type: SimulatorDeviceType) in
            type.name.compare(model, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
        }
        let sameModel = types.filter { $0.modelIdentifier == modelIdentifier }
        return sameModel.first(where: isNamedLikeDevice)
            ?? sameModel.min { $0.name.count < $1.name.count }
            ?? types.first(where: isNamedLikeDevice)
    }
}

/// What a real device looks like, borrowed from the Simulator device type that matches it.
struct PhysicalDeviceChrome: Sendable {
    static let maskFolder = URL(filePath: "/Library/Developer/DeviceKit/FramebufferMasks")

    let profile: DeviceProfile
    /// The outline of the screen, which rounds the corners of a screenshot so it fits inside the bezel.
    let screenMask: URL?

    static func load(for device: PhysicalDevice, types: [SimulatorDeviceType]) -> PhysicalDeviceChrome? {
        guard let type = SimulatorDeviceType.matching(device.modelIdentifier, model: device.model, in: types) else { return nil }
        return load(deviceTypeBundle: URL(filePath: type.bundlePath))
    }

    static func load(deviceTypeBundle: URL) -> PhysicalDeviceChrome? {
        guard let profile = DeviceProfile.load(deviceTypeBundle: deviceTypeBundle) else { return nil }
        let plist = deviceTypeBundle.appending(path: "Contents/Resources/profile.plist")
        let info = (try? Data(contentsOf: plist))
            .flatMap { try? PropertyListSerialization.propertyList(from: $0, format: nil) as? [String: Any] }
        let mask = (info?["framebufferMask"] as? String)
            .map { maskFolder.appending(path: "\($0).pdf") }
            .flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
        return PhysicalDeviceChrome(profile: profile, screenMask: mask)
    }
}
