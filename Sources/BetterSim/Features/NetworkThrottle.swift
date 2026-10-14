import AppKit

/// Network speeds to simulate, with the values Apple's Network Link Conditioner uses for its own presets.
enum NetworkCondition: String, CaseIterable, Identifiable, Sendable {
    case normal = "Normal"
    case wifi = "Wi-Fi"
    case lte = "LTE"
    case dsl = "DSL"
    case threeG = "3G"
    case edge = "Edge"
    case veryBad = "Very Bad Network"
    case offline = "100% Loss"

    var id: String { rawValue }

    struct Link: Equatable {
        let kilobits: Int
        let delay: Int
        let loss: Double
    }

    var download: Link? {
        switch self {
        case .normal: nil
        case .wifi: Link(kilobits: 40_000, delay: 1, loss: 0)
        case .lte: Link(kilobits: 50_000, delay: 50, loss: 0)
        case .dsl: Link(kilobits: 2_000, delay: 5, loss: 0)
        case .threeG: Link(kilobits: 780, delay: 100, loss: 0)
        case .edge: Link(kilobits: 240, delay: 400, loss: 0)
        case .veryBad: Link(kilobits: 1_000, delay: 500, loss: 0.1)
        case .offline: Link(kilobits: 1_000, delay: 0, loss: 1)
        }
    }

    var upload: Link? {
        switch self {
        case .normal: nil
        case .wifi: Link(kilobits: 33_000, delay: 1, loss: 0)
        case .lte: Link(kilobits: 10_000, delay: 65, loss: 0)
        case .dsl: Link(kilobits: 256, delay: 5, loss: 0)
        case .threeG: Link(kilobits: 330, delay: 100, loss: 0)
        case .edge: Link(kilobits: 200, delay: 440, loss: 0)
        case .veryBad: Link(kilobits: 1_000, delay: 500, loss: 0.1)
        case .offline: Link(kilobits: 1_000, delay: 0, loss: 1)
        }
    }
}

/// Slows the Mac's network with the dummynet traffic shaper built into macOS, which is what Network Link Conditioner
/// uses too. The Simulator shares the Mac's network, so it can't be slowed on its own: this affects every app on the
/// Mac until it's turned off. Changing it needs an administrator password, which macOS asks for itself.
enum NetworkThrottle {
    static let anchor = "com.apple/bettersim"
    static let tokenFile = "/var/tmp/bettersim-pf-token"

    struct Failure: LocalizedError {
        let errorDescription: String?
    }

    /// The shell commands, run as root, that switch to `condition`. Rules go in a sub-anchor of com.apple, which
    /// the system's pf.conf already loads, so the user's own firewall rules are left alone.
    static func script(for condition: NetworkCondition) -> String {
        var commands = [
            "/sbin/pfctl -q -a \(anchor) -F all 2>/dev/null",
            "/usr/sbin/dnctl -q pipe delete 81 2>/dev/null",
            "/usr/sbin/dnctl -q pipe delete 82 2>/dev/null",
            "if [ -f \(tokenFile) ]; then /sbin/pfctl -q -X $(cat \(tokenFile)) 2>/dev/null; rm -f \(tokenFile); fi",
        ]
        if let down = condition.download, let up = condition.upload {
            commands += [
                "/usr/sbin/dnctl pipe 81 config \(pipe(down))",
                "/usr/sbin/dnctl pipe 82 config \(pipe(up))",
                "printf 'dummynet in quick proto { tcp, udp } from any to any pipe 81\\ndummynet out quick proto { tcp, udp } from any to any pipe 82\\n' | /sbin/pfctl -q -a \(anchor) -f -",
                "/sbin/pfctl -E 2>&1 | /usr/bin/sed -n 's/^Token : //p' > \(tokenFile)",
                "chmod 644 \(tokenFile)",
            ]
        }
        return commands.joined(separator: "; ")
    }

    static func pipe(_ link: NetworkCondition.Link) -> String {
        let loss = String(format: "%.2f", locale: Locale(identifier: "en_US_POSIX"), link.loss)
        return "bw \(link.kilobits)Kbit/s delay \(link.delay) plr \(loss)"
    }

    /// Runs as root through AppleScript, so macOS shows its own password prompt. NSAppleScript keeps the
    /// authorisation for a few minutes, so switching presets in a row only asks once.
    @MainActor
    static func apply(_ condition: NetworkCondition) throws {
        let escaped = script(for: condition).replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let source = "do shell script \"\(escaped)\" with administrator privileges"
        var error: NSDictionary?
        NSAppleScript(source: source)?.executeAndReturnError(&error)
        if let error {
            let message = error[NSAppleScript.errorMessage] as? String ?? "macOS didn't allow the change."
            throw Failure(errorDescription: (error[NSAppleScript.errorNumber] as? Int) == -128 ? "Cancelled." : message)
        }
    }

    /// Whether BetterSim's slowdown is still switched on, for example after a crash.
    static var isActive: Bool {
        FileManager.default.fileExists(atPath: tokenFile)
    }
}
