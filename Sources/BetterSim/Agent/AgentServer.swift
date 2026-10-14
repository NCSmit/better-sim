import AppKit
import os

private let log = Logger(subsystem: "local.bettersim", category: "agent")

/// Answers the command-line tool on the agent socket. Commands that need the Simulator window or Accessibility run
/// in the app, because the Accessibility grant belongs to the app and not to the terminal running the tool.
final class AgentServer: Sendable {
    let path: String
    private let socket: UnixSocketServer

    init(path: String = AgentSocket.path, handler: @escaping @Sendable (AgentRequest) async -> AgentReply) throws {
        self.path = path
        socket = try UnixSocketServer(path: path) { data in
            let reply: AgentReply
            if let request = try? AgentCoding.decode(AgentRequest.self, from: data) {
                reply = await handler(request)
            } else {
                reply = AgentReply(failure: AgentFailure(.usage, "BetterSim couldn't read that request. Use the bettersim tool that came with this copy of BetterSim."))
            }
            return (try? AgentCoding.encode(reply)) ?? Data()
        }
        log.info("answering agents at \(path, privacy: .public)")
    }

    /// Starts answering on the shared socket, or logs why it can't, so the rest of the app carries on either way.
    static func start(commands: AgentCommands) -> AgentServer? {
        do {
            return try AgentServer { request in await commands.handle(request) }
        } catch {
            log.error("could not answer agents: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    func stop() {
        socket.stop()
    }
}

enum AgentClient {
    static func send(_ request: AgentRequest, to path: String = AgentSocket.path, timeout: TimeInterval) async throws -> AgentReply {
        let reply = try await UnixSocket.exchange(try AgentCoding.encode(request), path: path, timeout: timeout)
        guard let decoded = try? AgentCoding.decode(AgentReply.self, from: reply) else {
            throw AgentFailure(.failed, "BetterSim answered in a way this tool doesn't understand. Use the bettersim tool that came with the running BetterSim.")
        }
        return decoded
    }
}

/// Runs the requests that reach the app.
@MainActor
final class AgentCommands {
    private let knownScreen: (CGRect) -> CGRect?
    private let input = InputQueue()
    private var preview: (server: BrowserPreview, udid: String?)?

    /// `knownScreen` returns the device screen the side panel tracks for a Simulator window frame, when it tracks
    /// that window, so the screen isn't looked up twice.
    init(knownScreen: @escaping (CGRect) -> CGRect? = { _ in nil }) {
        self.knownScreen = knownScreen
    }

    func handle(_ request: AgentRequest) async -> AgentReply {
        do {
            return try await perform(request.action, udid: request.udid)
        } catch let failure as AgentFailure {
            return AgentReply(failure: failure)
        } catch {
            return AgentReply(failure: AgentFailure(.failed, error.localizedDescription))
        }
    }

    private func perform(_ action: AgentAction, udid: String?) async throws -> AgentReply {
        switch action {
        case .ping:
            return AgentReply(status: status())
        case .listElements(let includeAll):
            let elements = try await elements(on: try await target(udid))
            return AgentReply(elements: includeAll ? elements : DeviceElements.meaningful(elements))
        case .tap(let x, let y):
            let target = try await target(udid)
            let point = CGPoint(x: x, y: y)
            try await input.run { try await DeviceInput.tap(point, on: target) }
            return AgentReply(message: "Tapped \(Format.point(point)) on \(target.device.name).")
        case .tapLabel(let label):
            let target = try await target(udid)
            guard let element = DeviceElements.match(label, in: try await elements(on: target)) else {
                throw AgentFailure(.notFound, "Nothing on \(target.device.name)'s screen is labelled “\(label)”. Run bettersim ui to see what is.")
            }
            let point = element.tapPoint(within: target.screen.size)
            try await input.run { try await DeviceInput.tap(point, on: target) }
            return AgentReply(message: "Tapped “\(element.label ?? element.value ?? label)” at \(Format.point(point)) on \(target.device.name).", element: element)
        case .swipe(let fromX, let fromY, let toX, let toY, let duration):
            guard (0.05...10).contains(duration) else { throw AgentFailure(.usage, "A swipe takes from 0.05 to 10 seconds.") }
            let target = try await target(udid)
            let start = CGPoint(x: fromX, y: fromY)
            let end = CGPoint(x: toX, y: toY)
            try await input.run { try await DeviceInput.swipe(from: start, to: end, duration: duration, on: target) }
            return AgentReply(message: "Swiped from \(Format.point(start)) to \(Format.point(end)) on \(target.device.name).")
        case .type(let text):
            let target = try await target(udid)
            try await input.run { try await DeviceInput.type(text, on: target) }
            return AgentReply(message: "Typed \(text.count) character\(text.count == 1 ? "" : "s") on \(target.device.name).")
        case .waitForLabel(let label, let timeout):
            guard (0.1...600).contains(timeout) else { throw AgentFailure(.usage, "Waiting takes from 0.1 to 600 seconds.") }
            return try await wait(for: label, timeout: timeout, udid: udid)
        case .preview(let port):
            if let port, !(1...65535).contains(port) { throw AgentFailure(.usage, "A port is a number from 1 to 65535.") }
            return AgentReply(url: try await startPreview(port: port, udid: udid).absoluteString)
        }
    }

    private func status() -> AgentStatus {
        AgentStatus(
            version: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev",
            accessibilityAllowed: AccessibilityScreenFinder.isTrusted,
            simulatorWindows: SimulatorWindows.windows().count,
            currentDevice: SimulatorWindows.currentDeviceUDID,
            previewURL: preview?.server.url.absoluteString
        )
    }

    private func target(_ udid: String?) async throws -> DeviceTarget {
        try await DeviceTarget.locate(udid, knownScreen: knownScreen)
    }

    private func elements(on target: DeviceTarget) async throws -> [DeviceElement] {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(with: Result {
                    try DeviceElements.read(simulator: target.simulator, window: target.window.frame, screen: target.screen)
                })
            }
        }
    }

    private func wait(for label: String, timeout: Double, udid: String?) async throws -> AgentReply {
        try DeviceTarget.requireAccess()
        let device = try await DeviceResolver.resolve(udid)
        let started = Date()
        while true {
            let target = try await DeviceTarget.locate(device: device, knownScreen: knownScreen)
            if let element = DeviceElements.match(label, in: try await elements(on: target)) {
                let waited = Date().timeIntervalSince(started)
                return AgentReply(message: "Found “\(element.label ?? element.value ?? label)” after \(Format.number(waited)) seconds.", element: element)
            }
            guard Date().timeIntervalSince(started) < timeout else {
                throw AgentFailure(.timeout, "Nothing labelled “\(label)” appeared on \(device.name) within \(Format.number(timeout)) seconds.")
            }
            try await Task.sleep(for: .milliseconds(400))
        }
    }

    private func startPreview(port: Int?, udid: String?) async throws -> URL {
        if let preview, preview.udid == udid, port == nil || port == Int(preview.server.port) {
            return preview.server.url
        }
        preview?.server.stop()
        preview = nil
        let frames = PreviewFrames(udid: udid)
        let server = try await BrowserPreview.start(port: port, actions: PreviewActions(
            frame: { try await frames.frame() },
            tap: { [weak self] fraction in try await self?.tap(fraction: fraction, udid: udid) },
            swipe: { [weak self] from, to, duration in try await self?.swipe(from: from, to: to, duration: duration, udid: udid) }
        ))
        preview = (server, udid)
        log.info("browser preview on port \(server.port)")
        return server.url
    }

    private func tap(fraction: CGPoint, udid: String?) async throws {
        let target = try await target(udid)
        let point = target.screen.devicePoint(fraction: fraction)
        try await input.run { try await DeviceInput.tap(point, on: target) }
    }

    private func swipe(from start: CGPoint, to end: CGPoint, duration: Double, udid: String?) async throws {
        let target = try await target(udid)
        let from = target.screen.devicePoint(fraction: start)
        let to = target.screen.devicePoint(fraction: end)
        try await input.run { try await DeviceInput.swipe(from: from, to: to, duration: duration, on: target) }
    }
}

/// Runs taps, swipes and typing one at a time, so requests from two agents can't interleave their events.
@MainActor
private final class InputQueue {
    private var last: Task<Void, Never>?

    func run(_ work: @escaping @Sendable @MainActor () async throws -> Void) async throws {
        let previous = last
        let task = Task { @MainActor in
            await previous?.value
            try await work()
        }
        last = Task { @MainActor in _ = try? await task.value }
        try await task.value
    }
}
