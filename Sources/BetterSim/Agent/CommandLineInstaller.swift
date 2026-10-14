import AppKit

/// Links `bettersim` in ~/.local/bin to this copy of BetterSim, so agents can run the tool from any terminal.
enum CommandLineInstaller {
    static var link: URL {
        FileManager.default.homeDirectoryForCurrentUser.appending(path: ".local/bin/bettersim")
    }

    /// Replaces an earlier link, but never a real file someone put there.
    static func install(_ executable: URL, at link: URL = link) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        let path = link.path(percentEncoded: false)
        if let type = (try? fileManager.attributesOfItem(atPath: path))?[.type] as? FileAttributeType {
            guard type == .typeSymbolicLink else {
                throw AgentFailure(.failed, "There's already a file at \(path), so BetterSim left it alone.")
            }
            try fileManager.removeItem(at: link)
        }
        try fileManager.createSymbolicLink(at: link, withDestinationURL: executable)
    }

    static func manualCommand(for executable: URL) -> String {
        "mkdir -p ~/.local/bin && ln -sf '\(executable.path(percentEncoded: false))' ~/.local/bin/bettersim"
    }

    @MainActor
    static func installFromMenu() {
        let executable = Bundle.main.executableURL ?? URL(filePath: CommandLine.arguments[0])
        let alert = NSAlert()
        do {
            try install(executable)
            alert.messageText = "Installed bettersim"
            alert.informativeText = """
            Agents can now run bettersim in a terminal. Start with bettersim doctor. The link points at this copy of \
            BetterSim, so install it again if you move the app.

            If your shell can't find bettersim, add this line to your shell profile:
            export PATH="$HOME/.local/bin:$PATH"
            """
            alert.addButton(withTitle: "OK")
        } catch {
            alert.alertStyle = .warning
            alert.messageText = "BetterSim couldn't install bettersim"
            alert.informativeText = "\(error.localizedDescription)\n\nTo install it yourself, run:\n\(manualCommand(for: executable))"
            alert.addButton(withTitle: "OK")
            alert.addButton(withTitle: "Copy Command")
        }
        NSApp.activate()
        if alert.runModal() == .alertSecondButtonReturn {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(manualCommand(for: executable), forType: .string)
        }
    }
}
