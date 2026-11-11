import AppKit
import Foundation

extension AppDelegate {
    func codexIsFrontmost() -> Bool {
        guard let app = NSWorkspace.shared.frontmostApplication else { return false }
        return isCodexDesktopApplication(app)
    }

    func isCodexDesktopApplication(_ app: NSRunningApplication) -> Bool {
        DesktopApplication.matches(bundleID: app.bundleIdentifier, name: app.localizedName)
    }

    func launchAgentURL() -> URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/LaunchAgents/\(launchAgentIdentifier).plist")
    }

    func launchAtLoginEnabled() -> Bool {
        FileManager.default.fileExists(atPath: launchAgentURL().path)
    }

    func installLaunchAgent() throws {
        let monitorPath = Bundle.main.resourceURL!
            .appendingPathComponent("CodexLifecycleMonitor")
            .path
        guard FileManager.default.isExecutableFile(atPath: monitorPath) else {
            throw NSError(
                domain: "CodexAccountSwitcher",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "The lifecycle monitor is missing from the app bundle. Reinstall AI Account Switcher."]
            )
        }
        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
          <key>Label</key>
          <string>\(launchAgentIdentifier)</string>
          <key>ProgramArguments</key>
          <array>
            <string>\(monitorPath)</string>
          </array>
          <key>EnvironmentVariables</key>
          <dict>
            <key>PATH</key>
            <string>/usr/bin:/bin:/usr/sbin:/sbin</string>
            <key>HOME</key>
            <string>\(NSHomeDirectory())</string>
          </dict>
          <key>RunAtLoad</key>
          <true/>
          <key>KeepAlive</key>
          <true/>
          <key>ThrottleInterval</key>
          <integer>5</integer>
        </dict>
        </plist>
        """
        let url = launchAgentURL()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try plist.write(to: url, atomically: true, encoding: .utf8)
        let userDomain = "gui/\(getuid())"
        _ = commands.run("/bin/launchctl", ["bootout", userDomain, url.path])
        let bootstrap = commands.run("/bin/launchctl", ["bootstrap", userDomain, url.path])
        guard bootstrap.status == 0 else {
            throw NSError(
                domain: "CodexAccountSwitcher",
                code: Int(bootstrap.status),
                userInfo: [NSLocalizedDescriptionKey: "Could not start the lifecycle monitor: \(bootstrap.output)"]
            )
        }
    }

    func removeLaunchAgent() throws {
        let url = launchAgentURL()
        let userDomain = "gui/\(getuid())"
        _ = commands.run("/bin/launchctl", ["bootout", userDomain, url.path])
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    func restartCodexApp() -> CommandResult {
        var transcript: [String] = []
        let desktop = SpaceRestorer(windowsOf: Set(codexAppPIDs().compactMap { Int32($0) }))
        transcript.append("Quitting \(DesktopApplication.name) process tree...")

        // Ask politely first, then force; each step returns as soon as the processes are gone.
        for (signal, timeout) in [("-TERM", 4.0), ("-KILL", 2.0), ("-KILL", 1.0)] {
            let pids = codexAppPIDs()
            if pids.isEmpty { break }
            _ = commands.run("/bin/kill", [signal] + pids)
            if waitUntil(timeout: timeout, { self.codexAppPIDs().isEmpty }) { break }
        }

        let remaining = codexAppPIDs()
        if !remaining.isEmpty {
            transcript.append("Codex helper processes remained after force quit: \(remaining.joined(separator: ", ")). Opening Codex anyway.")
        }

        if let configMessage = ensureComputerUsePluginConfigured() {
            transcript.append(configMessage)
        }

        transcript.append("Opening \(DesktopApplication.name)...")
        desktop?.showRememberedSpace()
        let openResult = commands.run("/usr/bin/open", [DesktopApplication.path])
        if openResult.status != 0 {
            desktop?.returnToPreviousSpace()
            return CommandResult(status: openResult.status, output: transcript.joined(separator: "\n") + "\n" + openResult.output)
        }

        let mainExecutablePattern = "\(NSRegularExpression.escapedPattern(for: DesktopApplication.path))/Contents/MacOS/"
        let launched = waitUntil(timeout: 10) {
            self.commands.run("/usr/bin/pgrep", ["-f", mainExecutablePattern]).status == 0
        }
        guard launched else {
            desktop?.returnToPreviousSpace()
            transcript.append("\(DesktopApplication.name) did not report as running after launch.")
            return CommandResult(status: 1, output: transcript.joined(separator: "\n"))
        }
        if let desktop, !desktop.isVisible {
            // Let the first window open on the remembered desktop before leaving it.
            _ = waitUntil(timeout: 8) { SpaceRestorer(windowsOf: Set(self.codexAppPIDs().compactMap { Int32($0) })) != nil }
            Thread.sleep(forTimeInterval: 0.6)
            desktop.returnToPreviousSpace()
        }
        return CommandResult(status: 0, output: transcript.joined(separator: "\n"))
    }

    func waitUntil(timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if condition() { return true }
            Thread.sleep(forTimeInterval: 0.2)
        } while Date() < deadline
        return condition()
    }

    func ensureComputerUsePluginConfigured() -> String? {
        let home = NSHomeDirectory()
        let configURL = URL(fileURLWithPath: "\(home)/.codex/config.toml")
        let stateURL = URL(fileURLWithPath: "\(home)/.codex/.codex-global-state.json")
        var changed = false

        do {
            var config = try String(contentsOf: configURL, encoding: .utf8)
            if !config.contains("[plugins.\"computer-use@openai-bundled\"]") {
                let chromeBlock = "[plugins.\"chrome@openai-bundled\"]\nenabled = true"
                let computerUseBlock = "\(chromeBlock)\n\n[plugins.\"computer-use@openai-bundled\"]\nenabled = true"
                if config.contains(chromeBlock) {
                    config = config.replacingOccurrences(of: chromeBlock, with: computerUseBlock)
                } else {
                    config += "\n\n[plugins.\"computer-use@openai-bundled\"]\nenabled = true\n"
                }
                changed = true
            }

            if let computerUseApp = ComputerUsePluginLocator.latestApp(homeDirectory: home) {
                let codePathLine = "CODEX_CLI_PATH = \"\(DesktopApplication.resourcesPath)/codex\""
                let servicePathLine = "SKY_CUA_SERVICE_PATH = \"\(computerUseApp.path)\""
                let pattern = #"(?m)^SKY_CUA_SERVICE_PATH = ".*"$"#
                if let regex = try? NSRegularExpression(pattern: pattern),
                   let match = regex.firstMatch(in: config, range: NSRange(config.startIndex..., in: config)),
                   let range = Range(match.range, in: config) {
                    if config[range] != servicePathLine {
                        config.replaceSubrange(range, with: servicePathLine)
                        changed = true
                    }
                } else if config.contains(codePathLine) {
                    config = config.replacingOccurrences(of: codePathLine, with: "\(servicePathLine)\n\(codePathLine)")
                    changed = true
                }
            }

            if changed {
                try config.write(to: configURL, atomically: true, encoding: .utf8)
            }
        } catch {
            return "Computer Use config check failed: \(error.localizedDescription)"
        }

        do {
            var state = try String(contentsOf: stateURL, encoding: .utf8)
            if state.contains("\"electron-chrome-extension-sync-managed-plugin-ids\":[\"chrome@openai-bundled\"]") {
                state = state.replacingOccurrences(
                    of: "\"electron-chrome-extension-sync-managed-plugin-ids\":[\"chrome@openai-bundled\"]",
                    with: "\"electron-chrome-extension-sync-managed-plugin-ids\":[\"chrome@openai-bundled\",\"computer-use@openai-bundled\"]"
                )
                try state.write(to: stateURL, atomically: true, encoding: .utf8)
                changed = true
            }
        } catch {
            return "Computer Use state check failed: \(error.localizedDescription)"
        }

        return changed ? "Repaired Computer Use plugin config before Codex launch." : nil
    }

    func codexAppPIDs() -> [String] {
        let escapedPath = NSRegularExpression.escapedPattern(for: DesktopApplication.path)
        let result = commands.run("/usr/bin/pgrep", ["-f", "\(escapedPath)/Contents/"])
        guard result.status == 0 else { return [] }
        return result.output
            .split(whereSeparator: \.isNewline)
            .map(String.init)
            .filter { !$0.isEmpty }
    }
}
