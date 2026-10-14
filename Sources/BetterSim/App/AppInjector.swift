import Foundation

/// The libraries BetterSim builds for the Simulator and loads into apps it relaunches.
enum InjectedLibrary {
    static func url(named name: String) -> URL? {
        if let url = Bundle.main.url(forResource: name, withExtension: "dylib") { return url }
        // `swift run` has no app bundle, so look for the copy build.sh leaves in build/ next to the package.
        var folder = Bundle.main.bundleURL
        for _ in 0..<5 {
            let candidate = folder.appending(path: "build/\(name).dylib")
            if FileManager.default.fileExists(atPath: candidate.path(percentEncoded: false)) { return candidate }
            folder.deleteLastPathComponent()
        }
        return nil
    }
}

/// Relaunches simulator apps with BetterSim's libraries loaded into them: the network monitor, the camera, or both.
/// An app keeps them until it quits or is launched again some other way.
@MainActor
final class AppInjector {
    struct Features: OptionSet, Hashable, Sendable {
        let rawValue: Int
        static let network = Features(rawValue: 1)
        static let camera = Features(rawValue: 2)
    }

    struct Libraries {
        var network = InjectedLibrary.url(named: NetworkMonitor.libraryName)
        var camera = InjectedLibrary.url(named: SimulatorCamera.libraryName)
    }

    let network: NetworkMonitor
    let camera: SimulatorCamera
    private var launched: [String: (process: pid_t, features: Features)] = [:]

    init(network: NetworkMonitor, camera: SimulatorCamera) {
        self.network = network
        self.camera = camera
    }

    /// What the app's running process was launched with. Nothing, once it has quit or been launched again.
    func features(of bundleID: String, on udid: String) -> Features {
        guard let entry = launched["\(udid) \(bundleID)"], Self.isRunning(entry.process, on: udid) else { return [] }
        var features = entry.features
        if network.port == nil { features.remove(.network) }
        if camera.port == nil { features.remove(.camera) }
        return features
    }

    func relaunch(_ bundleID: String, on udid: String, with features: Features, libraries: Libraries = Libraries()) async throws {
        var paths: [String] = []
        var environment: [String: String] = [:]
        if features.contains(.network) {
            guard let library = libraries.network else { throw NetworkMonitorError.missingLibrary }
            let port = try await network.start()
            paths.append(library.path(percentEncoded: false))
            environment["SIMCTL_CHILD_BETTERSIM_MONITOR_PORT"] = String(port)
        }
        if features.contains(.camera) {
            guard let library = libraries.camera else { throw SimulatorCameraError.missingLibrary }
            let port = try await camera.start()
            paths.append(library.path(percentEncoded: false))
            environment["SIMCTL_CHILD_BETTERSIM_CAMERA_PORT"] = String(port)
        }
        if !paths.isEmpty { environment["SIMCTL_CHILD_DYLD_INSERT_LIBRARIES"] = paths.joined(separator: ":") }
        let output = try await Simctl.run(["launch", "--terminate-running-process", udid, bundleID], environment: environment)
        if let process = Self.processIdentifier(launchOutput: String(decoding: output, as: UTF8.self)) {
            launched["\(udid) \(bundleID)"] = (process, features)
        }
    }

    /// `simctl launch` prints the bundle identifier and the process it started, like `com.example.app: 4242`.
    nonisolated static func processIdentifier(launchOutput: String) -> pid_t? {
        launchOutput.split(separator: ":").last.flatMap { pid_t($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
    }

    /// Simulator apps are processes on the Mac, so the relaunched one is still the app while it lives in that device.
    nonisolated static func isRunning(_ process: pid_t, on udid: String) -> Bool {
        var path = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard proc_pidpath(process, &path, UInt32(path.count)) > 0 else { return false }
        return String(decoding: path.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self).contains("/Devices/\(udid)/")
    }
}
