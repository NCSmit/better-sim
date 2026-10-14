import Foundation

/// Records with `simctl io recordVideo` in a session of its own, so the recording outlives the `bettersim record start`
/// that began it, and the agent's shell, until `bettersim record stop` ends it.
enum DetachedRecording {
    struct State: Codable, Equatable {
        let pid: Int32
        let udid: String
        let name: String
        let movie: String
        let gif: Bool
    }

    static var folder: URL {
        AgentSocket.userTemporaryDirectory.appending(path: "BetterSim Recordings", directoryHint: .isDirectory)
    }

    static func start(_ device: SimDevice, gif: Bool) async throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        if let existing = states().first(where: { $0.udid == device.udid }) {
            guard !isRecording(existing) else {
                throw AgentFailure(.failed, "\(device.name) is already recording. Run bettersim record stop first.")
            }
            discard(existing)
        }
        let movie = folder.appending(path: "\(device.udid).mov")
        let log = folder.appending(path: "\(device.udid).log")
        try? FileManager.default.removeItem(at: movie)
        FileManager.default.createFile(atPath: log.path(percentEncoded: false), contents: nil)
        let arguments = Simctl.arguments(["io", device.udid, "recordVideo", "--codec=h264", "--force", movie.path(percentEncoded: false)])
        let pid = try spawn(Simctl.executable.path(percentEncoded: false), arguments, errorLog: log.path(percentEncoded: false))
        let state = State(pid: pid, udid: device.udid, name: device.name, movie: movie.path(percentEncoded: false), gif: gif)
        try AgentCoding.encode(state).write(to: stateFile(device.udid))
        for _ in 0..<200 {
            if (try? String(contentsOf: log, encoding: .utf8))?.contains("Recording started") == true { return }
            guard isAlive(pid) else {
                let reason = lastLine(of: log) ?? "simctl stopped straight away."
                discard(state)
                throw AgentFailure(.failed, "The recording didn't start. \(reason)")
            }
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    /// Stops the recording on `udid`, or the only recording when no device is named, and saves it as MP4 or GIF.
    /// The movie is kept until it's saved, so running this again retries a save that failed.
    static func stop(udid: String?, gif: Bool, output: String?) async throws -> URL {
        let state = try recording(udid)
        if isRecording(state) {
            kill(state.pid, SIGINT)
            var waited = 0.0
            while isAlive(state.pid) {
                guard waited < 20 else {
                    kill(state.pid, SIGKILL)
                    discard(state)
                    throw AgentFailure(.failed, "simctl didn't finish the recording in time.")
                }
                try await Task.sleep(for: .milliseconds(50))
                waited += 0.05
            }
        }
        let movie = URL(filePath: state.movie)
        guard FileManager.default.fileExists(atPath: state.movie) else {
            let reason = lastLine(of: logFile(state.udid)) ?? ""
            discard(state)
            throw AgentFailure(.failed, "simctl didn't save the recording. \(reason)")
        }
        let asGIF = gif || state.gif
        let device = SimDevice(udid: state.udid, name: state.name, state: "Booted", deviceTypeIdentifier: "", runtime: "")
        let destination = try OutputPaths.destination(output, for: device, extension: asGIF ? "gif" : "mp4")
        try? FileManager.default.removeItem(at: destination)
        if asGIF {
            try await GIFExporter.export(video: movie, to: destination)
        } else {
            try await MP4Exporter.export(video: movie, to: destination)
        }
        discard(state)
        return destination
    }

    static func states() -> [State] {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }.compactMap { file in
            (try? Data(contentsOf: file)).flatMap { try? AgentCoding.decode(State.self, from: $0) }
        }
    }

    private static func recording(_ udid: String?) throws -> State {
        let all = states()
        let notRecording = AgentFailure(.failed, "Nothing is recording. Start with bettersim record start.")
        if let udid {
            guard let state = all.first(where: { $0.udid.caseInsensitiveCompare(udid) == .orderedSame }) else { throw notRecording }
            return state
        }
        guard let only = all.first else { throw notRecording }
        guard all.count == 1 else { throw AgentFailure(.usage, "More than one simulator is recording. Say which with --udid.") }
        return only
    }

    /// True while the recorder runs. Checks the process is still simctl, in case its process ID was reused.
    private static func isRecording(_ state: State) -> Bool {
        guard isAlive(state.pid) else { return false }
        var name = [CChar](repeating: 0, count: 256)
        guard proc_name(state.pid, &name, UInt32(name.count)) > 0 else { return false }
        return String(decoding: name.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self) == "simctl"
    }

    /// Works for the recorder this process started, which has to be reaped, and for one started by an earlier run.
    private static func isAlive(_ pid: pid_t) -> Bool {
        var status: Int32 = 0
        if waitpid(pid, &status, WNOHANG) == pid { return false }
        return kill(pid, 0) == 0 || errno == EPERM
    }

    private static func spawn(_ executable: String, _ arguments: [String], errorLog: String) throws -> pid_t {
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_addopen(&actions, 1, "/dev/null", O_WRONLY, 0)
        posix_spawn_file_actions_addopen(&actions, 2, errorLog, O_WRONLY | O_APPEND, 0)
        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT))
        let argv = ([executable] + arguments).map { strdup($0) } + [nil]
        defer { argv.forEach { free($0) } }
        var pid = pid_t()
        let status = posix_spawn(&pid, executable, &actions, &attributes, argv, environ)
        guard status == 0 else {
            throw AgentFailure(.failed, "BetterSim couldn't start simctl: \(String(cString: strerror(status))).")
        }
        return pid
    }

    private static func discard(_ state: State) {
        for file in [stateFile(state.udid), logFile(state.udid), URL(filePath: state.movie)] {
            try? FileManager.default.removeItem(at: file)
        }
    }

    private static func stateFile(_ udid: String) -> URL { folder.appending(path: "\(udid).json") }
    private static func logFile(_ udid: String) -> URL { folder.appending(path: "\(udid).log") }

    private static func lastLine(of file: URL) -> String? {
        (try? String(contentsOf: file, encoding: .utf8))?
            .split(separator: "\n")
            .last { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .map { $0.trimmingCharacters(in: .whitespaces) }
    }
}
