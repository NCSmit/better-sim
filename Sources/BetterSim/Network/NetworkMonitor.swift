import Foundation
import Network
import os

private let log = Logger(subsystem: "local.bettersim", category: "network")

/// One finished request, as BetterSimNetworkMonitor.dylib reports it from inside a simulator app.
struct NetworkEvent: Identifiable, Sendable, Equatable, Decodable {
    let id: UUID
    let bundleID: String?
    let method: String
    let url: String
    let requestHeaders: [String: String]
    /// At most the first 64 KB. `requestBodySize` is the full size.
    let requestBody: Data?
    let requestBodySize: Int
    /// Missing when the request failed before a response arrived.
    let status: Int?
    let responseHeaders: [String: String]
    /// At most the first 256 KB. `responseBodySize` is the full size.
    let responseBody: Data?
    let responseBodySize: Int
    let startedAt: Date
    let duration: TimeInterval
    let error: String?

    static func decode(_ json: Data) throws -> NetworkEvent {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return try decoder.decode(NetworkEvent.self, from: json)
    }

    var host: String { URLComponents(string: url)?.host ?? "" }

    /// The path with its query, which is what tells requests to the same host apart.
    var path: String {
        guard let components = URLComponents(string: url) else { return url }
        let path = components.percentEncodedPath.isEmpty ? "/" : components.percentEncodedPath
        return components.percentEncodedQuery.map { "\(path)?\($0)" } ?? path
    }

    var statusClass: StatusClass {
        guard let status else { return .failed }
        switch status {
        case 200..<300: return .success
        case 300..<400: return .redirect
        case 400..<500: return .clientError
        case 500..<600: return .serverError
        default: return .informational
        }
    }

    enum StatusClass: Sendable {
        case informational, success, redirect, clientError, serverError, failed
    }

    func matches(_ filter: String) -> Bool {
        let filter = filter.trimmingCharacters(in: .whitespaces)
        guard !filter.isEmpty else { return true }
        return [method, url, status.map(String.init) ?? "", bundleID ?? "", error ?? ""]
            .contains { $0.localizedCaseInsensitiveContains(filter) }
    }

    /// One option per line, the way browsers copy requests.
    var curlCommand: String {
        var options = ["curl \(Self.shellQuoted(url))"]
        if method == "HEAD" {
            options.append("--head")
        } else if method != "GET" {
            options.append("-X \(method)")
        }
        // curl works out Content-Length itself, and a stale one makes the server wait for bytes that never come.
        for (name, value) in requestHeaders.sorted(by: { $0.key < $1.key }) where name.lowercased() != "content-length" {
            options.append("-H \(Self.shellQuoted("\(name): \(value)"))")
        }
        guard let body = requestBody, !body.isEmpty else { return options.joined(separator: " \\\n  ") }
        if let text = String(data: body, encoding: .utf8), !text.contains("\0") {
            options.append("--data-raw \(Self.shellQuoted(text))")
            return options.joined(separator: " \\\n  ")
        }
        options.append("--data-binary @-")
        return "echo \(body.base64EncodedString()) | base64 --decode | " + options.joined(separator: " \\\n  ")
    }

    static func shellQuoted(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
    }
}

/// Reads HTTP/1.1 requests with Content-Length bodies from a byte stream that can arrive in any number of pieces.
struct HTTPRequestParser: Sendable {
    struct Request: Equatable, Sendable {
        let method: String
        let path: String
        /// Keyed by lowercased name.
        let headers: [String: String]
        let body: Data
    }

    enum Failure: Error, Equatable {
        case malformed
        case tooLarge
    }

    static let headLimit = 64 * 1024
    static let bodyLimit = 16 * 1024 * 1024
    private static let headEnd = Data("\r\n\r\n".utf8)

    private var buffer = Data()

    mutating func append(_ data: Data) {
        buffer.append(data)
    }

    /// The next complete request, or nil until more bytes arrive.
    mutating func next() throws -> Request? {
        guard let headEnd = buffer.range(of: Self.headEnd) else {
            if buffer.count > Self.headLimit { throw Failure.tooLarge }
            return nil
        }
        var lines = String(decoding: buffer[buffer.startIndex..<headEnd.lowerBound], as: UTF8.self).components(separatedBy: "\r\n")
        let requestLine = lines.removeFirst().split(separator: " ")
        guard requestLine.count == 3, requestLine[2].hasPrefix("HTTP/1.") else { throw Failure.malformed }
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { throw Failure.malformed }
            headers[line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()] = line[line.index(after: colon)...]
                .trimmingCharacters(in: .whitespaces)
        }
        guard headers["transfer-encoding"] == nil, let length = Int(headers["content-length"] ?? "0"), length >= 0 else {
            throw Failure.malformed
        }
        guard length <= Self.bodyLimit else { throw Failure.tooLarge }
        guard buffer.distance(from: headEnd.upperBound, to: buffer.endIndex) >= length else { return nil }
        let bodyEnd = buffer.index(headEnd.upperBound, offsetBy: length)
        let body = Data(buffer[headEnd.upperBound..<bodyEnd])
        buffer = Data(buffer[bodyEnd...])
        return Request(method: String(requestLine[0]), path: String(requestLine[1]), headers: headers, body: body)
    }
}

enum NetworkMonitorError: LocalizedError {
    case missingLibrary

    var errorDescription: String? {
        "BetterSim can't find \(NetworkMonitor.libraryName).dylib. Build the app with build.sh."
    }
}

/// Listens on 127.0.0.1 for the requests BetterSimNetworkMonitor.dylib reports from simulator apps.
@MainActor
final class NetworkMonitor: ObservableObject {
    static let capacity = 500
    nonisolated static let libraryName = "BetterSimNetworkMonitor"

    /// Newest first.
    @Published private(set) var events: [NetworkEvent] = []
    @Published private(set) var port: UInt16?
    private var listener: NWListener?
    private var waiters: [CheckedContinuation<UInt16, any Error>] = []
    private let connectionQueue = DispatchQueue(label: "local.bettersim.network")

    /// The environment for `simctl launch` or `spawn` that loads the monitor into the app.
    static func launchEnvironment(port: UInt16, dylib: URL) -> [String: String] {
        [
            "SIMCTL_CHILD_DYLD_INSERT_LIBRARIES": dylib.path(percentEncoded: false),
            "SIMCTL_CHILD_BETTERSIM_MONITOR_PORT": String(port),
        ]
    }

    static var bundledLibrary: URL? {
        if let url = Bundle.main.url(forResource: libraryName, withExtension: "dylib") { return url }
        // `swift run` has no app bundle, so look for the copy build.sh leaves in build/ next to the package.
        var folder = Bundle.main.bundleURL
        for _ in 0..<5 {
            let candidate = folder.appending(path: "build/\(libraryName).dylib")
            if FileManager.default.fileExists(atPath: candidate.path(percentEncoded: false)) { return candidate }
            folder.deleteLastPathComponent()
        }
        return nil
    }

    /// Starts listening if it isn't already, and returns the port once it's ready.
    @discardableResult
    func start() async throws -> UInt16 {
        if let port { return port }
        if listener == nil {
            let parameters = NWParameters.tcp
            parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
            parameters.acceptLocalOnly = true
            let listener = try NWListener(using: parameters)
            let deliver: @Sendable (NetworkEvent) -> Void = { [weak self] event in
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.record(event) } }
            }
            let queue = connectionQueue
            listener.newConnectionHandler = { connection in
                EventConnection.serve(connection, on: queue, deliver: deliver)
            }
            listener.stateUpdateHandler = { [weak self] state in
                MainActor.assumeIsolated { self?.listenerChanged(state) }
            }
            self.listener = listener
            listener.start(queue: .main)
        }
        return try await withCheckedThrowingContinuation { waiters.append($0) }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        port = nil
        resumeWaiters(with: .failure(CancellationError()))
    }

    /// Relaunches the app with the monitor loaded, so its requests show up in `events`.
    func relaunch(_ bundleID: String, on udid: String) async throws {
        guard let library = Self.bundledLibrary else { throw NetworkMonitorError.missingLibrary }
        let port = try await start()
        try await Simctl.run(
            ["launch", "--terminate-running-process", udid, bundleID],
            environment: Self.launchEnvironment(port: port, dylib: library)
        )
    }

    func record(_ event: NetworkEvent) {
        events.insert(event, at: 0)
        if events.count > Self.capacity { events.removeLast(events.count - Self.capacity) }
    }

    func clear() {
        events = []
    }

    private func listenerChanged(_ state: NWListener.State) {
        switch state {
        case .ready:
            guard let port = listener?.port?.rawValue else { return }
            self.port = port
            resumeWaiters(with: .success(port))
        case .failed(let error):
            log.error("network monitor stopped: \(error.localizedDescription)")
            listener?.cancel()
            listener = nil
            port = nil
            resumeWaiters(with: .failure(error))
        default:
            break
        }
    }

    private func resumeWaiters(with result: Result<UInt16, any Error>) {
        let waiting = waiters
        waiters = []
        for waiter in waiting { waiter.resume(with: result) }
    }
}

/// Answers each request on one connection from the dylib, which keeps it open between events.
private enum EventConnection {
    static func serve(_ connection: NWConnection, on queue: DispatchQueue, deliver: @escaping @Sendable (NetworkEvent) -> Void) {
        connection.start(queue: queue)
        receive(on: connection, parser: HTTPRequestParser(), deliver: deliver)
    }

    private static func receive(on connection: NWConnection, parser: HTTPRequestParser, deliver: @escaping @Sendable (NetworkEvent) -> Void) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { data, _, isComplete, error in
            var parser = parser
            do {
                if let data { parser.append(data) }
                while let request = try parser.next() {
                    connection.send(content: Data(reply(to: request, deliver: deliver).utf8), completion: .idempotent)
                }
            } catch {
                log.error("dropped a malformed report: \(String(describing: error))")
                connection.cancel()
                return
            }
            if isComplete || error != nil {
                connection.cancel()
            } else {
                receive(on: connection, parser: parser, deliver: deliver)
            }
        }
    }

    private static func reply(to request: HTTPRequestParser.Request, deliver: @Sendable (NetworkEvent) -> Void) -> String {
        guard request.method == "POST", request.path == "/events" else {
            return "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\n\r\n"
        }
        do {
            deliver(try NetworkEvent.decode(request.body))
            return "HTTP/1.1 204 No Content\r\n\r\n"
        } catch {
            log.error("could not read a network event: \(error.localizedDescription)")
            return "HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\n\r\n"
        }
    }
}
