import Foundation

/// What the command-line tool asks the running app to do: the work that needs the Simulator window or BetterSim's
/// Accessibility access, which belongs to the app rather than to whatever terminal runs the tool.
enum AgentAction: Codable, Equatable, Sendable {
    case ping
    case listElements(includeAll: Bool)
    case tap(x: Double, y: Double)
    case tapLabel(label: String)
    case swipe(fromX: Double, fromY: Double, toX: Double, toY: Double, duration: Double)
    case type(text: String)
    case waitForLabel(label: String, timeout: Double)
    case preview(port: Int?)
    /// Gives an app the simulator camera or takes it away, after picking what it shows. With `on` nil, only reports.
    case camera(on: Bool?, bundleID: String?, source: String?)
}

/// Sent as JSON, one request per connection. Without a UDID the app uses the device the Simulator shows as current.
struct AgentRequest: Codable, Equatable, Sendable {
    var action: AgentAction
    var udid: String?
}

/// The one reply to a request. `failure` is set when the action didn't happen.
struct AgentReply: Codable, Equatable, Sendable {
    var message: String?
    var elements: [DeviceElement]?
    var element: DeviceElement?
    var url: String?
    var status: AgentStatus?
    var failure: AgentFailure?
}

struct AgentStatus: Codable, Equatable, Sendable {
    var version: String
    var accessibilityAllowed: Bool
    var simulatorWindows: Int
    var currentDevice: String?
    var previewURL: String?
}

struct AgentFailure: LocalizedError, Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable {
        case usage, appNotRunning, accessibility, noDevice, noWindow, notFound, timeout, failed
    }

    let kind: Kind
    let message: String

    init(_ kind: Kind, _ message: String) {
        self.kind = kind
        self.message = message
    }

    var errorDescription: String? { message }

    /// The exit codes `bettersim help` lists.
    var exitCode: Int32 {
        switch kind {
        case .failed: 1
        case .usage: 2
        case .appNotRunning: 3
        case .accessibility: 4
        case .noDevice, .noWindow: 5
        case .notFound, .timeout: 6
        }
    }

    static let accessibilityNeeded = AgentFailure(
        .accessibility,
        "BetterSim needs Accessibility access to read and control the Simulator. Allow it in System Settings > Privacy & Security > Accessibility, then try again."
    )

    static let appNotRunning = AgentFailure(.appNotRunning, "BetterSim isn't running. Open BetterSim, then try again.")
}

enum AgentSocket {
    static let fileName = "bettersim-agent.sock"
    /// Lets a test build of the app and its tool use their own socket, next to an installed BetterSim.
    static let overrideVariable = "BETTERSIM_AGENT_SOCKET"

    static var path: String {
        if let path = ProcessInfo.processInfo.environment[overrideVariable], !path.isEmpty { return path }
        return userTemporaryDirectory.appending(path: fileName).path(percentEncoded: false)
    }

    /// The per-user temporary folder. Unlike TMPDIR, which agents and terminals often change, it's the same for the
    /// app and every copy of the tool.
    static var userTemporaryDirectory: URL {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        let length = confstr(_CS_DARWIN_USER_TEMP_DIR, &buffer, buffer.count)
        guard length > 0, length <= buffer.count else { return FileManager.default.temporaryDirectory }
        return URL(filePath: String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self), directoryHint: .isDirectory)
    }
}

enum AgentCoding {
    static func encode<Value: Encodable>(_ value: Value) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }

    static func decode<Value: Decodable>(_ type: Value.Type, from data: Data) throws -> Value {
        try JSONDecoder().decode(type, from: data)
    }

    static func string<Value: Encodable>(_ value: Value) -> String {
        (try? encode(value)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
    }
}
