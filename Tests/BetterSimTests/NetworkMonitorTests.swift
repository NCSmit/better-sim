import Foundation
import Network
import Testing
@testable import BetterSim

struct HTTPRequestParserTests {
    @Test func readsTheRequestLineHeadersAndBody() throws {
        var parser = HTTPRequestParser()
        parser.append(Data("POST /events HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Type: application/json\r\nContent-Length: 2\r\n\r\n{}".utf8))
        let request = try #require(try parser.next())
        #expect(request.method == "POST")
        #expect(request.path == "/events")
        #expect(request.headers["content-type"] == "application/json")
        #expect(request.body == Data("{}".utf8))
        #expect(try parser.next() == nil)
    }

    @Test func waitsForARequestSplitAcrossReads() throws {
        var parser = HTTPRequestParser()
        parser.append(Data("POST /ev".utf8))
        #expect(try parser.next() == nil)
        parser.append(Data("ents HTTP/1.1\r\nContent-Length: 11\r\n\r\nhello".utf8))
        #expect(try parser.next() == nil)
        parser.append(Data(" world".utf8))
        #expect(try parser.next()?.body == Data("hello world".utf8))
    }

    @Test func readsBackToBackRequestsFromOneConnection() throws {
        var parser = HTTPRequestParser()
        parser.append(Data("POST /events HTTP/1.1\r\nContent-Length: 1\r\n\r\naGET / HTTP/1.1\r\n\r\nPOST /events HTTP/1.1\r\nContent-Le".utf8))
        #expect(try parser.next()?.body == Data("a".utf8))
        #expect(try parser.next()?.method == "GET")
        #expect(try parser.next() == nil)
        parser.append(Data("ngth: 1\r\n\r\nb".utf8))
        #expect(try parser.next()?.body == Data("b".utf8))
    }

    @Test func refusesWhatItCannotRead() {
        var garbage = HTTPRequestParser()
        garbage.append(Data("hello there\r\n\r\n".utf8))
        #expect(throws: HTTPRequestParser.Failure.malformed) { try garbage.next() }

        var chunked = HTTPRequestParser()
        chunked.append(Data("POST /events HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n".utf8))
        #expect(throws: HTTPRequestParser.Failure.malformed) { try chunked.next() }

        var endless = HTTPRequestParser()
        endless.append(Data(repeating: UInt8(ascii: "a"), count: HTTPRequestParser.headLimit + 1))
        #expect(throws: HTTPRequestParser.Failure.tooLarge) { try endless.next() }
    }
}

struct NetworkEventTests {
    static let posted = """
    {
      "id": "6F9619FF-8B86-D011-B42D-00C04FC964FF",
      "bundleID": "com.example.cafe",
      "method": "POST",
      "url": "https://api.example.com/v1/orders?table=4",
      "requestHeaders": { "Content-Type": "application/json" },
      "requestBody": "eyJkcmluayI6InRlYSJ9",
      "requestBodySize": 15,
      "status": 201,
      "responseHeaders": { "Content-Type": "application/json" },
      "responseBody": "eyJpZCI6NH0=",
      "responseBodySize": 8,
      "startedAt": 1760436000.5,
      "duration": 0.25
    }
    """

    @Test func decodesWhatTheLibraryPosts() throws {
        let event = try NetworkEvent.decode(Data(Self.posted.utf8))
        #expect(event.bundleID == "com.example.cafe")
        #expect(event.method == "POST")
        #expect(event.host == "api.example.com")
        #expect(event.path == "/v1/orders?table=4")
        #expect(event.requestBody == Data(#"{"drink":"tea"}"#.utf8))
        #expect(event.status == 201)
        #expect(event.statusClass == .success)
        #expect(event.responseBody == Data(#"{"id":4}"#.utf8))
        #expect(event.startedAt == Date(timeIntervalSince1970: 1760436000.5))
        #expect(event.duration == 0.25)
        #expect(event.error == nil)
    }

    @Test func decodesARequestThatFailedBeforeAnyResponse() throws {
        let json = """
        { "id": "6F9619FF-8B86-D011-B42D-00C04FC964FF", "method": "GET", "url": "https://offline.example.com",
          "requestHeaders": {}, "requestBodySize": 0, "responseHeaders": {}, "responseBodySize": 0,
          "startedAt": 1760436000, "duration": 1.5, "error": "The Internet connection appears to be offline." }
        """
        let event = try NetworkEvent.decode(Data(json.utf8))
        #expect(event.status == nil)
        #expect(event.statusClass == .failed)
        #expect(event.path == "/")
        #expect(event.error == "The Internet connection appears to be offline.")
    }

    @Test func sortsStatusesAndFilters() {
        #expect(NetworkEvent.sample(status: 302).statusClass == .redirect)
        #expect(NetworkEvent.sample(status: 404).statusClass == .clientError)
        #expect(NetworkEvent.sample(status: 503).statusClass == .serverError)
        let event = NetworkEvent.sample(status: 404)
        #expect(event.matches(""))
        #expect(event.matches("404"))
        #expect(event.matches("EXAMPLE.com"))
        #expect(event.matches("com.example.cafe"))
        #expect(!event.matches("500"))
    }
}

struct CurlTests {
    @Test func writesAGetWithItsHeadersInOrder() {
        let event = NetworkEvent.sample(requestHeaders: ["Authorization": "Bearer abc", "Accept": "application/json"])
        #expect(event.curlCommand == """
        curl 'https://api.example.com/v1/menu?lang=en' \\
          -H 'Accept: application/json' \\
          -H 'Authorization: Bearer abc'
        """)
    }

    @Test func quotesTheBodyAndLeavesContentLengthToCurl() {
        let event = NetworkEvent.sample(
            method: "POST",
            requestHeaders: ["Content-Type": "application/json", "Content-Length": "21"],
            requestBody: Data(#"{"note":"it's done"}"#.utf8)
        )
        #expect(event.curlCommand == """
        curl 'https://api.example.com/v1/menu?lang=en' \\
          -X POST \\
          -H 'Content-Type: application/json' \\
          --data-raw '{"note":"it'\\''s done"}'
        """)
    }

    @Test func pipesBinaryBodiesThroughBase64() {
        let event = NetworkEvent.sample(method: "PUT", requestBody: Data([0, 1, 2, 255]))
        #expect(event.curlCommand == "echo AAEC/w== | base64 --decode | curl 'https://api.example.com/v1/menu?lang=en' \\\n  -X PUT \\\n  --data-binary @-")
        #expect(NetworkEvent.sample(method: "HEAD").curlCommand == "curl 'https://api.example.com/v1/menu?lang=en' \\\n  --head")
    }

    @Test func quotingSurvivesTheShell() throws {
        let text = #"it's "quoted" $HOME `date` \n done"#
        let shell = Process()
        let output = Pipe()
        shell.executableURL = URL(filePath: "/bin/sh")
        shell.arguments = ["-c", "printf %s \(NetworkEvent.shellQuoted(text))"]
        shell.standardOutput = output
        try shell.run()
        shell.waitUntilExit()
        #expect(String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self) == text)
    }
}

struct NetworkFormatTests {
    @Test func prettyPrintsJSONAndShowsOtherTextAsItIs() {
        #expect(NetworkFormat.text(Data(#"{"b":1,"a":[true]}"#.utf8)) == "{\n  \"a\" : [\n    true\n  ],\n  \"b\" : 1\n}")
        #expect(NetworkFormat.text(Data("plain text".utf8)) == "plain text")
        #expect(NetworkFormat.text(Data([0, 1, 2])) == nil)
        #expect(NetworkFormat.text(nil) == nil)
    }

    @Test func readsABodyCutOffPartwayThroughACharacter() {
        let cut = Data("café".utf8).dropLast()
        #expect(NetworkFormat.text(cut) == nil)
        #expect(NetworkFormat.text(cut, truncated: true) == "caf")
    }

    @Test func writesShortDurationsInMilliseconds() {
        #expect(NetworkFormat.duration(0.1234) == "123 ms")
        #expect(NetworkFormat.duration(1.5) == "1.50 s")
    }
}

@MainActor
struct NetworkMonitorTests {
    @Test func receivesEventsPostedToItsPort() async throws {
        let monitor = NetworkMonitor()
        let port = try await monitor.start()
        #expect(try await monitor.start() == port)
        defer { monitor.stop() }
        var request = URLRequest(url: try #require(URL(string: "http://127.0.0.1:\(port)/events")))
        request.httpMethod = "POST"

        let (_, accepted) = try await URLSession.shared.upload(for: request, from: Data(NetworkEventTests.posted.utf8))
        #expect((accepted as? HTTPURLResponse)?.statusCode == 204)
        let (_, rejected) = try await URLSession.shared.upload(for: request, from: Data("{}".utf8))
        #expect((rejected as? HTTPURLResponse)?.statusCode == 400)
        try await waitUntil { !monitor.events.isEmpty }
        #expect(monitor.events.map(\.url) == ["https://api.example.com/v1/orders?table=4"])
    }

    @Test func keepsTheNewest500() {
        let monitor = NetworkMonitor()
        for _ in 0..<(NetworkMonitor.capacity + 10) { monitor.record(.sample()) }
        let newest = NetworkEvent.sample(method: "DELETE")
        monitor.record(newest)
        #expect(monitor.events.count == NetworkMonitor.capacity)
        #expect(monitor.events.first == newest)
        monitor.clear()
        #expect(monitor.events.isEmpty)
    }

    @Test func loadsTheLibraryThroughSimctlChildVariables() {
        let environment = NetworkMonitor.launchEnvironment(port: 50123, dylib: URL(filePath: "/Apps/Better Sim.app/Contents/Resources/BetterSimNetworkMonitor.dylib"))
        #expect(environment == [
            "SIMCTL_CHILD_DYLD_INSERT_LIBRARIES": "/Apps/Better Sim.app/Contents/Resources/BetterSimNetworkMonitor.dylib",
            "SIMCTL_CHILD_BETTERSIM_MONITOR_PORT": "50123",
        ])
    }
}

/// Builds the monitor and a small command line tool for the simulator, and runs the tool on the throwaway device named
/// in BETTERSIM_NET_SCRATCH_UDID with the monitor injected, the way BetterSim relaunches an app.
@MainActor
struct ScratchNetworkTests {
    let udid = ProcessInfo.processInfo.environment["BETTERSIM_NET_SCRATCH_UDID"]

    static let tool = #"""
    #import <Foundation/Foundation.h>

    @interface RefuseRedirects : NSObject <NSURLSessionTaskDelegate>
    @end

    @implementation RefuseRedirects
    - (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task willPerformHTTPRedirection:(NSHTTPURLResponse *)response
            newRequest:(NSURLRequest *)request completionHandler:(void (^)(NSURLRequest *))completionHandler {
        completionHandler(nil);
    }
    @end

    static void print_result(NSString *label, NSData *data, NSURLResponse *response, NSError *error) {
        NSHTTPURLResponse *http = (NSHTTPURLResponse *)response;
        NSString *body = data.length < 100 ? [[NSString alloc] initWithData:data ?: [NSData data] encoding:NSUTF8StringEncoding]
                                           : [NSString stringWithFormat:@"<%lu bytes>", (unsigned long)data.length];
        NSString *seen = [http valueForHTTPHeaderField:@"X-Saw-Session-Header"] ?: @"-";
        printf("%s %ld %s %s %s\n", label.UTF8String, (long)http.statusCode, seen.UTF8String, body.UTF8String,
               error ? error.domain.UTF8String : "");
    }

    static void fetch(NSString *label, NSURLSession *session, NSURLRequest *request, NSData *upload) {
        dispatch_semaphore_t done = dispatch_semaphore_create(0);
        void (^finished)(NSData *, NSURLResponse *, NSError *) = ^(NSData *data, NSURLResponse *response, NSError *error) {
            print_result(label, data, response, error);
            dispatch_semaphore_signal(done);
        };
        NSURLSessionTask *task = upload ? [session uploadTaskWithRequest:request fromData:upload completionHandler:finished]
                                        : [session dataTaskWithRequest:request completionHandler:finished];
        [task resume];
        dispatch_semaphore_wait(done, DISPATCH_TIME_FOREVER);
    }

    int main(int argc, char *argv[]) {
        @autoreleasepool {
            NSString *base = @(argv[1]);
            NSURLRequest *(^get)(NSString *) = ^(NSString *path) {
                return [NSURLRequest requestWithURL:[NSURL URLWithString:[base stringByAppendingString:path]]];
            };
            fetch(@"shared", NSURLSession.sharedSession, get(@"/hello?from=shared"), nil);

            NSURLSessionConfiguration *ephemeral = NSURLSessionConfiguration.ephemeralSessionConfiguration;
            ephemeral.HTTPAdditionalHeaders = @{ @"X-Session-Header": @"yes" };
            NSMutableURLRequest *order = [get(@"/echo") mutableCopy];
            order.HTTPMethod = @"POST";
            [order setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
            order.HTTPBody = [@"{\"drink\":\"tea\"}" dataUsingEncoding:NSUTF8StringEncoding];
            fetch(@"ephemeral", [NSURLSession sessionWithConfiguration:ephemeral], order, nil);

            NSURLSession *custom = [NSURLSession sessionWithConfiguration:NSURLSessionConfiguration.defaultSessionConfiguration];
            fetch(@"redirect", custom, get(@"/redirect"), nil);
            NSURLSession *refusing = [NSURLSession sessionWithConfiguration:NSURLSessionConfiguration.defaultSessionConfiguration
                                                                   delegate:[RefuseRedirects new] delegateQueue:nil];
            fetch(@"refusing", refusing, get(@"/redirect"), nil);
            NSMutableURLRequest *upload = [get(@"/upload") mutableCopy];
            upload.HTTPMethod = @"POST";
            fetch(@"upload", custom, upload, [NSMutableData dataWithLength:100 * 1024]);
            fetch(@"big", custom, get(@"/big"), nil);
            fetch(@"refused", custom, [NSURLRequest requestWithURL:[NSURL URLWithString:@"http://127.0.0.1:1/refused"]], nil);
            // Each request is reported after it finishes, so give the last report a moment to go out.
            [NSThread sleepForTimeInterval:2];
        }
        return 0;
    }
    """#

    @Test func capturesRequestsFromAProcessOnTheSimulator() async throws {
        guard let udid else { return }
        let folder = FileManager.default.temporaryDirectory.appending(path: "bettersim-network-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let packageRoot = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let library = folder.appending(path: "\(NetworkMonitor.libraryName).dylib")
        try Self.buildForSimulator(packageRoot.appending(path: "Monitor/\(NetworkMonitor.libraryName).m"), to: library, extraArguments: ["-dynamiclib"])
        let toolSource = folder.appending(path: "fetch.m")
        try Self.tool.write(to: toolSource, atomically: true, encoding: .utf8)
        let tool = folder.appending(path: "fetch")
        try Self.buildForSimulator(toolSource, to: tool)

        let server = try await TestServer.start()
        defer { server.stop() }
        let monitor = NetworkMonitor()
        let port = try await monitor.start()
        defer { monitor.stop() }

        let output = String(decoding: try await Simctl.run(
            ["spawn", udid, tool.path(percentEncoded: false), "http://127.0.0.1:\(server.port)"],
            environment: NetworkMonitor.launchEnvironment(port: port, dylib: library)
        ), as: UTF8.self)
        #expect(output.contains("shared 200 - hello"))
        #expect(output.contains(#"ephemeral 201 yes {"drink":"tea"}"#))
        #expect(output.contains("redirect 200 - hello"))
        #expect(output.contains("refusing 302 - "))
        #expect(output.contains("upload 200 - received 102400"))
        #expect(output.contains("big 200 - <307200 bytes>"))
        #expect(output.contains("refused 0 -  NSURLErrorDomain"))

        try await waitUntil { monitor.events.count >= 8 }
        let events = Dictionary(monitor.events.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
        #expect(events.keys.sorted() == ["/big", "/echo", "/hello?from=redirect", "/hello?from=shared", "/redirect", "/refused", "/upload"])
        let shared = try #require(events["/hello?from=shared"])
        #expect(shared.method == "GET")
        #expect(shared.status == 200)
        #expect(shared.responseBody == Data("hello".utf8))
        #expect(shared.responseHeaders["Content-Type"] == "text/plain")
        #expect(shared.bundleID == "fetch")
        #expect(shared.duration > 0)
        let order = try #require(events["/echo"])
        #expect(order.method == "POST")
        #expect(order.status == 201)
        #expect(order.requestBody == Data(#"{"drink":"tea"}"#.utf8))
        #expect(order.requestHeaders["Content-Type"] == "application/json")
        #expect(order.responseBody == Data(#"{"drink":"tea"}"#.utf8))
        let redirect = try #require(events["/redirect"])
        #expect(redirect.status == 302)
        #expect(redirect.responseHeaders["Location"] == "/hello?from=redirect")
        #expect(redirect.error == nil)
        #expect(monitor.events.filter { $0.path == "/redirect" }.count == 2)
        #expect(events["/hello?from=redirect"]?.status == 200)
        let upload = try #require(events["/upload"])
        #expect(upload.requestBodySize == 100 * 1024)
        #expect(upload.requestBody?.count == 64 * 1024)
        let big = try #require(events["/big"])
        #expect(big.responseBodySize == 300 * 1024)
        #expect(big.responseBody?.count == 256 * 1024)
        let refused = try #require(events["/refused"])
        #expect(refused.status == nil)
        #expect(refused.error?.isEmpty == false)
        #expect(!monitor.events.contains { $0.url.contains(":\(port)/") })
    }

    static func buildForSimulator(_ source: URL, to output: URL, extraArguments: [String] = []) throws {
        #if arch(arm64)
        let architecture = "arm64"
        #else
        let architecture = "x86_64"
        #endif
        try run("/usr/bin/xcrun", [
            "-sdk", "iphonesimulator", "clang", "-fobjc-arc", "-arch", architecture, "-mios-simulator-version-min=15.0",
            "-framework", "Foundation", "-o", output.path(percentEncoded: false), source.path(percentEncoded: false),
        ] + extraArguments)
        try run("/usr/bin/codesign", ["--force", "--sign", "-", output.path(percentEncoded: false)])
    }

    static func run(_ executable: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(filePath: executable)
        process.arguments = arguments
        try process.run()
        process.waitUntilExit()
        try #require(process.terminationStatus == 0, "\(executable) \(arguments.joined(separator: " "))")
    }
}

/// A tiny HTTP server for the tool on the simulator to talk to.
private final class TestServer: Sendable {
    let port: UInt16
    private let listener: NWListener

    private init(listener: NWListener, port: UInt16) {
        self.listener = listener
        self.port = port
    }

    static func start() async throws -> TestServer {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        let listener = try NWListener(using: parameters)
        let queue = DispatchQueue(label: "bettersim.test-server")
        listener.newConnectionHandler = { connection in
            connection.start(queue: queue)
            serve(connection, parser: HTTPRequestParser())
        }
        let port: UInt16 = try await withCheckedThrowingContinuation { continuation in
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    listener.stateUpdateHandler = nil
                    continuation.resume(returning: listener.port?.rawValue ?? 0)
                case .failed(let error):
                    listener.stateUpdateHandler = nil
                    continuation.resume(throwing: error)
                default:
                    break
                }
            }
            listener.start(queue: queue)
        }
        return TestServer(listener: listener, port: port)
    }

    func stop() {
        listener.cancel()
    }

    private static func serve(_ connection: NWConnection, parser: HTTPRequestParser) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, isComplete, error in
            var parser = parser
            if let data { parser.append(data) }
            while let request = try? parser.next() {
                connection.send(content: response(to: request), completion: .idempotent)
            }
            if isComplete || error != nil {
                connection.cancel()
            } else {
                serve(connection, parser: parser)
            }
        }
    }

    private static func response(to request: HTTPRequestParser.Request) -> Data {
        func reply(_ status: String, _ headers: [String], _ body: Data = Data()) -> Data {
            Data(((["HTTP/1.1 \(status)", "Content-Length: \(body.count)"] + headers).joined(separator: "\r\n") + "\r\n\r\n").utf8) + body
        }
        switch request.path {
        case "/hello?from=shared", "/hello?from=redirect":
            return reply("200 OK", ["Content-Type: text/plain"], Data("hello".utf8))
        case "/echo":
            let seen = request.headers["x-session-header"] ?? "no"
            return reply("201 Created", ["Content-Type: application/json", "X-Saw-Session-Header: \(seen)"], request.body)
        case "/redirect":
            return reply("302 Found", ["Location: /hello?from=redirect"])
        case "/upload":
            return reply("200 OK", ["Content-Type: text/plain"], Data("received \(request.body.count)".utf8))
        case "/big":
            return reply("200 OK", ["Content-Type: application/octet-stream"], Data(count: 300 * 1024))
        default:
            return reply("404 Not Found", [])
        }
    }
}

/// Gives events up to ten seconds to arrive, since they're delivered asynchronously.
@MainActor
private func waitUntil(_ condition: () -> Bool) async throws {
    var attempts = 0
    while !condition(), attempts < 200 {
        attempts += 1
        try await Task.sleep(for: .milliseconds(50))
    }
}

extension NetworkEvent {
    static func sample(
        method: String = "GET",
        status: Int? = 200,
        requestHeaders: [String: String] = [:],
        requestBody: Data? = nil
    ) -> NetworkEvent {
        NetworkEvent(
            id: UUID(),
            bundleID: "com.example.cafe",
            method: method,
            url: "https://api.example.com/v1/menu?lang=en",
            requestHeaders: requestHeaders,
            requestBody: requestBody,
            requestBodySize: requestBody?.count ?? 0,
            status: status,
            responseHeaders: ["Content-Type": "application/json"],
            responseBody: Data(#"{"items":[]}"#.utf8),
            responseBodySize: 12,
            startedAt: Date(timeIntervalSince1970: 1760436000),
            duration: 0.12,
            error: nil
        )
    }
}
