import AppKit
import Foundation

extension AppDelegate {
    func checkForUpdates(showResult: Bool) {
        guard let url = URL(string: "https://api.github.com/repos/lordydord/Codex-Account-Switcher/releases/latest") else { return }
        updateHealthTitle = "Checking"
        updateHealthColor = .systemOrange
        refreshAccountPanelContentIfVisible()

        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        URLSession.shared.dataTask(with: request) { [weak self] data, _, error in
            DispatchQueue.main.async {
                guard let self else { return }
                if let error {
                    self.updateHealthTitle = "Error"
                    self.updateHealthColor = .systemRed
                    if showResult {
                        self.showAlert(title: "Update check failed", message: error.localizedDescription)
                    }
                    self.refreshAccountPanelContentIfVisible()
                    return
                }

                guard
                    let data,
                    let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                    let tag = object["tag_name"] as? String
                else {
                    self.updateHealthTitle = "Unknown"
                    self.updateHealthColor = .systemOrange
                    if showResult {
                        self.showAlert(title: "Update check failed", message: "GitHub did not return a readable latest release.")
                    }
                    self.refreshAccountPanelContentIfVisible()
                    return
                }

                let releaseURL = (object["html_url"] as? String).flatMap(URL.init(string:))
                let latestVersion = tag.trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
                let currentVersion = self.currentAppVersion()
                if self.version(latestVersion, isNewerThan: currentVersion) {
                    self.updateHealthTitle = tag
                    self.updateHealthColor = .systemOrange
                    if showResult {
                        self.showUpdateAvailableAlert(tag: tag, currentVersion: currentVersion, url: releaseURL)
                    }
                } else {
                    self.updateHealthTitle = "Current"
                    self.updateHealthColor = .systemGreen
                    if showResult {
                        self.showAlert(title: "AI Account Switcher is up to date", message: "Installed version \(currentVersion) matches the latest GitHub release.")
                    }
                }
                self.refreshAccountPanelContentIfVisible()
            }
        }.resume()
    }

    func showUpdateAvailableAlert(tag: String, currentVersion: String, url: URL?) {
        let alert = NSAlert()
        alert.messageText = "Update available"
        alert.informativeText = "Installed version \(currentVersion) can be updated to \(tag)."
        alert.addButton(withTitle: "Open Release")
        alert.addButton(withTitle: "Later")
        if alert.runAbovePanel() == .alertFirstButtonReturn, let url {
            NSWorkspace.shared.open(url)
        }
    }

    func currentAppVersion() -> String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    func version(_ left: String, isNewerThan right: String) -> Bool {
        let leftParts = left.split(separator: ".").map { Int($0) ?? 0 }
        let rightParts = right.split(separator: ".").map { Int($0) ?? 0 }
        let count = max(leftParts.count, rightParts.count)
        for index in 0..<count {
            let leftValue = index < leftParts.count ? leftParts[index] : 0
            let rightValue = index < rightParts.count ? rightParts[index] : 0
            if leftValue != rightValue {
                return leftValue > rightValue
            }
        }
        return false
    }

    func recordSwitch(from: CodexAccount?, to: CodexAccount?, automatic: Bool, reason: String, result: String) {
        let entry = SwitchHistoryEntry(
            date: Date(),
            fromLabel: from.map(preferences.displayLabel(for:)) ?? "?",
            toLabel: to.map(preferences.displayLabel(for:)) ?? "?",
            automatic: automatic,
            reason: reason,
            result: result
        )
        var entries = switchHistory()
        entries.insert(entry, at: 0)
        entries = Array(entries.prefix(30))
        if let data = try? JSONEncoder().encode(entries) {
            UserDefaults.standard.set(data, forKey: switchHistoryDefaultsKey)
        }
    }

    func switchHistory() -> [SwitchHistoryEntry] {
        guard let data = UserDefaults.standard.data(forKey: switchHistoryDefaultsKey) else { return [] }
        return (try? JSONDecoder().decode([SwitchHistoryEntry].self, from: data)) ?? []
    }

    func recordReset(
        label: String,
        result: String,
        creditBefore: Int?,
        creditAfter: Int?,
        usage: DirectUsageSnapshot?,
        detail: String
    ) {
        let entry = ResetHistoryEntry(
            date: Date(),
            accountLabel: label,
            result: result,
            creditBefore: creditBefore,
            creditAfter: creditAfter,
            fiveHourRemaining: usage?.fiveHour.remainingPercent,
            weeklyRemaining: usage?.weekly.remainingPercent,
            detail: detail
        )
        var entries = resetHistory()
        entries.insert(entry, at: 0)
        entries = Array(entries.prefix(30))
        if let data = try? JSONEncoder().encode(entries) {
            UserDefaults.standard.set(data, forKey: resetHistoryDefaultsKey)
        }
    }

    func resetHistory() -> [ResetHistoryEntry] {
        guard let data = UserDefaults.standard.data(forKey: resetHistoryDefaultsKey) else { return [] }
        return (try? JSONDecoder().decode([ResetHistoryEntry].self, from: data)) ?? []
    }

    func diagnosticsText() -> String {
        let version = currentAppVersion()
        let auth = commands.codexAuthPath() == nil ? "missing" : "available"
        let desktop = FileManager.default.fileExists(atPath: DesktopApplication.path) ? DesktopApplication.name : "missing"
        let entries = switchHistory().prefix(12).map { entry in
            let stamp = DateFormatter.diagnosticStamp.string(from: entry.date)
            return "\(stamp) | \(entry.fromLabel)->\(entry.toLabel) | \(entry.automatic ? "automatic" : "manual") | \(entry.reason) | \(entry.result)"
        }
        let resetEntries = resetHistory().prefix(8).map { entry in
            let stamp = DateFormatter.diagnosticStamp.string(from: entry.date)
            let credits = resetCreditChangeText(before: entry.creditBefore, after: entry.creditAfter)
            let usage = entry.fiveHourRemaining.map { "5h \($0)%" } ?? "5h ?"
            let weekly = entry.weeklyRemaining.map { "weekly \($0)%" } ?? "weekly ?"
            return "\(stamp) | reset \(entry.accountLabel) | \(entry.result) | \(credits) | \(usage), \(weekly) | \(entry.detail)"
        }
        return ([
            "AI Account Switcher \(version)",
            "macOS \(ProcessInfo.processInfo.operatingSystemVersionString)",
            "codex-auth: \(auth)",
            "desktop: \(desktop)",
            "saved accounts: \(accounts.count)",
            "auto switch: \(preferences.autoSwitchMode.rawValue)",
            "auto resume: \(preferences.autoResumeMode.rawValue)",
            "refresh: \(lastUpdatedText())",
            "switch history:"
        ] + (entries.isEmpty ? ["none"] : entries) + [
            "reset history:"
        ] + (resetEntries.isEmpty ? ["none"] : resetEntries)).joined(separator: "\n")
    }

    func showDiagnostics() {
        let text = diagnosticsText()
        let alert = NSAlert()
        alert.messageText = "Reliability diagnostics"
        alert.informativeText = text
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Copy")
        alert.addButton(withTitle: "Close")
        if alert.runAbovePanel() == .alertFirstButtonReturn {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }
    }
}
