import Foundation

final class CodexCommands {
    private var cachedCodexAuthPath: String?
    private let codexAuthPathLock = NSLock()

    func runCodexAuth(_ args: [String]) -> CommandResult {
        guard let path = codexAuthPath() else {
            return CommandResult(status: 127, output: "codex-auth was not found in known locations.")
        }
        let result = run(path, args)
        if result.status == 127 {
            invalidateCodexAuthPath()
        }
        return result
    }

    func codexAuthPath() -> String? {
        codexAuthPathLock.lock()
        let cached = cachedCodexAuthPath
        codexAuthPathLock.unlock()
        if let cached, FileManager.default.isExecutableFile(atPath: cached) {
            return cached
        }
        let resolved = resolveCodexAuthPath()
        codexAuthPathLock.lock()
        cachedCodexAuthPath = resolved
        codexAuthPathLock.unlock()
        return resolved
    }

    func invalidateCodexAuthPath() {
        codexAuthPathLock.lock()
        cachedCodexAuthPath = nil
        codexAuthPathLock.unlock()
    }

    func resolveCodexAuthPath() -> String? {
        let home = NSHomeDirectory()
        let stableCandidates = [
            "\(home)/.local/bin/codex-auth",
            "/opt/homebrew/bin/codex-auth",
            "/usr/local/bin/codex-auth"
        ]
        if let path = stableCandidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }),
           ProcessRunner.run(path, ["--version"], environment: augmentedEnvironment(), timeout: 4).status == 0 {
            return path
        }

        for binDirectory in nodeBinDirectories {
            let path = binDirectory.appendingPathComponent("codex-auth").path
            if FileManager.default.isExecutableFile(atPath: path),
               ProcessRunner.run(path, ["--version"], environment: augmentedEnvironment(), timeout: 4).status == 0 {
                return path
            }
        }

        let fallback = ProcessRunner.run(
            "/bin/zsh",
            ["-l", "-c", "which codex-auth"],
            environment: augmentedEnvironment(),
            timeout: 5
        )
        if fallback.status == 0 {
            let path = fallback.output.trimmingCharacters(in: .whitespacesAndNewlines)
            if !path.isEmpty, FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        }

        return nil
    }

    func run(_ executable: String, _ args: [String]) -> CommandResult {
        var environment = augmentedEnvironment()
        let bundledNode = "\(DesktopApplication.resourcesPath)/node"
        if FileManager.default.isExecutableFile(atPath: bundledNode) {
            environment["CODEX_AUTH_NODE_EXECUTABLE"] = bundledNode
        }
        let bundledCodex = "\(DesktopApplication.resourcesPath)/codex"
        if FileManager.default.isExecutableFile(atPath: bundledCodex) {
            environment["CODEX_CLI_PATH"] = bundledCodex
        }
        return ProcessRunner.run(executable, args, environment: environment, timeout: commandTimeout(for: executable, arguments: args))
    }

    func commandTimeout(for executable: String, arguments: [String]) -> TimeInterval {
        let command = URL(fileURLWithPath: executable).lastPathComponent
        if command == "codex-auth" {
            return arguments.first == "login" ? 180 : 20
        }
        if command == "open" || command == "osascript" { return 15 }
        return 12
    }

    func augmentedEnvironment() -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = augmentedPath(from: environment["PATH"])
        return environment
    }

    func augmentedPath(from currentPath: String?) -> String {
        let home = NSHomeDirectory()
        let candidates = [
            "\(home)/.local/bin",
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/usr/bin",
            "/bin",
            "/usr/sbin",
            "/sbin"
        ]

        var seen = Set<String>()
        var parts: [String] = []
        let nodeBins = nodeBinDirectories.map(\.path)
        for path in [DesktopApplication.resourcesPath] + nodeBins + candidates + (currentPath?.split(separator: ":").map(String.init) ?? []) {
            guard !path.isEmpty, !seen.contains(path) else { continue }
            seen.insert(path)
            parts.append(path)
        }
        return parts.joined(separator: ":")
    }

    func shellEnvironmentSetupCommand() -> String {
        let path = augmentedPath(from: nil)
        var commands = ["export PATH=\(Self.shellEscaped(path))"]
        let bundledNode = "\(DesktopApplication.resourcesPath)/node"
        if FileManager.default.isExecutableFile(atPath: bundledNode) {
            commands.append("export CODEX_AUTH_NODE_EXECUTABLE=\(Self.shellEscaped(bundledNode))")
        }
        let bundledCodex = "\(DesktopApplication.resourcesPath)/codex"
        if FileManager.default.isExecutableFile(atPath: bundledCodex) {
            commands.append("export CODEX_CLI_PATH=\(Self.shellEscaped(bundledCodex))")
        }
        return commands.joined(separator: "; ")
    }

    static func shellEscaped(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    func listCodexAccounts() -> (result: CommandResult, accounts: [CodexAccount]) {
        let json = runCodexAuth(["list", "--skip-api", "--json"])
        if json.status == 0, let entries = CodexAuthListJSON.parse(json.output) {
            let accounts = entries.map { entry in
                CodexAccount(
                    selector: entry.selector,
                    email: entry.email,
                    plan: entry.plan,
                    fiveHourUsage: "-",
                    weeklyUsage: "-",
                    fiveHourRemaining: nil,
                    weeklyRemaining: nil,
                    lastActivity: "-",
                    isActive: entry.isActive
                )
            }
            return (json, accounts)
        }
        // codex-auth without `--json`: its table still carries email, plan and the active mark.
        let table = runCodexAuth(["list", "--skip-api"])
        return (table, table.status == 0 ? CodexAuthListTable.parse(table.output) : [])
    }

    func verifyActiveAccount(expectedEmail: String) -> CommandResult {
        for attempt in 1...3 {
            let (result, parsed) = listCodexAccounts()
            if result.status == 0 {
                if parsed.contains(where: { $0.isActive && $0.email.caseInsensitiveCompare(expectedEmail) == .orderedSame }) {
                    return CommandResult(status: 0, output: "active account verified")
                }
            }
            if attempt < 3 { Thread.sleep(forTimeInterval: 0.6) }
        }
        return CommandResult(status: 1, output: "codex-auth did not report the requested account as active after three checks")
    }

    var cachedPath: String? {
        codexAuthPathLock.lock()
        defer { codexAuthPathLock.unlock() }
        return cachedCodexAuthPath
    }

    private var nodeBinDirectories: [URL] {
        let root = URL(fileURLWithPath: "\(NSHomeDirectory())/.nvm/versions/node")
        return ((try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [])
            .sorted { $0.lastPathComponent.compare($1.lastPathComponent, options: .numeric) == .orderedDescending }
            .map { $0.appendingPathComponent("bin") }
    }

}
