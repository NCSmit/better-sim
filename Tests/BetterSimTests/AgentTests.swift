import AVFoundation
import Foundation
import ImageIO
import Testing
@testable import BetterSim

struct CommandLineEntryTests {
    @Test func startsTheToolOnlyWhenAskedTo() {
        let app = "/Applications/BetterSim.app/Contents/MacOS/BetterSim"
        #expect(CommandLineTool.arguments(from: [app, "cli", "screenshot", "--frame"]) == ["screenshot", "--frame"])
        #expect(CommandLineTool.arguments(from: ["/Users/me/.local/bin/bettersim", "ui"]) == ["ui"])
        #expect(CommandLineTool.arguments(from: ["bettersim"]) == [])
        #expect(CommandLineTool.arguments(from: [app]) == nil)
        #expect(CommandLineTool.arguments(from: [app, "-NSDocumentRevisionsDebugMode", "YES"]) == nil)
        #expect(CommandLineTool.arguments(from: ["/tmp/BetterSim", "screenshot"]) == nil)
    }

    @Test func sendsCameraImagesAsFullPaths() throws {
        let image = FileManager.default.temporaryDirectory.appending(path: "bettersim-\(UUID().uuidString).png")
        try Data().write(to: image)
        defer { try? FileManager.default.removeItem(at: image) }
        #expect(CommandLineTool.fullPathIfFile(image.path) == image.standardizedFileURL.path)
        #expect(CommandLineTool.fullPathIfFile(".") == URL.currentDirectory().standardizedFileURL.path)
        #expect(CommandLineTool.fullPathIfFile("FaceTime HD Camera") == "FaceTime HD Camera")
    }
}

struct CommandLineParsingTests {
    func command(_ arguments: String...) throws -> CLICommand {
        try CLIInvocation.parse(arguments).command
    }

    func failure(_ arguments: [String]) -> AgentFailure? {
        do {
            _ = try CLIInvocation.parse(arguments)
            return nil
        } catch {
            return error as? AgentFailure
        }
    }

    @Test func readsTheSimulatorCommands() throws {
        #expect(try command("devices") == .devices)
        #expect(try command("screenshot") == .screenshot(framed: false, output: nil))
        #expect(try command("screenshot", "--frame", "--out", "shot.png") == .screenshot(framed: true, output: "shot.png"))
        #expect(try command("screenshot", "--out=~/shot.png") == .screenshot(framed: false, output: "~/shot.png"))
        #expect(try command("record", "start") == .recordStart(gif: false))
        #expect(try command("record", "start", "--gif") == .recordStart(gif: true))
        #expect(try command("record", "stop", "--out", "clip.mp4") == .recordStop(gif: false, output: "clip.mp4"))
        #expect(try command("record", "stop", "--gif") == .recordStop(gif: true, output: nil))
        #expect(try command("open", "myapp://settings?tab=1") == .open("myapp://settings?tab=1"))
        #expect(try command("push", "com.example.app", "payload.apns") == .push(bundleID: "com.example.app", file: "payload.apns"))
        #expect(try command("push", "com.example.app", "-") == .push(bundleID: "com.example.app", file: "-"))
        #expect(try command("launch", "com.example.app") == .launch("com.example.app"))
        #expect(try command("terminate", "com.example.app") == .terminate("com.example.app"))
        #expect(try command("appearance", "dark") == .appearance("dark"))
        #expect(try command("appearance", "light") == .appearance("light"))
        #expect(try command("appearance") == .appearance(nil))
        #expect(try command("statusbar", "clean") == .statusBar(clean: true))
        #expect(try command("statusbar", "clear") == .statusBar(clean: false))
        #expect(try command("location", "52.37,4.89") == .location(Coordinate(latitude: 52.37, longitude: 4.89)))
        #expect(try command("location", "-33.86", "151.2") == .location(Coordinate(latitude: -33.86, longitude: 151.2)))
        #expect(try command("location", "clear") == .location(nil))
        #expect(try command("doctor") == .doctor)
        #expect(try command("help") == .help)
        #expect(try command("--help") == .help)
        #expect(try command("tap", "-h") == .help)
    }

    @Test func readsTheScreenCommands() throws {
        #expect(try command("ui") == .ui(includeAll: false))
        #expect(try command("ui", "--all") == .ui(includeAll: true))
        #expect(try command("tap", "120", "640.5") == .tap(x: 120, y: 640.5))
        #expect(try command("tap", "--label", "Sign In") == .tapLabel("Sign In"))
        #expect(try command("tap", "--label=Sign In") == .tapLabel("Sign In"))
        #expect(try command("swipe", "200", "700", "200", "100") == .swipe(fromX: 200, fromY: 700, toX: 200, toY: 100, duration: 0.3))
        #expect(try command("swipe", "0", "1", "2", "3", "--duration", "1.5") == .swipe(fromX: 0, fromY: 1, toX: 2, toY: 3, duration: 1.5))
        #expect(try command("type", "hello", "world") == .type("hello world"))
        #expect(try command("type", "--", "-5 degrees") == .type("-5 degrees"))
        #expect(try command("wait", "--label", "Welcome") == .wait(label: "Welcome", timeout: 10))
        #expect(try command("wait", "--label", "Welcome", "--timeout", "30") == .wait(label: "Welcome", timeout: 30))
        #expect(try command("preview") == .preview(port: nil))
        #expect(try command("preview", "--port", "8123") == .preview(port: 8123))
    }

    @Test func readsTheCameraCommand() throws {
        #expect(try command("camera") == .camera(on: nil, bundleID: nil, source: nil))
        #expect(try command("camera", "on", "--app", "com.example.trails") == .camera(on: true, bundleID: "com.example.trails", source: nil))
        #expect(try command("camera", "off") == .camera(on: false, bundleID: nil, source: nil))
        #expect(try command("camera", "on", "--source", "Test Pattern") == .camera(on: true, bundleID: nil, source: "Test Pattern"))
        #expect(try command("camera", "on", "--source", "codes/qr.png") == .camera(on: true, bundleID: nil, source: "codes/qr.png"))
        #expect(throws: AgentFailure.self) { try command("camera", "maybe") }
        #expect(throws: AgentFailure.self) { try command("camera", "on", "now") }
    }

    @Test func takesTheGlobalOptionsAnywhere() throws {
        let before = try CLIInvocation.parse(["--udid", "ABC", "--json", "screenshot"])
        let after = try CLIInvocation.parse(["screenshot", "--json", "--udid=ABC"])
        #expect(before == after)
        #expect(before.udid == "ABC")
        #expect(before.json)
        #expect(try CLIInvocation.parse(["devices"]).udid == nil)
    }

    @Test func explainsWrongArguments() {
        let wrong: [[String]] = [
            [], ["frobnicate"], ["tap", "1"], ["tap", "x", "y"], ["tap", "1", "2", "--label", "OK"], ["swipe", "1", "2", "3"],
            ["swipe", "1", "2", "3", "4", "--duration", "0"], ["wait"], ["wait", "--label", "A", "--timeout", "-1"],
            ["wait", "--label", "A", "extra"], ["appearance", "blue"], ["statusbar"], ["statusbar", "pretty"],
            ["location", "Amsterdam"], ["location", "95,10"], ["record"], ["record", "pause"], ["record", "start", "--out", "x.mp4"],
            ["open"], ["push", "com.example.app"], ["launch"], ["preview", "--port", "70000"], ["preview", "--port", "web"],
            ["screenshot", "--all"], ["ui", "--label", "x"], ["--udid"], ["--colour", "devices"], ["-x", "devices"],
            ["devices", "extra"], ["type"], ["ui", "--json=yes"],
        ]
        for arguments in wrong {
            #expect(failure(arguments)?.kind == .usage, "\(arguments)")
        }
        #expect(failure(["screenshot", "--all"])?.message == "screenshot doesn't take --all.")
        #expect(failure(["frobnicate"])?.message == "There's no command called frobnicate.")
        #expect(failure(["tap", "1"])?.exitCode == 2)
    }
}

/// Collects what the tool prints, in place of standard output and standard error.
final class CapturedOutput: @unchecked Sendable {
    private let lock = NSLock()
    private var written: [String] = []
    private var errors: [String] = []

    var output: CommandLineOutput {
        CommandLineOutput(
            write: { text in self.lock.withLock { self.written.append(text) } },
            error: { text in self.lock.withLock { self.errors.append(text) } }
        )
    }

    var standardOutput: String { lock.withLock { written.joined(separator: "\n") } }
    var standardError: String { lock.withLock { errors.joined(separator: "\n") } }
}

struct AgentCodingTests {
    @Test func everyRequestSurvivesTheTrip() throws {
        let actions: [AgentAction] = [
            .ping, .listElements(includeAll: true), .tap(x: 10, y: 20.5), .tapLabel(label: "Sign In"),
            .swipe(fromX: 1, fromY: 2, toX: 3, toY: 4, duration: 0.5), .type(text: "héllo\n"),
            .waitForLabel(label: "Done", timeout: 5), .preview(port: nil), .preview(port: 8123),
            .camera(on: true, bundleID: "com.example.trails", source: "FaceTime"), .camera(on: nil, bundleID: nil, source: nil),
        ]
        for action in actions {
            for udid in ["ABC", nil] {
                let request = AgentRequest(action: action, udid: udid)
                #expect(try AgentCoding.decode(AgentRequest.self, from: AgentCoding.encode(request)) == request)
            }
        }
    }

    @Test func requestsHaveAPlainWireFormat() throws {
        let json = String(decoding: try AgentCoding.encode(AgentRequest(action: .tap(x: 10, y: 20), udid: "ABC")), as: UTF8.self)
        #expect(json == #"{"action":{"tap":{"x":10,"y":20}},"udid":"ABC"}"#)
        let decoded = try AgentCoding.decode(AgentRequest.self, from: Data(#"{"action":{"tapLabel":{"label":"OK"}}}"#.utf8))
        #expect(decoded == AgentRequest(action: .tapLabel(label: "OK"), udid: nil))
    }

    @Test func repliesCarryElementsStatusAndFailures() throws {
        let element = DeviceElement(
            role: "AXButton", label: "Continue", value: nil, identifier: "continue",
            frame: DeviceElement.Frame(CGRect(x: 20, y: 700.04, width: 362, height: 50))
        )
        #expect(String(decoding: try AgentCoding.encode(element), as: UTF8.self)
            == #"{"frame":{"height":50,"width":362,"x":20,"y":700},"identifier":"continue","label":"Continue","role":"AXButton"}"#)
        let status = AgentStatus(version: "0.1", accessibilityAllowed: true, simulatorWindows: 2, currentDevice: "ABC", previewURL: nil)
        let reply = AgentReply(message: "Found it.", elements: [element], element: element, url: "http://127.0.0.1:9/token/", status: status)
        #expect(try AgentCoding.decode(AgentReply.self, from: AgentCoding.encode(reply)) == reply)
        let failed = try AgentCoding.decode(AgentReply.self, from: AgentCoding.encode(AgentReply(failure: .accessibilityNeeded)))
        #expect(failed.failure == .accessibilityNeeded)
        #expect(failed.failure?.exitCode == 4)
    }

    @Test func failuresHaveTheDocumentedExitCodes() {
        let codes: [(AgentFailure.Kind, Int32)] = [
            (.failed, 1), (.usage, 2), (.appNotRunning, 3), (.accessibility, 4), (.noDevice, 5), (.noWindow, 5), (.notFound, 6), (.timeout, 6),
        ]
        for (kind, code) in codes {
            #expect(AgentFailure(kind, "").exitCode == code, "\(kind)")
        }
    }

    @Test func usesThePerUserTemporaryFolder() {
        let folder = AgentSocket.userTemporaryDirectory.path(percentEncoded: false)
        #expect(folder.hasPrefix("/var/folders/") || folder.hasPrefix("/private/var/folders/"))
        #expect(folder.hasSuffix("/T/") || folder.hasSuffix("/T"))
        #expect(AgentSocket.path.hasSuffix("/bettersim-agent.sock") || ProcessInfo.processInfo.environment[AgentSocket.overrideVariable] != nil)
    }
}

struct AgentSocketTests {
    /// Short, because a Unix socket path can only be 103 bytes long.
    static func temporarySocket() -> String {
        AgentSocket.userTemporaryDirectory.appending(path: "bst-\(UUID().uuidString.prefix(8)).sock").path(percentEncoded: false)
    }

    @Test func answersEachConnectionWithOneReply() async throws {
        let path = Self.temporarySocket()
        let server = try AgentServer(path: path) { request in
            AgentReply(message: "\(request.action) for \(request.udid ?? "the current device")")
        }
        defer { server.stop() }
        let reply = try await AgentClient.send(AgentRequest(action: .tap(x: 1, y: 2), udid: "ABC"), to: path, timeout: 5)
        #expect(reply.message == "tap(x: 1.0, y: 2.0) for ABC")

        let messages = try await withThrowingTaskGroup(of: String?.self) { group in
            for index in 0..<8 {
                group.addTask { try await AgentClient.send(AgentRequest(action: .type(text: "\(index)")), to: path, timeout: 5).message }
            }
            return try await group.reduce(into: [String?]()) { $0.append($1) }
        }
        #expect(Set(messages.compactMap { $0 }).count == 8)
    }

    @Test func refusesRequestsItCantRead() async throws {
        let path = Self.temporarySocket()
        let server = try AgentServer(path: path) { _ in AgentReply(message: "should not run") }
        defer { server.stop() }
        let raw = try await UnixSocket.exchange(Data("not json".utf8), path: path, timeout: 5)
        let reply = try AgentCoding.decode(AgentReply.self, from: raw)
        #expect(reply.failure?.kind == .usage)
        #expect(reply.message == nil)
    }

    @Test func saysWhenNothingIsListening() async {
        await #expect(throws: AgentFailure.appNotRunning) {
            try await AgentClient.send(AgentRequest(action: .ping), to: Self.temporarySocket(), timeout: 2)
        }
    }

    @Test func onlyItsOwnerCanConnect() throws {
        let path = Self.temporarySocket()
        let server = try AgentServer(path: path) { _ in AgentReply() }
        defer { server.stop() }
        var info = stat()
        #expect(lstat(path, &info) == 0)
        #expect(info.st_mode & 0o777 == 0o600)
        server.stop()
        #expect(lstat(path, &info) != 0, "stopping removes the socket file")
    }

    @Test func replacesAStaleSocketButNeverALiveOne() async throws {
        let path = Self.temporarySocket()
        let abandoned = socket(AF_UNIX, SOCK_STREAM, 0)
        var address = try UnixSocket.address(path)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(abandoned, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        #expect(bound == 0)
        close(abandoned)

        let server = try AgentServer(path: path) { _ in AgentReply(message: "fresh") }
        defer { server.stop() }
        #expect(try await AgentClient.send(AgentRequest(action: .ping), to: path, timeout: 5).message == "fresh")
        #expect(throws: AgentFailure.self) { try AgentServer(path: path) { _ in AgentReply() } }
        #expect(try await AgentClient.send(AgentRequest(action: .ping), to: path, timeout: 5).message == "fresh")
    }

    @Test func leavesOtherFilesAlone() throws {
        let path = Self.temporarySocket()
        try Data("keep me".utf8).write(to: URL(filePath: path))
        defer { unlink(path) }
        #expect(throws: AgentFailure.self) { try AgentServer(path: path) { _ in AgentReply() } }
        #expect(try String(contentsOfFile: path, encoding: .utf8) == "keep me")
    }
}

@MainActor
struct AgentEndToEndTests {
    @Test func saysWhenBetterSimIsntOpen() async {
        let captured = CapturedOutput()
        let status = await CommandLineTool.run(["ui"], output: captured.output, socket: AgentSocketTests.temporarySocket())
        #expect(status == 3)
        #expect(captured.standardError.contains("BetterSim isn't running"))

        let json = CapturedOutput()
        #expect(await CommandLineTool.run(["--json", "tap", "1", "2"], output: json.output, socket: AgentSocketTests.temporarySocket()) == 3)
        #expect(json.standardOutput.contains(#""kind":"appNotRunning""#))
        #expect(json.standardOutput.contains(#""ok":false"#))
    }

    @Test func passesTheAppsAnswerBackToTheTool() async throws {
        let path = AgentSocketTests.temporarySocket()
        let element = DeviceElement(role: "AXButton", label: "OK", value: nil, identifier: nil, frame: DeviceElement.Frame(CGRect(x: 1, y: 2, width: 3, height: 4)))
        let server = try AgentServer(path: path) { request in
            switch request.action {
            case .listElements: AgentReply(elements: [element])
            case .tapLabel: AgentReply(message: "Tapped “OK”.", element: element)
            case .waitForLabel: AgentReply(failure: AgentFailure(.timeout, "Nothing labelled “Done” appeared."))
            default: AgentReply(message: "Done.")
            }
        }
        defer { server.stop() }

        let ui = CapturedOutput()
        #expect(await CommandLineTool.run(["ui"], output: ui.output, socket: path) == 0)
        let listed = try AgentCoding.decode([DeviceElement].self, from: Data(ui.standardOutput.utf8))
        #expect(listed == [element])

        let tap = CapturedOutput()
        #expect(await CommandLineTool.run(["--json", "tap", "--label", "OK"], output: tap.output, socket: path) == 0)
        #expect(tap.standardOutput.contains(#""label":"OK""#))

        let wait = CapturedOutput()
        #expect(await CommandLineTool.run(["wait", "--label", "Done", "--timeout", "1"], output: wait.output, socket: path) == 6)
        #expect(wait.standardError.contains("Nothing labelled “Done” appeared."))
    }

    /// Runs only without the Accessibility grant, which is how tests usually run, to check the whole path from the
    /// tool through the socket to the app's commands.
    @Test func explainsMissingAccessibility() async throws {
        guard !AccessibilityScreenFinder.isTrusted else { return }
        let path = AgentSocketTests.temporarySocket()
        let commands = AgentCommands()
        let server = try AgentServer(path: path) { request in await commands.handle(request) }
        defer { server.stop() }

        for arguments in [["tap", "10", "10"], ["ui"], ["type", "hello"], ["wait", "--label", "OK"], ["swipe", "1", "2", "3", "4"]] {
            let captured = CapturedOutput()
            #expect(await CommandLineTool.run(["--json"] + arguments, output: captured.output, socket: path) == 4, "\(arguments)")
            #expect(captured.standardOutput.contains(#""kind":"accessibility""#))
        }
        let reply = try await AgentClient.send(AgentRequest(action: .ping), to: path, timeout: 5)
        #expect(reply.status?.accessibilityAllowed == false)

        let doctor = CapturedOutput()
        #expect(await CommandLineTool.run(["--json", "doctor"], output: doctor.output, socket: path) == 1)
        struct Report: Decodable {
            struct Check: Decodable { let name: String; let ok: Bool }
            let ok: Bool
            let checks: [Check]
        }
        let report = try AgentCoding.decode(Report.self, from: Data(doctor.standardOutput.utf8))
        #expect(report.checks.first { $0.name == "BetterSim app" }?.ok == true)
        #expect(report.checks.first { $0.name == "Accessibility" }?.ok == false)
    }
}

struct DeviceScreenTests {
    let portrait = DeviceScreen(frame: CGRect(x: 100, y: 50, width: 201, height: 437), pointSize: CGSize(width: 402, height: 874))

    @Test func mapsDevicePointsOntoTheMac() {
        #expect(portrait.size == CGSize(width: 402, height: 874))
        #expect(portrait.screenPoint(.zero) == CGPoint(x: 100, y: 50))
        #expect(portrait.screenPoint(CGPoint(x: 402, y: 874)) == CGPoint(x: 301, y: 487))
        #expect(portrait.screenPoint(CGPoint(x: 201, y: 437)) == CGPoint(x: 200.5, y: 268.5))
        #expect(portrait.devicePoint(CGPoint(x: 200.5, y: 268.5)) == CGPoint(x: 201, y: 437))
        #expect(portrait.deviceRect(CGRect(x: 110, y: 60, width: 50, height: 25)) == CGRect(x: 20, y: 20, width: 100, height: 50))
    }

    @Test func turnsWithTheWindow() {
        let landscape = DeviceScreen(frame: CGRect(x: 0, y: 0, width: 874, height: 402), pointSize: CGSize(width: 402, height: 874))
        #expect(landscape.size == CGSize(width: 874, height: 402))
        #expect(landscape.screenPoint(CGPoint(x: 800, y: 10)) == CGPoint(x: 800, y: 10))
        #expect(landscape.contains(CGPoint(x: 800, y: 10)))
        #expect(!landscape.contains(CGPoint(x: 10, y: 800)))
    }

    @Test func keepsPointsOnTheScreen() {
        #expect(portrait.contains(.zero))
        #expect(portrait.contains(CGPoint(x: 401.9, y: 873.9)))
        #expect(!portrait.contains(CGPoint(x: 402, y: 10)))
        #expect(!portrait.contains(CGPoint(x: -1, y: 10)))
        #expect(portrait.devicePoint(fraction: CGPoint(x: 0.5, y: 0.25)) == CGPoint(x: 201, y: 218.5))
        #expect(portrait.devicePoint(fraction: CGPoint(x: 2, y: -1)) == CGPoint(x: 402, y: 0))
    }

    @Test func roundsElementFramesToATenthOfAPoint() {
        let frame = DeviceElement.Frame(portrait.deviceRect(CGRect(x: 100.123, y: 50, width: 10.07, height: 5)))
        #expect(frame == DeviceElement.Frame(CGRect(x: 0.2, y: 0, width: 20.1, height: 10)))
    }
}

struct DeviceElementsTests {
    func element(_ role: String, _ label: String?, value: String? = nil, id: String? = nil, y: Double, height: Double = 44) -> DeviceElement {
        DeviceElement(role: role, label: label, value: value, identifier: id, frame: DeviceElement.Frame(CGRect(x: 16, y: y, width: 370, height: height)))
    }

    @Test func findsWhatSomeoneMeans() {
        let elements = [
            element("AXStaticText", "Sign in to continue", y: 100),
            element("AXStaticText", nil, value: "Sign In", y: 150),
            element("AXButton", "Sign In", y: 200),
            element("AXButton", "Sign in with Apple", y: 300),
            element("AXTextField", "Email", value: "me@example.com", id: "email-field", y: 400),
            element("AXButton", "Café", y: 500),
        ]
        func match(_ text: String) -> DeviceElement? { DeviceElements.match(text, in: elements) }
        #expect(match("sign in")?.frame.y == 200)
        #expect(match("  Sign   In ")?.frame.y == 200)
        #expect(match("Email")?.role == "AXTextField")
        #expect(match("email-field")?.label == "Email")
        #expect(match("me@example.com")?.identifier == "email-field")
        #expect(match("cafe")?.label == "Café")
        #expect(match("with Apple")?.label == "Sign in with Apple")
        #expect(match("continue")?.frame.y == 100)
        #expect(match("Checkout") == nil)
        #expect(match(" ") == nil)
    }

    @Test func prefersControlsOverTheirCaptions() {
        let elements = [element("AXStaticText", "Continue", y: 100), element("AXButton", "Continue", y: 600)]
        #expect(DeviceElements.match("Continue", in: elements)?.role == "AXButton")
    }

    @Test func leavesOutEmptyContainers() {
        let elements = [
            element("AXGroup", nil, y: 0, height: 800),
            element("AXGroup", "Toolbar", y: 0),
            element("AXButton", nil, y: 50),
            element("AXImage", nil, id: "logo", y: 100),
            element("AXStaticText", nil, value: "Hello", y: 150),
        ]
        #expect(DeviceElements.meaningful(elements).map(\.frame.y) == [0, 50, 100, 150])
        #expect(DeviceElements.meaningful(elements).first?.label == "Toolbar")
    }

    @Test func tapsTheVisiblePartOfAnElement() {
        let size = CGSize(width: 402, height: 874)
        #expect(element("AXButton", "OK", y: 100).tapPoint(within: size) == CGPoint(x: 201, y: 122))
        #expect(element("AXCell", "Row", y: 800, height: 200).tapPoint(within: size) == CGPoint(x: 201, y: 837))
    }
}

struct KeyboardLayoutTests {
    let keys: [CGKeyCode: (plain: String, shifted: String)] = [
        0: ("a", "A"), 18: ("1", "!"), 24: ("=", "+"), 49: (" ", " "), 36: ("\r", "\r"), 83: ("1", "1"), 10: ("é", "É"),
    ]

    var layout: KeyboardLayout {
        KeyboardLayout { code, shift in keys[code].map { shift ? $0.shifted : $0.plain } }
    }

    @Test func typesEachCharacterWithItsKey() {
        #expect(layout.keystroke(for: "a") == KeyboardLayout.Keystroke(keyCode: 0, shift: false))
        #expect(layout.keystroke(for: "A") == KeyboardLayout.Keystroke(keyCode: 0, shift: true))
        #expect(layout.keystroke(for: "!") == KeyboardLayout.Keystroke(keyCode: 18, shift: true))
        #expect(layout.keystroke(for: "+") == KeyboardLayout.Keystroke(keyCode: 24, shift: true))
        #expect(layout.keystroke(for: "é") == KeyboardLayout.Keystroke(keyCode: 10, shift: false))
        #expect(layout.keystroke(for: "😀") == nil)
        #expect(layout.keystroke(for: "z") == nil)
    }

    @Test func usesTheMainKeysForDigitsAndLineBreaks() {
        #expect(layout.keystroke(for: "1") == KeyboardLayout.Keystroke(keyCode: 18, shift: false))
        #expect(layout.keystroke(for: "\n") == KeyboardLayout.Keystroke(keyCode: 36, shift: false))
        #expect(layout.keystroke(for: "\r\n") == KeyboardLayout.Keystroke(keyCode: 36, shift: false))
        #expect(layout.keystroke(for: "\t") == KeyboardLayout.Keystroke(keyCode: 48, shift: false))
    }

    @MainActor @Test func readsTheMacsLayout() throws {
        let layout = try #require(KeyboardLayout.current())
        #expect(layout.keystroke(for: " ") == KeyboardLayout.Keystroke(keyCode: 49, shift: false))
    }
}

struct DeviceResolverTests {
    let devices = [
        SimDevice(udid: "A", name: "iPhone 17 Pro", state: "Booted", deviceTypeIdentifier: "", runtime: "iOS 26.5"),
        SimDevice(udid: "B", name: "iPhone 17 Pro Max", state: "Booted", deviceTypeIdentifier: "", runtime: "iOS 26.5"),
        SimDevice(udid: "C", name: "iPad Air", state: "Shutdown", deviceTypeIdentifier: "", runtime: "iOS 26.5"),
    ]

    @Test func picksTheDeviceTheSimulatorShows() throws {
        #expect(try DeviceResolver.pick(nil, from: devices, current: "B").udid == "B")
        #expect(try DeviceResolver.pick(nil, from: devices, current: "C").udid == "A")
        #expect(try DeviceResolver.pick(nil, from: devices, current: nil).udid == "A")
        #expect(try DeviceResolver.pick("b", from: devices, current: "A").udid == "B")
    }

    @Test func explainsDevicesItCantUse() {
        for (udid, list) in [("C", devices), ("Z", devices), (nil, [devices[2]]), (nil, [])] as [(String?, [SimDevice])] {
            #expect(throws: AgentFailure.self) { try DeviceResolver.pick(udid, from: list, current: nil) }
            #expect((try? DeviceResolver.pick(udid, from: list, current: nil)) == nil)
        }
        do {
            _ = try DeviceResolver.pick("C", from: devices, current: nil)
        } catch {
            #expect((error as? AgentFailure)?.kind == .noDevice)
            #expect(error.localizedDescription.contains("isn't booted"))
        }
    }
}

struct DeviceWindowsTests {
    let front = SimulatorWindow(id: 1, frame: CGRect(x: 0, y: 30, width: 420, height: 900))
    let back = SimulatorWindow(id: 2, frame: CGRect(x: 500, y: 30, width: 460, height: 960))
    let pro = SimDevice(udid: "A", name: "iPhone 17 Pro", state: "Booted", deviceTypeIdentifier: "", runtime: "iOS 26.5")
    let max = SimDevice(udid: "B", name: "iPhone 17 Pro Max", state: "Booted", deviceTypeIdentifier: "", runtime: "iOS 26.5")

    var titles: [(title: String, frame: CGRect)] {
        [("iPhone 17 Pro Max", back.frame), ("iPhone 17 Pro", front.frame)]
    }

    @Test func usesTheFrontWindowForTheCurrentDevice() throws {
        #expect(try DeviceWindows.window(for: pro, in: [front, back], current: "A") { [] } == front)
    }

    @Test func findsOtherDevicesByTitle() throws {
        #expect(try DeviceWindows.window(for: max, in: [front, back], current: "A") { titles } == back)
        #expect(try DeviceWindows.window(for: pro, in: [back, front], current: "B") { titles } == front)
    }

    @Test func explainsAMissingWindow() {
        #expect(throws: AgentFailure.self) { try DeviceWindows.window(for: pro, in: [], current: "A") { [] } }
        #expect(throws: AgentFailure.self) { try DeviceWindows.window(for: max, in: [front], current: "A") { [] } }
    }

    @Test func readsTitlesWithAndWithoutTheOSVersion() {
        #expect(DeviceWindows.shows("iPhone 17 Pro", title: "iPhone 17 Pro"))
        #expect(DeviceWindows.shows("iPhone 17 Pro", title: "iPhone 17 Pro – iOS 26.5"))
        #expect(!DeviceWindows.shows("iPhone 17 Pro", title: "iPhone 17 Pro Max"))
    }
}

struct PreviewRouterTests {
    let token = "0123456789abcdef0123456789abcdef"
    var router: PreviewRouter { PreviewRouter(token: token, port: 8123) }

    func request(_ path: String, method: String = "GET", host: String? = "127.0.0.1:8123", origin: String? = nil, body: String = "") -> HTTPRequest {
        var headers: [String: String] = [:]
        headers["host"] = host
        headers["origin"] = origin
        return HTTPRequest(method: method, path: path, headers: headers, body: Data(body.utf8))
    }

    @Test func needsTheToken() {
        let notFound = PreviewRouter.Route.reject(status: 404, message: "Not found.")
        #expect(router.route(request("/")) == notFound)
        #expect(router.route(request("/frame.jpg")) == notFound)
        #expect(router.route(request("/0123456789abcdef0123456789abcdee/frame.jpg")) == notFound)
        #expect(router.route(request("/\(token.uppercased())/")) == notFound)
        #expect(router.route(request("/\(token)/../../etc/passwd")) == notFound)
        #expect(router.route(request("/\(token)/")) == .page)
        #expect(router.route(request("/\(token)")) == .page)
        #expect(router.route(request("/\(token)/frame.jpg?time=12")) == .frame)
    }

    @Test func onlyAnswersToLocalNames() {
        #expect(router.route(request("/\(token)/", host: "localhost:8123")) == .page)
        for host in ["evil.example:8123", "127.0.0.1:9999", "127.0.0.1", nil] as [String?] {
            guard case .reject(403, _) = router.route(request("/\(token)/", host: host)) else {
                Issue.record("\(host ?? "no host") was let in")
                continue
            }
        }
    }

    @Test func takesTapsAndSwipesFromThePageOnly() {
        let tap = #"{"x":0.25,"y":0.75}"#
        #expect(router.route(request("/\(token)/tap", method: "POST", body: tap)) == .tap(CGPoint(x: 0.25, y: 0.75)))
        #expect(router.route(request("/\(token)/tap", method: "POST", origin: "http://127.0.0.1:8123", body: tap)) == .tap(CGPoint(x: 0.25, y: 0.75)))
        guard case .reject(403, _) = router.route(request("/\(token)/tap", method: "POST", origin: "https://evil.example", body: tap)) else {
            Issue.record("a tap from another site was let in")
            return
        }
        guard case .reject(400, _) = router.route(request("/\(token)/tap", method: "POST", body: #"{"x":1.5,"y":0.5}"#)) else {
            Issue.record("a tap off the screen was accepted")
            return
        }
        guard case .reject(405, _) = router.route(request("/\(token)/tap", method: "GET")) else {
            Issue.record("a tap was accepted over GET")
            return
        }
        let swipe = #"{"x1":0.5,"y1":0.9,"x2":0.5,"y2":0.1,"duration":0.4}"#
        #expect(router.route(request("/\(token)/swipe", method: "POST", body: swipe))
            == .swipe(from: CGPoint(x: 0.5, y: 0.9), to: CGPoint(x: 0.5, y: 0.1), duration: 0.4))
    }

    @Test func tokensAreRandomAndComparedExactly() {
        let first = PreviewToken.make()
        let second = PreviewToken.make()
        #expect(first.count == 32)
        #expect(first.allSatisfy { $0.isHexDigit })
        #expect(first != second)
        #expect(PreviewToken.matches(Substring(first), first))
        #expect(!PreviewToken.matches(Substring(second), first))
        #expect(!PreviewToken.matches(first.dropLast(), first))
    }
}

struct HTTPRequestTests {
    @Test func waitsForTheWholeRequest() throws {
        #expect(HTTPRequest.parse(Data("GET / HTTP/1.1\r\nHost: 127.0.0.1".utf8)) == .incomplete)
        let body = #"{"x":0.5,"y":0.5}"#
        let head = "POST /token/tap HTTP/1.1\r\nHost: 127.0.0.1:1\r\nContent-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\n\r\n"
        #expect(HTTPRequest.parse(Data(head.utf8)) == .incomplete)
        guard case .complete(let request) = HTTPRequest.parse(Data((head + body).utf8)) else {
            Issue.record("the request wasn't read")
            return
        }
        #expect(request.method == "POST")
        #expect(request.path == "/token/tap")
        #expect(request.headers["host"] == "127.0.0.1:1")
        #expect(request.body == Data(body.utf8))
    }

    @Test func refusesNonsense() {
        #expect(HTTPRequest.parse(Data("hello\r\n\r\n".utf8)) == .invalid)
        #expect(HTTPRequest.parse(Data("GET / HTTP/1.1\r\nContent-Length: 999999\r\n\r\n".utf8)) == .invalid)
        #expect(HTTPRequest.parse(Data("GET / HTTP/1.1\r\nno colon here\r\n\r\n".utf8)) == .invalid)
        #expect(HTTPRequest.parse(Data(String(repeating: "x", count: HTTPRequest.headerLimit + 1).utf8)) == .invalid)
    }
}

/// Remembers the taps the preview passes on.
actor TapLog {
    private(set) var taps: [CGPoint] = []
    func add(_ point: CGPoint) { taps.append(point) }
}

struct BrowserPreviewTests {
    static let jpeg = Data([0xFF, 0xD8, 0xFF, 0xD9])

    static func actions(_ log: TapLog) -> PreviewActions {
        PreviewActions(frame: { jpeg }, tap: { await log.add($0) }, swipe: { _, _, _ in })
    }

    static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.connectionProxyDictionary = [:]
        return URLSession(configuration: configuration)
    }()

    @Test func servesThePageFramesAndTaps() async throws {
        let log = TapLog()
        let preview = try await BrowserPreview.start(port: nil, actions: Self.actions(log))
        defer { preview.stop() }
        #expect(preview.port > 0)
        #expect(preview.url.absoluteString.hasPrefix("http://127.0.0.1:\(preview.port)/\(preview.token)/"))

        let (page, pageResponse) = try await Self.session.data(from: preview.url)
        #expect((pageResponse as? HTTPURLResponse)?.statusCode == 200)
        #expect((pageResponse as? HTTPURLResponse)?.value(forHTTPHeaderField: "Referrer-Policy") == "no-referrer")
        #expect(String(decoding: page, as: UTF8.self).contains("frame.jpg"))

        let (frame, frameResponse) = try await Self.session.data(from: preview.url.appending(path: "frame.jpg"))
        #expect(frame == Self.jpeg)
        #expect((frameResponse as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Type") == "image/jpeg")

        let wrong = URL(string: "http://127.0.0.1:\(preview.port)/\(PreviewToken.make())/frame.jpg")!
        #expect((try await Self.session.data(from: wrong).1 as? HTTPURLResponse)?.statusCode == 404)

        var tap = URLRequest(url: preview.url.appending(path: "tap"))
        tap.httpMethod = "POST"
        tap.httpBody = Data(#"{"x":0.25,"y":0.75}"#.utf8)
        #expect((try await Self.session.data(for: tap).1 as? HTTPURLResponse)?.statusCode == 200)
        #expect(await log.taps == [CGPoint(x: 0.25, y: 0.75)])
    }

    @Test func reportsAFailedTapToThePage() async throws {
        let preview = try await BrowserPreview.start(port: nil, actions: PreviewActions(
            frame: { throw AgentFailure(.noDevice, "No simulator is booted.") },
            tap: { _ in throw AgentFailure.accessibilityNeeded },
            swipe: { _, _, _ in }
        ))
        defer { preview.stop() }
        var tap = URLRequest(url: preview.url.appending(path: "tap"))
        tap.httpMethod = "POST"
        tap.httpBody = Data(#"{"x":0.5,"y":0.5}"#.utf8)
        let (body, response) = try await Self.session.data(for: tap)
        #expect((response as? HTTPURLResponse)?.statusCode == 409)
        #expect(String(decoding: body, as: UTF8.self).contains("Accessibility"))
        let (frame, frameResponse) = try await Self.session.data(from: preview.url.appending(path: "frame.jpg"))
        #expect((frameResponse as? HTTPURLResponse)?.statusCode == 503)
        #expect(String(decoding: frame, as: UTF8.self).contains("No simulator is booted."))
    }

    @Test func refusesAPortThatIsTaken() async throws {
        let first = try await BrowserPreview.start(port: nil, actions: Self.actions(TapLog()))
        defer { first.stop() }
        await #expect(throws: AgentFailure.self) {
            try await BrowserPreview.start(port: Int(first.port), actions: Self.actions(TapLog()))
        }
    }
}

struct CommandLineInstallerTests {
    @Test func linksTheToolAndOnlyReplacesEarlierLinks() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let link = folder.appending(path: "bin/bettersim")
        try CommandLineInstaller.install(URL(filePath: "/bin/echo"), at: link)
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link.path(percentEncoded: false)) == "/bin/echo")
        try CommandLineInstaller.install(URL(filePath: "/bin/cat"), at: link)
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link.path(percentEncoded: false)) == "/bin/cat")

        try FileManager.default.removeItem(at: link)
        try Data("mine".utf8).write(to: link)
        #expect(throws: AgentFailure.self) { try CommandLineInstaller.install(URL(filePath: "/bin/echo"), at: link) }
        #expect(try String(contentsOf: link, encoding: .utf8) == "mine")
        #expect(CommandLineInstaller.manualCommand(for: URL(filePath: "/Applications/BetterSim.app/Contents/MacOS/BetterSim"))
            == "mkdir -p ~/.local/bin && ln -sf '/Applications/BetterSim.app/Contents/MacOS/BetterSim' ~/.local/bin/bettersim")
    }
}

/// Runs the simctl commands against the throwaway device named in BETTERSIM_CLI_UDID, which they change.
@Suite(.serialized)
struct LiveCommandLineTests {
    let udid = ProcessInfo.processInfo.environment["BETTERSIM_CLI_UDID"]

    func run(_ arguments: [String]) async -> (status: Int32, output: String, error: String) {
        let captured = CapturedOutput()
        let status = await CommandLineTool.run(arguments, output: captured.output, socket: AgentSocketTests.temporarySocket())
        return (status, captured.standardOutput, captured.standardError)
    }

    func folder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appending(path: "bettersim-cli-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    @Test func listsDevices() async throws {
        guard let udid else { return }
        let listed = await run(["--json", "devices"])
        #expect(listed.status == 0)
        struct Row: Decodable { let udid: String; let state: String }
        let rows = try AgentCoding.decode([Row].self, from: Data(listed.output.utf8))
        #expect(rows.first { $0.udid == udid }?.state == "Booted")
        #expect(await run(["devices"]).output.contains(udid))
    }

    @Test func takesPlainAndFramedScreenshots() async throws {
        guard let udid else { return }
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }

        let plainPath = folder.appending(path: "plain.png").path(percentEncoded: false)
        let plain = await run(["--udid", udid, "--json", "screenshot", "--out", plainPath])
        #expect(plain.status == 0, "\(plain.error)")
        let plainImage = try #require(ImageFile.load(URL(filePath: plainPath)))
        #expect((plainImage.width, plainImage.height) == (1206, 2622))
        #expect(plain.output.contains(#""framed":false"#))

        let framed = await run(["--udid", udid, "--json", "screenshot", "--frame", "--out", folder.path(percentEncoded: false)])
        #expect(framed.status == 0, "\(framed.error)")
        struct Saved: Decodable { let path: String; let width: Int; let height: Int; let framed: Bool }
        let saved = try AgentCoding.decode(Saved.self, from: Data(framed.output.utf8))
        #expect(saved.framed)
        #expect(saved.path.hasPrefix(folder.path(percentEncoded: false)))
        let name = try #require(try await SimDevice.all().first { $0.udid == udid }?.name)
        #expect(URL(filePath: saved.path).lastPathComponent.hasPrefix("\(name) "))
        #expect(saved.width > 1206 && saved.height > 2622)
        let image = try #require(ImageFile.load(URL(filePath: saved.path)))
        let pixels = try #require(FramerTests.rgba(image))
        #expect(pixels[3] == 0, "the corner outside the frame is transparent")
    }

    @Test func changesTheDevicesSettings() async throws {
        guard let udid else { return }
        #expect(await run(["--udid", udid, "appearance", "dark"]).status == 0)
        #expect(await DeviceSettings.appearance(udid) == "dark")
        #expect(await run(["--udid", udid, "appearance"]).output == "dark")
        #expect(await run(["--udid", udid, "appearance", "light"]).status == 0)
        #expect(await DeviceSettings.appearance(udid) == "light")

        #expect(await run(["--udid", udid, "statusbar", "clean"]).status == 0)
        #expect(await DeviceSettings.statusBarIsClean(udid))
        #expect(await run(["--udid", udid, "statusbar", "clear"]).status == 0)
        #expect(await !DeviceSettings.statusBarIsClean(udid))

        let located = await run(["--udid", udid, "location", "52.37,4.89"])
        #expect(located.status == 0)
        #expect(located.output.contains("52.370000,4.890000"))
        #expect(await run(["--udid", udid, "location", "clear"]).status == 0)

        let opened = await run(["--udid", udid, "--json", "open", "https://example.com"])
        #expect(opened.status == 0, "\(opened.output)")
    }

    @Test func launchesQuitsAndNotifiesApps() async throws {
        guard let udid else { return }
        let settings = "com.apple.Preferences"
        let launched = await run(["--udid", udid, "--json", "launch", settings])
        #expect(launched.status == 0)
        struct Launched: Decodable { let pid: Int }
        #expect(try AgentCoding.decode(Launched.self, from: Data(launched.output.utf8)).pid > 0)

        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let payload = folder.appending(path: "payload.apns")
        try Data(PushPayload.templates[0].json.utf8).write(to: payload)
        #expect(await run(["--udid", udid, "push", settings, payload.path(percentEncoded: false)]).status == 0)
        try Data("{ nope".utf8).write(to: payload)
        let broken = await run(["--udid", udid, "push", settings, payload.path(percentEncoded: false)])
        #expect(broken.status == 2)
        #expect(broken.error.contains("isn't valid JSON"))

        #expect(await run(["--udid", udid, "terminate", settings]).output.hasPrefix("Quit"))
        let again = await run(["--udid", udid, "terminate", settings])
        #expect(again.status == 0)
        #expect(again.output.contains("wasn't running"))

        let missing = await run(["--udid", udid, "launch", "com.example.not-installed"])
        #expect(missing.status == 1)
        #expect(missing.error == "bettersim: Simulator device failed to launch com.example.not-installed.")
    }

    @Test func recordsMP4AndGIF() async throws {
        guard let udid else { return }
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }

        #expect(await run(["--udid", udid, "record", "start"]).status == 0)
        let twice = await run(["--udid", udid, "record", "start"])
        #expect(twice.status == 1)
        #expect(twice.error.contains("already recording"))
        try await Task.sleep(for: .seconds(2))
        let movie = folder.appending(path: "clip.mp4")
        let stopped = await run(["--udid", udid, "record", "stop", "--out", movie.path(percentEncoded: false)])
        #expect(stopped.status == 0, "\(stopped.error)")
        let duration = try await AVURLAsset(url: movie).load(.duration).seconds
        #expect(duration > 1)

        #expect(await run(["--udid", udid, "record", "start", "--gif"]).status == 0)
        try await Task.sleep(for: .seconds(1.5))
        let gif = await run(["--json", "record", "stop"])
        #expect(gif.status == 0, "\(gif.error)")
        struct Saved: Decodable { let path: String }
        let saved = URL(filePath: try AgentCoding.decode(Saved.self, from: Data(gif.output.utf8)).path)
        defer { try? FileManager.default.removeItem(at: saved) }
        #expect(saved.pathExtension == "gif")
        #expect((CGImageSourceCreateWithURL(saved as CFURL, nil).map(CGImageSourceGetCount) ?? 0) > 5)

        let nothing = await run(["record", "stop"])
        #expect(nothing.status == 1)
        #expect(nothing.error.contains("Nothing is recording"))
    }

    @Test func capturesPreviewFrames() async throws {
        guard let udid else { return }
        let frame = try await PreviewFrames(udid: udid).frame()
        #expect(frame.prefix(2) == Data([0xFF, 0xD8]))
        let image = try #require(CGImageSourceCreateWithData(frame as CFData, nil).flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) })
        #expect((image.width, image.height) == (1206, 2622))
    }
}

@MainActor
struct AgentCommandsTests {
    @Test func refusesValuesTheToolWouldNeverSend() async {
        let commands = AgentCommands()
        let requests: [AgentAction] = [
            .swipe(fromX: 1, fromY: 2, toX: 3, toY: 4, duration: .nan),
            .swipe(fromX: 1, fromY: 2, toX: 3, toY: 4, duration: 1e9),
            .waitForLabel(label: "OK", timeout: -1),
            .preview(port: 70000),
        ]
        for action in requests {
            #expect(await commands.handle(AgentRequest(action: action)).failure?.kind == .usage, "\(action)")
        }
    }

    @Test func reportsItsStatus() async {
        let status = await AgentCommands().handle(AgentRequest(action: .ping)).status
        #expect(status?.accessibilityAllowed == AccessibilityScreenFinder.isTrusted)
        #expect(status?.previewURL == nil)
    }
}
