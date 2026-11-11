import Foundation

enum ClaudeCLI {
    static func executable() -> String? {
        let candidates = [
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/claude").path,
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/local/claude").path,
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude"
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    static func openLoginTerminal(email: String?) throws {
        guard ClaudeAccountStore.synchronize().preserved else {
            throw ClaudeError.message("The current Claude login could not be saved first. Try again shortly.")
        }
        guard let claude = executable() else {
            throw ClaudeError.message("Claude Code CLI was not found. Install it from claude.com/claude-code.")
        }
        func quoted(_ value: String) -> String { "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'" }
        var command = "\(quoted(claude)) auth login"
        if let email, email.contains("@") { command += " --email \(quoted(email))" }
        let script = "#!/bin/zsh\nclear\necho 'Sign in to Claude. The switcher saves this login automatically.'\n\(command)\nexit\n"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("claude-login-\(UUID().uuidString).command")
        try script.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        let result = ProcessRunner.run("/usr/bin/open", ["-a", "Terminal", url.path], environment: [:], timeout: 10)
        guard result.status == 0 else { throw ClaudeError.message("Could not open Terminal: \(result.output)") }
    }
}
