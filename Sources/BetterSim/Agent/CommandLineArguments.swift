import Foundation

/// What someone asked the `bettersim` tool to do.
enum CLICommand: Equatable {
    case help
    case devices
    case screenshot(framed: Bool, output: String?)
    case recordStart(gif: Bool)
    case recordStop(gif: Bool, output: String?)
    case open(String)
    case push(bundleID: String, file: String)
    case launch(String)
    case terminate(String)
    case appearance(String?)
    case statusBar(clean: Bool)
    case location(Coordinate?)
    case doctor
    case ui(includeAll: Bool)
    case tap(x: Double, y: Double)
    case tapLabel(String)
    case swipe(fromX: Double, fromY: Double, toX: Double, toY: Double, duration: Double)
    case type(String)
    case wait(label: String, timeout: Double)
    case preview(port: Int?)
}

struct CLIInvocation: Equatable {
    var command: CLICommand
    var udid: String?
    var json = false

    /// Whether each option takes a value.
    private static let options: [String: Bool] = [
        "udid": true, "json": false, "help": false, "frame": false, "out": true, "gif": false, "all": false,
        "label": true, "duration": true, "timeout": true, "port": true,
    ]

    private static let globalOptions: Set<String> = ["udid", "json", "help"]

    private static let commandOptions: [String: Set<String>] = [
        "screenshot": ["frame", "out"], "record": ["gif", "out"], "ui": ["all"], "tap": ["label"],
        "swipe": ["duration"], "wait": ["label", "timeout"], "preview": ["port"],
    ]

    static func parse(_ arguments: [String]) throws -> CLIInvocation {
        var words: [String] = []
        var values: [String: String] = [:]
        var remaining = arguments[...]
        var onlyWords = false
        while let token = remaining.popFirst() {
            if onlyWords || !isOption(token) {
                words.append(token)
            } else if token == "--" {
                onlyWords = true
            } else if token == "-h" {
                values["help"] = ""
            } else {
                guard token.hasPrefix("--") else { throw usage("There's no option called \(token).") }
                var name = String(token.dropFirst(2))
                var value: String?
                if let equals = name.firstIndex(of: "=") {
                    value = String(name[name.index(after: equals)...])
                    name = String(name[..<equals])
                }
                guard let takesValue = options[name] else { throw usage("There's no option called --\(name).") }
                if takesValue {
                    guard let given = value ?? remaining.popFirst(), !given.isEmpty else { throw usage("--\(name) needs a value.") }
                    values[name] = given
                } else {
                    guard value == nil else { throw usage("--\(name) doesn't take a value.") }
                    values[name] = ""
                }
            }
        }
        let udid = values["udid"]
        let json = values["json"] != nil
        if values["help"] != nil || words.first == "help" {
            return CLIInvocation(command: .help, udid: udid, json: json)
        }
        guard !words.isEmpty else { throw usage("Say what to do, for example bettersim screenshot.") }
        let name = words.removeFirst()
        guard commands.contains(name) else { throw usage("There's no command called \(name).") }
        if let extra = Set(values.keys).subtracting(globalOptions).subtracting(commandOptions[name] ?? []).sorted().first {
            throw usage("\(name) doesn't take --\(extra).")
        }
        return CLIInvocation(command: try command(name, words, values), udid: udid, json: json)
    }

    private static let commands: Set<String> = [
        "devices", "screenshot", "record", "open", "push", "launch", "terminate", "appearance", "statusbar", "location",
        "doctor", "ui", "tap", "swipe", "type", "wait", "preview",
    ]

    private static func command(_ name: String, _ words: [String], _ values: [String: String]) throws -> CLICommand {
        switch name {
        case "devices":
            try expect(words, count: 0, "devices")
            return .devices
        case "screenshot":
            try expect(words, count: 0, "screenshot [--frame] [--out PATH]")
            return .screenshot(framed: values["frame"] != nil, output: values["out"])
        case "record":
            switch words {
            case ["start"]:
                guard values["out"] == nil else { throw usage("--out goes with record stop.") }
                return .recordStart(gif: values["gif"] != nil)
            case ["stop"]:
                return .recordStop(gif: values["gif"] != nil, output: values["out"])
            default:
                throw usage("Say record start or record stop.")
            }
        case "open":
            try expect(words, count: 1, "open URL")
            return .open(words[0])
        case "push":
            try expect(words, count: 2, "push BUNDLE_ID FILE")
            return .push(bundleID: words[0], file: words[1])
        case "launch", "terminate":
            try expect(words, count: 1, "\(name) BUNDLE_ID")
            return name == "launch" ? .launch(words[0]) : .terminate(words[0])
        case "appearance":
            guard words.count <= 1, words.allSatisfy({ ["light", "dark"].contains($0) }) else {
                throw usage("Say appearance light or appearance dark, or just appearance to see which is on.")
            }
            return .appearance(words.first)
        case "statusbar":
            guard words.count == 1, ["clean", "clear"].contains(words[0]) else {
                throw usage("Say statusbar clean for a 9:41 status bar, or statusbar clear for the real one.")
            }
            return .statusBar(clean: words[0] == "clean")
        case "location":
            let text = words.joined(separator: " ")
            if text == "clear" { return .location(nil) }
            guard let coordinate = Coordinate(text) else {
                throw usage("Give a location as LATITUDE,LONGITUDE, for example 52.37,4.89, or say location clear.")
            }
            return .location(coordinate)
        case "doctor":
            try expect(words, count: 0, "doctor")
            return .doctor
        case "ui":
            try expect(words, count: 0, "ui [--all]")
            return .ui(includeAll: values["all"] != nil)
        case "tap":
            if let label = values["label"] {
                guard words.isEmpty else { throw usage("Give tap either a point or --label, not both.") }
                return .tapLabel(label)
            }
            let point = try numbers(words, count: 2, "tap X Y, or tap --label TEXT")
            return .tap(x: point[0], y: point[1])
        case "swipe":
            let points = try numbers(words, count: 4, "swipe X1 Y1 X2 Y2 [--duration SECONDS]")
            let duration = try number(values["duration"], option: "duration", default: 0.3, range: 0.05...10)
            return .swipe(fromX: points[0], fromY: points[1], toX: points[2], toY: points[3], duration: duration)
        case "type":
            guard !words.isEmpty else { throw usage("Say what to type, for example bettersim type \"hello\".") }
            return .type(words.joined(separator: " "))
        case "wait":
            guard let label = values["label"] else { throw usage("Say what to wait for with --label TEXT.") }
            try expect(words, count: 0, "wait --label TEXT [--timeout SECONDS]")
            return .wait(label: label, timeout: try number(values["timeout"], option: "timeout", default: 10, range: 0.1...600))
        case "preview":
            try expect(words, count: 0, "preview [--port N]")
            guard let text = values["port"] else { return .preview(port: nil) }
            guard let port = Int(text), (1...65535).contains(port) else { throw usage("--port needs a number from 1 to 65535.") }
            return .preview(port: port)
        default:
            throw usage("There's no command called \(name).")
        }
    }

    /// Words starting with a dash are options, apart from a lone dash, which means standard input, and negative numbers.
    private static func isOption(_ token: String) -> Bool {
        guard token.hasPrefix("-"), token != "-", let next = token.dropFirst().first else { return false }
        return !(next.isNumber || next == ".")
    }

    private static func expect(_ words: [String], count: Int, _ form: String) throws {
        guard words.count == count else { throw usage("Use it like this: bettersim \(form)") }
    }

    private static func numbers(_ words: [String], count: Int, _ form: String) throws -> [Double] {
        let values = words.compactMap { Double($0) }.filter(\.isFinite)
        guard words.count == count, values.count == count else { throw usage("Use it like this: bettersim \(form)") }
        return values
    }

    private static func number(_ text: String?, option: String, default fallback: Double, range: ClosedRange<Double>) throws -> Double {
        guard let text else { return fallback }
        guard let value = Double(text), range.contains(value) else {
            throw usage("--\(option) needs a number of seconds from \(Format.number(range.lowerBound)) to \(Format.number(range.upperBound)).")
        }
        return value
    }

    private static func usage(_ message: String) -> AgentFailure {
        AgentFailure(.usage, message)
    }

    static let usageText = """
    Usage: bettersim [--udid UDID] [--json] COMMAND [ARGUMENTS]

    Simulator commands. These only need Xcode:
      devices                             List the simulators, booted ones first.
      screenshot [--frame] [--out PATH]   Save a PNG, in the device's frame with --frame.
      record start [--gif]                Start recording the screen.
      record stop [--gif] [--out PATH]    Stop recording and save an MP4, or a GIF with --gif.
      open URL                            Open a URL or deep link.
      push BUNDLE_ID FILE                 Send a push notification. FILE can be - for standard input.
      launch BUNDLE_ID                    Launch an app.
      terminate BUNDLE_ID                 Quit an app.
      appearance [light|dark]             Switch light or dark mode, or show which is on.
      statusbar clean|clear               Show a clean 9:41 status bar, or the real one.
      location LAT,LON | clear            Set or clear the simulated location.
      doctor                              Check that everything the tool needs is ready.

    Screen commands. These need BetterSim to be open and allowed to use Accessibility:
      ui [--all]                          List what's on screen as JSON, with frames in device points.
      tap X Y                             Tap a point, in device points from the top-left corner.
      tap --label TEXT                    Tap the element with that label.
      swipe X1 Y1 X2 Y2 [--duration S]    Swipe from one point to another. It takes 0.3 seconds unless you say.
      type TEXT                           Type into the focused field.
      wait --label TEXT [--timeout S]     Wait for an element with that label. It gives up after 10 seconds unless you say.
      preview [--port N]                  Show the screen in a web browser, and print the page's private address.

    Options:
      --udid UDID   Use this simulator. Otherwise it's the one the Simulator app shows.
      --json        Print the result as JSON. ui always prints JSON.

    Exit codes: 0 done, 1 failed, 2 wrong arguments, 3 BetterSim isn't open, 4 Accessibility isn't allowed,
    5 no booted simulator or no Simulator window, 6 the element wasn't found in time.
    """
}
