import Foundation

struct SimctlError: LocalizedError {
    let command: String
    let status: Int32
    let message: String

    var errorDescription: String? {
        message.isEmpty ? "simctl \(command) failed with status \(status)." : message
    }
}

enum Simctl {
    // `xcrun` resolves the active Xcode on every call, which adds a noticeable delay, so look simctl up once.
    static let executable: URL = {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(filePath: "/usr/bin/xcrun")
        process.arguments = ["--find", "simctl"]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return URL(filePath: "/usr/bin/xcrun") }
        let path = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        process.waitUntilExit()
        return process.terminationStatus == 0 && !path.isEmpty ? URL(filePath: path) : URL(filePath: "/usr/bin/xcrun")
    }()

    static func arguments(_ arguments: [String]) -> [String] {
        executable.lastPathComponent == "xcrun" ? ["simctl"] + arguments : arguments
    }

    /// `environment` reaches the launched app when its keys start with SIMCTL_CHILD_.
    @discardableResult
    static func run(_ arguments: [String], input: Data? = nil, environment: [String: String] = [:]) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(with: Result { try runBlocking(arguments, input: input, environment: environment) })
            }
        }
    }

    static func output(_ arguments: [String]) async throws -> String {
        String(decoding: try await run(arguments), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func process(_ arguments: [String]) -> Process {
        let process = Process()
        process.executableURL = executable
        process.arguments = Self.arguments(arguments)
        return process
    }

    private static func runBlocking(_ arguments: [String], input: Data?, environment: [String: String]) throws -> Data {
        let process = process(arguments)
        if !environment.isEmpty {
            process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
        }
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        let stdin = Pipe()
        process.standardInput = input == nil ? FileHandle.nullDevice : stdin
        try process.run()
        if let input {
            stdin.fileHandleForWriting.write(input)
            try? stdin.fileHandleForWriting.close()
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let message = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            throw SimctlError(
                command: arguments.first ?? "",
                status: process.terminationStatus,
                message: message.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
        return data
    }
}
