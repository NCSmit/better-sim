import Foundation
import Network

struct PreviewActions: Sendable {
    var frame: @Sendable () async throws -> Data
    /// Points are fractions of the screen's width and height, measured from its top-left corner.
    var tap: @Sendable (CGPoint) async throws -> Void
    var swipe: @Sendable (CGPoint, CGPoint, Double) async throws -> Void
}

/// A page on 127.0.0.1 that shows the device screen a few times a second and sends clicks back as taps. Every URL
/// carries a random token, so other pages in the browser and other local processes can't use it.
final class BrowserPreview: @unchecked Sendable {
    let token: String
    private let listener: NWListener
    private let actions: PreviewActions
    private let queue = DispatchQueue(label: "local.bettersim.preview")
    private let lock = NSLock()
    private var boundPort: UInt16 = 0

    var port: UInt16 { lock.withLock { boundPort } }
    var url: URL { URL(string: "http://127.0.0.1:\(port)/\(token)/")! }

    static func start(port: Int?, token: String = PreviewToken.make(), actions: PreviewActions) async throws -> BrowserPreview {
        let preview = try BrowserPreview(port: port, token: token, actions: actions)
        try await preview.waitUntilReady(requestedPort: port)
        return preview
    }

    private init(port: Int?, token: String, actions: PreviewActions) throws {
        guard let requested = NWEndpoint.Port(rawValue: UInt16(clamping: port ?? 0)) else {
            throw AgentFailure(.usage, "\(port ?? 0) isn't a port BetterSim can use.")
        }
        let parameters = NWParameters.tcp
        parameters.requiredInterfaceType = .loopback
        parameters.acceptLocalOnly = true
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: requested)
        self.token = token
        self.actions = actions
        listener = try NWListener(using: parameters)
        listener.newConnectionHandler = { [weak self] connection in self?.serve(connection) }
    }

    func stop() {
        listener.cancel()
    }

    private func waitUntilReady(requestedPort: Int?) async throws {
        let started = PreviewStart()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            listener.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    lock.withLock { boundPort = listener.port?.rawValue ?? 0 }
                    started.finish(continuation, with: .success(()))
                case .failed(let error), .waiting(let error):
                    listener.cancel()
                    let message = requestedPort.map { "Port \($0) isn't free. Choose another with --port." }
                        ?? "The preview couldn't start: \(error.localizedDescription)"
                    started.finish(continuation, with: .failure(AgentFailure(.failed, message)))
                case .cancelled:
                    started.finish(continuation, with: .failure(AgentFailure(.failed, "The preview stopped before it started.")))
                default:
                    break
                }
            }
            listener.start(queue: queue)
        }
    }

    private func serve(_ connection: NWConnection) {
        connection.start(queue: queue)
        queue.asyncAfter(deadline: .now() + 20) { connection.cancel() }
        receive(on: connection, buffer: Data())
    }

    private func receive(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return connection.cancel() }
            var buffer = buffer
            if let data { buffer.append(data) }
            switch HTTPRequest.parse(buffer) {
            case .complete(let request):
                Task { await self.respond(to: request, on: connection) }
            case .incomplete where !isComplete && error == nil:
                receive(on: connection, buffer: buffer)
            case .incomplete, .invalid:
                send(.text(400, "Bad request."), on: connection)
            }
        }
    }

    private func respond(to request: HTTPRequest, on connection: NWConnection) async {
        let response: HTTPResponse
        switch PreviewRouter(token: token, port: port).route(request) {
        case .page:
            response = .html(PreviewPage.html(token: token))
        case .frame:
            do {
                response = .jpeg(try await actions.frame())
            } catch {
                response = .json(503, ["error": error.localizedDescription])
            }
        case .tap(let point):
            response = await perform { try await self.actions.tap(point) }
        case .swipe(let from, let to, let duration):
            response = await perform { try await self.actions.swipe(from, to, duration) }
        case .reject(let status, let message):
            response = .text(status, message)
        }
        send(response, on: connection)
    }

    private func perform(_ action: @Sendable () async throws -> Void) async -> HTTPResponse {
        do {
            try await action()
            return .json(200, ["ok": true])
        } catch {
            return .json(409, ["error": error.localizedDescription])
        }
    }

    private func send(_ response: HTTPResponse, on connection: NWConnection) {
        connection.send(content: response.data, completion: .contentProcessed { _ in connection.cancel() })
    }
}

/// Resumes the start-up continuation once, whichever state the listener reaches first.
private final class PreviewStart: @unchecked Sendable {
    private let lock = NSLock()
    private var finished = false

    func finish(_ continuation: CheckedContinuation<Void, Error>, with result: Result<Void, Error>) {
        let first = lock.withLock {
            defer { finished = true }
            return !finished
        }
        if first { continuation.resume(with: result) }
    }
}

enum PreviewToken {
    static func make() -> String {
        var generator = SystemRandomNumberGenerator()
        return (0..<16).map { _ in String(format: "%02x", Int(UInt8.random(in: .min ... .max, using: &generator))) }.joined()
    }

    /// Compares in constant time, so response timing doesn't give the token away.
    static func matches(_ candidate: Substring, _ token: String) -> Bool {
        let given = Array(candidate.utf8)
        let expected = Array(token.utf8)
        guard given.count == expected.count else { return false }
        return zip(given, expected).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }
}

/// Decides what a request to the preview is for. Kept apart from the network code so it can be tested on its own.
struct PreviewRouter {
    enum Route: Equatable {
        case page
        case frame
        case tap(CGPoint)
        case swipe(from: CGPoint, to: CGPoint, duration: Double)
        case reject(status: Int, message: String)
    }

    let token: String
    let port: UInt16

    func route(_ request: HTTPRequest) -> Route {
        guard isLocal(host: request.headers["host"]) else {
            return .reject(status: 403, message: "This preview only answers at 127.0.0.1:\(port).")
        }
        let path = request.path.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).first ?? ""
        let parts = path.split(separator: "/", omittingEmptySubsequences: false).dropFirst()
        guard let first = parts.first, PreviewToken.matches(first, token) else {
            return .reject(status: 404, message: "Not found.")
        }
        let resource = parts.dropFirst().joined(separator: "/")
        switch (request.method, resource) {
        case ("GET", ""):
            return .page
        case ("GET", "frame.jpg"):
            return .frame
        case ("POST", "tap"), ("POST", "swipe"):
            guard isLocal(origin: request.headers["origin"]) else {
                return .reject(status: 403, message: "Taps are only accepted from the preview page.")
            }
            return resource == "tap" ? tap(request.body) : swipe(request.body)
        case (_, ""), (_, "frame.jpg"), (_, "tap"), (_, "swipe"):
            return .reject(status: 405, message: "Method not allowed.")
        default:
            return .reject(status: 404, message: "Not found.")
        }
    }

    private func tap(_ body: Data) -> Route {
        struct Tap: Decodable { let x: Double; let y: Double }
        guard let tap = try? JSONDecoder().decode(Tap.self, from: body), Self.isFraction(tap.x, tap.y) else {
            return .reject(status: 400, message: "A tap needs x and y between 0 and 1.")
        }
        return .tap(CGPoint(x: tap.x, y: tap.y))
    }

    private func swipe(_ body: Data) -> Route {
        struct Swipe: Decodable { let x1: Double; let y1: Double; let x2: Double; let y2: Double; let duration: Double }
        guard let swipe = try? JSONDecoder().decode(Swipe.self, from: body), Self.isFraction(swipe.x1, swipe.y1, swipe.x2, swipe.y2),
              (0.05...5).contains(swipe.duration)
        else { return .reject(status: 400, message: "A swipe needs x1, y1, x2 and y2 between 0 and 1, and a duration of up to 5 seconds.") }
        return .swipe(from: CGPoint(x: swipe.x1, y: swipe.y1), to: CGPoint(x: swipe.x2, y: swipe.y2), duration: swipe.duration)
    }

    private static func isFraction(_ values: Double...) -> Bool {
        values.allSatisfy { (0...1).contains($0) }
    }

    /// Refusing other host names stops a web page from reaching the preview through a domain that points at 127.0.0.1.
    private func isLocal(host: String?) -> Bool {
        guard let host = host?.lowercased() else { return false }
        let names = ["127.0.0.1", "localhost"]
        return names.contains { host == "\($0):\(port)" || (port == 80 && host == $0) }
    }

    private func isLocal(origin: String?) -> Bool {
        guard let origin = origin?.lowercased() else { return true }
        return ["127.0.0.1", "localhost"].contains { origin == "http://\($0):\(port)" || (port == 80 && origin == "http://\($0)") }
    }
}

struct HTTPRequest: Equatable {
    enum Parsed: Equatable {
        case incomplete
        case invalid
        case complete(HTTPRequest)
    }

    static let headerLimit = 16 * 1024
    static let bodyLimit = 64 * 1024

    var method: String
    var path: String
    /// Names are lowercased.
    var headers: [String: String]
    var body: Data

    static func parse(_ data: Data) -> Parsed {
        guard let end = data.range(of: Data("\r\n\r\n".utf8)) else {
            return data.count > headerLimit ? .invalid : .incomplete
        }
        guard end.lowerBound - data.startIndex <= headerLimit else { return .invalid }
        var lines = String(decoding: data[data.startIndex..<end.lowerBound], as: UTF8.self).components(separatedBy: "\r\n")
        let requestLine = lines.removeFirst().split(separator: " ")
        guard requestLine.count == 3, requestLine[2].hasPrefix("HTTP/1.") else { return .invalid }
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { return .invalid }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            headers[name] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        guard let length = Int(headers["content-length"] ?? "0"), (0...bodyLimit).contains(length) else { return .invalid }
        let body = data[end.upperBound...]
        guard body.count >= length else { return .incomplete }
        return .complete(HTTPRequest(method: String(requestLine[0]), path: String(requestLine[1]), headers: headers, body: Data(body.prefix(length))))
    }
}

struct HTTPResponse: Equatable {
    var status: Int
    var contentType: String
    var body: Data

    static func html(_ text: String) -> HTTPResponse {
        HTTPResponse(status: 200, contentType: "text/html; charset=utf-8", body: Data(text.utf8))
    }

    static func jpeg(_ data: Data) -> HTTPResponse {
        HTTPResponse(status: 200, contentType: "image/jpeg", body: data)
    }

    static func text(_ status: Int, _ text: String) -> HTTPResponse {
        HTTPResponse(status: status, contentType: "text/plain; charset=utf-8", body: Data(text.utf8))
    }

    static func json<Body: Encodable>(_ status: Int, _ body: Body) -> HTTPResponse {
        HTTPResponse(status: status, contentType: "application/json", body: (try? AgentCoding.encode(body)) ?? Data())
    }

    var data: Data {
        let reasons = [200: "OK", 400: "Bad Request", 403: "Forbidden", 404: "Not Found", 405: "Method Not Allowed", 409: "Conflict", 503: "Service Unavailable"]
        let head = [
            "HTTP/1.1 \(status) \(reasons[status] ?? "Error")",
            "Content-Type: \(contentType)",
            "Content-Length: \(body.count)",
            "Cache-Control: no-store",
            "Referrer-Policy: no-referrer",
            "X-Content-Type-Options: nosniff",
            "X-Frame-Options: DENY",
            "Connection: close",
        ].joined(separator: "\r\n")
        return Data((head + "\r\n\r\n").utf8) + body
    }
}

/// Shares screenshots between browser tabs, and takes at most one at a time.
actor PreviewFrames {
    private let udid: String?
    private var latest: (data: Data, taken: Date)?
    private var pending: Task<Data, Error>?

    init(udid: String?) {
        self.udid = udid
    }

    func frame() async throws -> Data {
        if let latest, Date().timeIntervalSince(latest.taken) < 0.2 { return latest.data }
        if let pending { return try await pending.value }
        let task = Task { [udid] in try await Self.capture(udid: udid) }
        pending = task
        defer { pending = nil }
        let data = try await task.value
        latest = (data, Date())
        return data
    }

    /// `simctl io screenshot` won't write to standard output, so each frame goes through a temporary file.
    static func capture(udid: String?) async throws -> Data {
        if let udid { return try await screenshot(udid) }
        if let current = SimulatorWindows.currentDeviceUDID, let data = try? await screenshot(current) { return data }
        return try await screenshot(try await DeviceResolver.resolve(nil).udid)
    }

    private static func screenshot(_ udid: String) async throws -> Data {
        let file = FileManager.default.temporaryDirectory.appending(path: "bettersim-preview-\(UUID().uuidString).jpg")
        defer { try? FileManager.default.removeItem(at: file) }
        try await Simctl.run(["io", udid, "screenshot", "--type=jpeg", file.path(percentEncoded: false)])
        return try Data(contentsOf: file)
    }
}

enum PreviewPage {
    static func html(token: String) -> String {
        """
        <!doctype html>
        <html lang="en">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <base href="/\(token)/">
        <title>BetterSim Preview</title>
        <style>
          :root { color-scheme: light dark; --background: #f2f2f7; --text: #1c1c1e; --muted: #6e6e73; --error: #c4372c; }
          @media (prefers-color-scheme: dark) { :root { --background: #111113; --text: #f2f2f7; --muted: #98989d; --error: #ff6961; } }
          html, body { margin: 0; height: 100%; background: var(--background); color: var(--text); font: 13px -apple-system, system-ui, sans-serif; }
          main { box-sizing: border-box; height: 100%; padding: 16px; display: flex; flex-direction: column; align-items: center; justify-content: center; gap: 12px; }
          img { max-width: 100%; max-height: calc(100vh - 72px); border-radius: 28px; box-shadow: 0 10px 40px rgb(0 0 0 / 0.3); cursor: pointer; touch-action: none; user-select: none; -webkit-user-drag: none; }
          img:not([src]) { visibility: hidden; }
          p { margin: 0; color: var(--muted); min-height: 1.3em; text-align: center; }
          p.error { color: var(--error); }
        </style>
        </head>
        <body>
        <main>
          <img id="screen" alt="The simulator's screen" draggable="false">
          <p id="status">Connecting to BetterSim…</p>
        </main>
        <script>
          const screen = document.getElementById('screen');
          const status = document.getElementById('status');
          const hint = 'Click to tap. Drag to swipe.';
          let shown = null;
          let start = null;
          let holdUntil = 0;

          function say(text, isError) {
            if (performance.now() < holdUntil) return;
            status.textContent = text;
            status.className = isError ? 'error' : '';
          }

          function sayForAWhile(text) {
            holdUntil = 0;
            say(text, true);
            holdUntil = performance.now() + 5000;
          }

          async function refresh() {
            const began = performance.now();
            try {
              const response = await fetch('frame.jpg', { cache: 'no-store' });
              if (!response.ok) throw new Error((await response.json()).error || 'BetterSim could not take a screenshot.');
              const url = URL.createObjectURL(await response.blob());
              screen.src = url;
              if (shown) URL.revokeObjectURL(shown);
              shown = url;
              if (status.textContent !== hint) say(hint, false);
            } catch (error) {
              say(error instanceof TypeError ? 'BetterSim stopped answering.' : error.message, true);
            }
            setTimeout(refresh, Math.max(0, 333 - (performance.now() - began)));
          }

          function fraction(event) {
            const rect = screen.getBoundingClientRect();
            return {
              x: Math.min(1, Math.max(0, (event.clientX - rect.left) / rect.width)),
              y: Math.min(1, Math.max(0, (event.clientY - rect.top) / rect.height)),
              time: performance.now()
            };
          }

          async function send(path, body) {
            try {
              const response = await fetch(path, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(body) });
              if (!response.ok) sayForAWhile((await response.json()).error || "That didn't work.");
            } catch {
              sayForAWhile('BetterSim stopped answering.');
            }
          }

          screen.addEventListener('pointerdown', event => {
            start = fraction(event);
            screen.setPointerCapture(event.pointerId);
          });
          screen.addEventListener('pointerup', event => {
            if (!start) return;
            const end = fraction(event);
            const from = start;
            start = null;
            if (Math.hypot(end.x - from.x, end.y - from.y) < 0.01) {
              send('tap', { x: end.x, y: end.y });
            } else {
              const duration = Math.min(5, Math.max(0.1, (end.time - from.time) / 1000));
              send('swipe', { x1: from.x, y1: from.y, x2: end.x, y2: end.y, duration });
            }
          });
          screen.addEventListener('pointercancel', () => { start = null; });
          refresh();
        </script>
        </body>
        </html>
        """
    }
}
