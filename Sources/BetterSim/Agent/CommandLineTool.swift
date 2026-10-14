import Foundation

struct CommandLineOutput: Sendable {
    var write: @Sendable (String) -> Void
    var error: @Sendable (String) -> Void

    static let standard = CommandLineOutput(
        write: { try? FileHandle.standardOutput.write(contentsOf: Data(($0 + "\n").utf8)) },
        error: { try? FileHandle.standardError.write(contentsOf: Data(($0 + "\n").utf8)) }
    )
}

/// `bettersim`, the command-line tool for people and AI agents. Commands that only need simctl run in this process;
/// the rest go to the running app over the agent socket.
enum CommandLineTool {
    /// The tool's arguments when the binary was started as `BetterSim cli …` or through a `bettersim` symlink, or nil
    /// when the app should start as usual.
    static func arguments(from argv: [String]) -> [String]? {
        guard let program = argv.first else { return nil }
        if URL(filePath: program).lastPathComponent == "bettersim" { return Array(argv.dropFirst()) }
        if argv.count > 1, argv[1] == "cli" { return Array(argv.dropFirst(2)) }
        return nil
    }

    static func runAndExit(_ arguments: [String]) -> Never {
        Task {
            exit(await run(arguments, output: .standard))
        }
        dispatchMain()
    }

    /// `socket` is where the running app listens, for the commands it handles.
    static func run(_ arguments: [String], output: CommandLineOutput, socket: String = AgentSocket.path) async -> Int32 {
        guard !arguments.isEmpty else {
            output.error(CLIInvocation.usageText)
            return 2
        }
        var json = arguments.contains("--json")
        do {
            let invocation = try CLIInvocation.parse(arguments)
            json = invocation.json
            let result = try await execute(invocation, socket: socket)
            output.write(json ? result.json : result.text)
            if !json, let note = result.note { output.error(note) }
            return result.status
        } catch {
            let failure = error as? AgentFailure ?? AgentFailure(.failed, Readable.message(error))
            if json {
                output.write(AgentCoding.string(Outcome(ok: false, message: failure.message, kind: failure.kind.rawValue)))
            } else {
                output.error("bettersim: \(failure.message)")
                if failure.kind == .usage { output.error("Run bettersim help to see every command.") }
            }
            return failure.exitCode
        }
    }

    private static func execute(_ invocation: CLIInvocation, socket: String) async throws -> CommandResult {
        let udid = invocation.udid
        func forward(_ action: AgentAction, timeout: TimeInterval = 30) async throws -> AgentReply {
            let reply = try await AgentClient.send(AgentRequest(action: action, udid: udid), to: socket, timeout: timeout)
            if let failure = reply.failure { throw failure }
            return reply
        }
        switch invocation.command {
        case .help:
            return CommandResult(text: CLIInvocation.usageText, json: AgentCoding.string(["usage": CLIInvocation.usageText]))
        case .devices:
            return try await devices()
        case .screenshot(let framed, let output):
            return try await screenshot(udid, framed: framed, output: output)
        case .recordStart(let gif):
            let device = try await DeviceResolver.resolve(udid)
            try await DetachedRecording.start(device, gif: gif)
            return .done("Recording \(device.name). Run bettersim record stop to save it.", Outcome(udid: device.udid))
        case .recordStop(let gif, let output):
            let file = try await DetachedRecording.stop(udid: udid, gif: gif, output: output)
            return .done("Saved the recording to \(file.path(percentEncoded: false)).", Outcome(path: file.path(percentEncoded: false)))
        case .open(let link):
            let device = try await DeviceResolver.resolve(udid)
            try await simctl { try await AppActions.open(link, on: device.udid) }
            return .done("Opened \(link) on \(device.name).", Outcome(udid: device.udid))
        case .push(let bundleID, let file):
            let device = try await DeviceResolver.resolve(udid)
            let payload = try pushPayload(file)
            try await simctl { try await AppActions.push(payload, to: bundleID, on: device.udid) }
            return .done("Sent the notification to \(bundleID) on \(device.name).", Outcome(udid: device.udid))
        case .launch(let bundleID):
            let device = try await DeviceResolver.resolve(udid)
            let reply = try await simctl { try await Simctl.output(["launch", device.udid, bundleID]) }
            let pid = reply.split(separator: ":").last.flatMap { Int($0.trimmingCharacters(in: .whitespaces)) }
            return .done("Launched \(bundleID) on \(device.name).", Outcome(udid: device.udid, pid: pid))
        case .terminate(let bundleID):
            let device = try await DeviceResolver.resolve(udid)
            do {
                try await Simctl.run(["terminate", device.udid, bundleID])
            } catch let error as SimctlError where error.message.contains("found nothing to terminate") {
                return .done("\(bundleID) wasn't running on \(device.name).", Outcome(udid: device.udid))
            } catch let error as SimctlError {
                throw AgentFailure(.failed, Readable.simctl(error))
            }
            return .done("Quit \(bundleID) on \(device.name).", Outcome(udid: device.udid))
        case .appearance(let style):
            let device = try await DeviceResolver.resolve(udid)
            guard let style else {
                let current = await DeviceSettings.appearance(device.udid) ?? "unknown"
                return CommandResult(text: current, json: AgentCoding.string(Outcome(udid: device.udid, appearance: current)))
            }
            try await simctl { try await DeviceSettings.setAppearance(style, on: device.udid) }
            return .done("Switched \(device.name) to \(style) mode.", Outcome(udid: device.udid, appearance: style))
        case .statusBar(let clean):
            let device = try await DeviceResolver.resolve(udid)
            try await simctl { try await DeviceSettings.setCleanStatusBar(clean, on: device.udid) }
            let message = clean ? "Set a clean 9:41 status bar on \(device.name)." : "Put the real status bar back on \(device.name)."
            return .done(message, Outcome(udid: device.udid))
        case .location(let coordinate):
            let device = try await DeviceResolver.resolve(udid)
            guard let coordinate else {
                try await simctl { try await DeviceSettings.clearLocation(on: device.udid) }
                return .done("Cleared the simulated location on \(device.name).", Outcome(udid: device.udid))
            }
            try await simctl { try await DeviceSettings.setLocation(coordinate, on: device.udid) }
            return .done("Set \(device.name)'s location to \(coordinate.argument).", Outcome(udid: device.udid))
        case .doctor:
            return await Doctor.run(udid: udid, socket: socket)
        case .ui(let includeAll):
            let elements = try await forward(.listElements(includeAll: includeAll), timeout: 60).elements ?? []
            let list = elements.isEmpty ? "[]" : "[\n" + elements.map { "  " + AgentCoding.string($0) }.joined(separator: ",\n") + "\n]"
            let note = elements.isEmpty ? "The Simulator reported nothing on screen. Try again once the app has finished loading." : nil
            return CommandResult(text: list, json: list, note: note)
        case .tap(let x, let y):
            return .forwarded(try await forward(.tap(x: x, y: y)))
        case .tapLabel(let label):
            return .forwarded(try await forward(.tapLabel(label: label), timeout: 60))
        case .swipe(let fromX, let fromY, let toX, let toY, let duration):
            return .forwarded(try await forward(.swipe(fromX: fromX, fromY: fromY, toX: toX, toY: toY, duration: duration), timeout: 30 + duration))
        case .type(let text):
            return .forwarded(try await forward(.type(text: text), timeout: 30 + Double(text.count) * 0.05))
        case .wait(let label, let timeout):
            return .forwarded(try await forward(.waitForLabel(label: label, timeout: timeout), timeout: timeout + 60))
        case .preview(let port):
            let reply = try await forward(.preview(port: port), timeout: 15)
            let url = reply.url ?? ""
            return CommandResult(text: url, json: AgentCoding.string(Outcome(url: url)))
        case .camera(let on, let bundleID, let source):
            return .forwarded(try await forward(.camera(on: on, bundleID: bundleID, source: source), timeout: 60))
        }
    }

    private static func devices() async throws -> CommandResult {
        let devices = try await simctl { try await SimDevice.all() }
        let chosen = DeviceResolver.defaultDevice(in: devices, current: SimulatorWindows.currentDeviceUDID)
        struct Row: Encodable {
            let udid: String
            let name: String
            let runtime: String
            let state: String
            let current: Bool
        }
        let rows = devices.map { Row(udid: $0.udid, name: $0.name, runtime: $0.runtime, state: $0.state, current: $0.udid == chosen?.udid) }
        let nameWidth = rows.map(\.name.count).max() ?? 0
        let runtimeWidth = rows.map(\.runtime.count).max() ?? 0
        let stateWidth = rows.map(\.state.count).max() ?? 0
        let text = rows.map { row in
            [
                row.current ? "*" : " ",
                row.name.padding(toLength: nameWidth, withPad: " ", startingAt: 0),
                row.runtime.padding(toLength: runtimeWidth, withPad: " ", startingAt: 0),
                row.state.padding(toLength: stateWidth, withPad: " ", startingAt: 0),
                row.udid,
            ].joined(separator: "  ")
        }
        let json = rows.isEmpty ? "[]" : "[\n" + rows.map { "  " + AgentCoding.string($0) }.joined(separator: ",\n") + "\n]"
        return CommandResult(text: text.isEmpty ? "There are no simulators. Add one in Xcode's Devices and Simulators window." : text.joined(separator: "\n"), json: json)
    }

    private static func screenshot(_ udid: String?, framed: Bool, output: String?) async throws -> CommandResult {
        let device = try await DeviceResolver.resolve(udid)
        let profile = framed ? await DeviceProfiles.shared.profile(for: device) : nil
        let scratch = FileManager.default.temporaryDirectory.appending(path: "BetterSim-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let shot = try await simctl {
            try await Screenshotter.capture(device, profile: profile, framed: framed, folder: scratch)
        }
        let destination = try OutputPaths.destination(output, for: device, extension: "png")
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: shot, to: destination)
        let image = ImageFile.load(destination)
        let width = image?.width ?? 0
        let height = image?.height ?? 0
        let isFramed = profile.map { CGFloat(width * height) > $0.screenPixels.width * $0.screenPixels.height } ?? false
        let path = destination.path(percentEncoded: false)
        var message = "Saved a screenshot of \(device.name) to \(path)."
        if framed, !isFramed { message += " BetterSim has no frame for this device, so it isn't framed." }
        return .done(message, Outcome(udid: device.udid, path: path, width: width, height: height, framed: isFramed))
    }

    private static func pushPayload(_ file: String) throws -> Data {
        let data: Data
        if file == "-" {
            data = FileHandle.standardInput.readDataToEndOfFile()
        } else {
            guard let contents = try? Data(contentsOf: OutputPaths.resolve(file)) else {
                throw AgentFailure(.usage, "BetterSim couldn't read \(file).")
            }
            data = contents
        }
        switch PushPayload.validate(String(decoding: data, as: UTF8.self)) {
        case .success(let payload): return payload
        case .failure(let problem): throw AgentFailure(.usage, problem.localizedDescription)
        }
    }

    /// Turns simctl's long errors into one readable line.
    private static func simctl<Value>(_ work: () async throws -> Value) async throws -> Value {
        do {
            return try await work()
        } catch let error as SimctlError {
            throw AgentFailure(.failed, Readable.simctl(error))
        }
    }
}

struct CommandResult {
    var text: String
    var json: String
    /// Extra advice for people, written to standard error so it never mixes with the output.
    var note: String?
    var status: Int32 = 0

    static func done(_ message: String, _ outcome: Outcome) -> CommandResult {
        var outcome = outcome
        outcome.message = message
        return CommandResult(text: message, json: AgentCoding.string(outcome))
    }

    static func forwarded(_ reply: AgentReply) -> CommandResult {
        let message = reply.message ?? "Done."
        return CommandResult(text: message, json: AgentCoding.string(Outcome(message: message, element: reply.element)))
    }
}

/// The JSON the tool prints for anything that isn't a list. Fields that don't apply are left out.
struct Outcome: Encodable {
    var ok = true
    var message: String?
    var kind: String?
    var udid: String?
    var path: String?
    var width: Int?
    var height: Int?
    var framed: Bool?
    var pid: Int?
    var appearance: String?
    var url: String?
    var element: DeviceElement?
}

enum OutputPaths {
    /// Where files go without --out. A temporary folder keeps agents' captures off the Desktop.
    static var folder: URL {
        FileManager.default.temporaryDirectory.appending(path: "BetterSim", directoryHint: .isDirectory)
    }

    /// `output` can be a file, or a folder to put a dated file in: one that exists, or any path ending in a slash.
    static func destination(_ output: String?, for device: SimDevice, extension ext: String) throws -> URL {
        let url = output.map(resolve) ?? folder
        var isFolder: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: url.path(percentEncoded: false), isDirectory: &isFolder)
        if output == nil || output?.hasSuffix("/") == true || (exists && isFolder.boolValue) {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            return CaptureFiles.url(for: device, in: url, extension: ext)
        }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        return url
    }

    static func resolve(_ path: String) -> URL {
        URL(filePath: (path as NSString).expandingTildeInPath, relativeTo: .currentDirectory()).absoluteURL.standardizedFileURL
    }
}

enum Readable {
    static func message(_ error: Error) -> String {
        (error as? SimctlError).map(simctl) ?? error.localizedDescription
    }

    /// simctl's errors open with a generic line and then repeat themselves; the first specific line says what happened.
    static func simctl(_ error: SimctlError) -> String {
        let lines = error.message.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        return lines.first { !$0.hasPrefix("An error was encountered processing the command") && !$0.hasPrefix("Underlying error") }
            ?? error.localizedDescription
    }
}

/// Checks everything the tool depends on and says how to fix what's missing.
enum Doctor {
    struct Check: Encodable {
        let name: String
        let ok: Bool
        let detail: String
    }

    static func run(udid: String?, socket: String) async -> CommandResult {
        var checks: [Check] = []
        do {
            let devices = try await SimDevice.all()
            checks.append(Check(name: "Simulator tools", ok: true, detail: Simctl.executable.path(percentEncoded: false)))
            do {
                let device = try DeviceResolver.pick(udid, from: devices, current: SimulatorWindows.currentDeviceUDID)
                checks.append(Check(name: "Device", ok: true, detail: "\(device.name), \(device.runtime) (\(device.udid))"))
            } catch {
                checks.append(Check(name: "Device", ok: false, detail: error.localizedDescription))
            }
        } catch {
            checks.append(Check(name: "Simulator tools", ok: false, detail: "simctl didn't work. Install Xcode, then run sudo xcode-select --switch /Applications/Xcode.app."))
        }
        let windows = SimulatorWindows.windows().count
        checks.append(Check(
            name: "Simulator window",
            ok: windows > 0,
            detail: windows > 0 ? "\(windows) visible" : "None visible. Open the Simulator so ui, tap, swipe, type and wait can see the device."
        ))
        let status = try? await AgentClient.send(AgentRequest(action: .ping), to: socket, timeout: 5).status
        checks.append(Check(
            name: "BetterSim app",
            ok: status != nil,
            detail: status.map { "Open, version \($0.version)" } ?? "Not open. Open BetterSim so ui, tap, swipe, type, wait and preview work."
        ))
        if let status {
            checks.append(Check(
                name: "Accessibility",
                ok: status.accessibilityAllowed,
                detail: status.accessibilityAllowed ? "Allowed" : "Not allowed. Allow BetterSim in System Settings > Privacy & Security > Accessibility."
            ))
        }
        let installed = commandOnPath("bettersim")
        checks.append(Check(
            name: "Command on PATH",
            ok: installed != nil,
            detail: installed ?? "Not found. Choose Install Command-Line Tool… in BetterSim's menu, and make sure ~/.local/bin is on your PATH."
        ))
        struct Report: Encodable {
            let ok: Bool
            let checks: [Check]
        }
        let ok = checks.allSatisfy(\.ok)
        return CommandResult(
            text: checks.map { "\($0.ok ? "✓" : "✗") \($0.name): \($0.detail)" }.joined(separator: "\n"),
            json: AgentCoding.string(Report(ok: ok, checks: checks)),
            status: ok ? 0 : 1
        )
    }

    private static func commandOnPath(_ name: String) -> String? {
        let folders = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":")
        return folders.lazy
            .map { URL(filePath: String($0)).appending(path: name).path(percentEncoded: false) }
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }
}
