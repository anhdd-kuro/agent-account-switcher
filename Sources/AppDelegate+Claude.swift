import AppKit
import Foundation

extension AppDelegate {
    func switchClaudeAccount(_ id: String) {
        guard !claude.isSwitching, let target = claude.accounts.first(where: { $0.id == id }) else { return }
        setResetStatus("Switching")
        claude.switchTo(id) { [weak self] failure in
            guard let self else { return }
            self.setResetStatus(nil)
            if let failure {
                self.showAlert(title: "Claude switch failed", message: failure)
            } else {
                self.sendNotification(title: "Claude switched", subtitle: target.title, body: "New Claude Code sessions use \(target.title) (\(target.email)).")
            }
        }
    }

    func signInToClaude(email: String?) {
        closeAccountPanel()
        claude.signIn(email: email) { [weak self] failure in
            if let failure {
                self?.showAlert(title: "Claude sign-in", message: failure)
                return
            }
            for delay in [20.0, 45.0, 90.0, 180.0] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in self?.claude.refresh() }
            }
        }
    }

    func confirmClaudeReset(profileID: String, grantID: String) {
        guard let account = claude.accounts.first(where: { $0.id == profileID }),
              let grant = account.resets?.grants.first(where: { $0.id == grantID }) else {
            showAlert(title: "Reset unavailable", message: "This Claude reset is no longer listed. Refresh and try again.")
            return
        }
        var details = [grant.label.isEmpty ? grant.title : grant.label]
        if !grant.clearedText.isEmpty { details.append("Clears: \(grant.clearedText)") }
        details.append("Resets left after this: \(max(0, grant.resetsLeft - 1))")
        if let endsAt = grant.endsAt { details.append("Use by: \(DateFormatter.resetCreditDisplay.string(from: endsAt))") }
        let alert = NSAlert()
        alert.messageText = "Use a Claude \(grant.title.lowercased()) for \(account.title)?"
        alert.informativeText = "This spends one reset for \(account.email).\n\n" + details.joined(separator: "\n")
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Use Reset")
        alert.addButton(withTitle: "Cancel")
        closeAccountPanel()
        guard alert.runAbovePanel() == .alertFirstButtonReturn else { return }

        let generation = beginStatusAnimation(title: "Resetting")
        claude.claimReset(profileID: profileID, grantID: grantID) { [weak self] result in
            guard let self else { return }
            self.endStatusAnimation(expectedGeneration: generation)
            switch result {
            case .success(.reset(let confirmed, let cleared)):
                let what = cleared.isEmpty ? "Limits" : "\(cleared) limits"
                let message = confirmed
                    ? "\(what) for \(account.title) were reset."
                    : "Anthropic accepted the reset for \(account.title) but has not confirmed it yet. If your limits aren't refilled in a few minutes, refresh."
                self.sendNotification(title: confirmed ? "Claude reset used" : "Claude reset pending", subtitle: account.title, body: message)
                self.showAlert(title: confirmed ? "Reset confirmed" : "Reset pending", message: message)
            case .success(.refused(let reason)):
                self.showAlert(title: "Reset not used", message: reason)
            case .failure(let error):
                self.showAlert(title: "Reset failed", message: error.localizedDescription)
            }
            self.refreshUI()
        }
    }

    func confirmRemoveClaudeAccount(_ id: String) {
        guard let account = claude.accounts.first(where: { $0.id == id }) else { return }
        let alert = NSAlert()
        alert.messageText = "Remove \(account.title)?"
        alert.informativeText = "The saved login for \(account.email) is deleted from the Keychain. You can sign in again later."
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runAbovePanel() == .alertFirstButtonReturn else { return }
        do {
            try claude.remove(id)
        } catch {
            showAlert(title: "Remove Claude account", message: error.localizedDescription)
        }
    }

    func checkClaudeAutomation() {
        guard let active = claude.active, !active.needsLogin, !claude.isSwitching else { return }
        if preferences.remindersEnabled {
            for (metric, percent) in [("5hr", active.fiveHourRemaining), ("Weekly", active.weeklyRemaining)] {
                guard let percent else { continue }
                let key = "reminder|\(active.id)|\(metric)|\(preferences.reminderThreshold)"
                if percent > preferences.reminderThreshold {
                    notifiedClaudeKeys.remove(key)
                } else if notifiedClaudeKeys.insert(key).inserted {
                    sendNotification(title: "Claude usage is low", subtitle: "\(active.title) · \(metric) \(percent)%", body: "\(active.email) is at or below \(preferences.reminderThreshold)%.")
                }
            }
        }
        let mode = preferences.autoSwitchMode
        guard mode != .off else { return }
        let limit = mode == .zero ? 0 : preferences.autoSwitchThreshold
        func level(_ account: ClaudeAccountSummary) -> Int? {
            guard account.usageError == nil, !account.needsLogin,
                  let five = account.fiveHourRemaining, let weekly = account.weeklyRemaining else { return nil }
            return min(five, weekly)
        }
        guard let activeLevel = level(active), activeLevel <= limit,
              let target = claude.accounts
                .filter({ !$0.isActive && (level($0) ?? -1) > limit })
                .max(by: { (level($0) ?? -1) < (level($1) ?? -1) }),
              let targetLevel = level(target) else { return }
        let key = "switch|\(active.id)|\(target.id)|\(limit)|\(mode.rawValue)"
        guard notifiedClaudeKeys.insert(key).inserted else { return }
        if mode == .threshold {
            switchClaudeAccount(target.id)
        } else {
            sendNotification(
                title: "Claude usage is low",
                subtitle: "\(active.title) \(activeLevel)% -> \(target.title) \(targetLevel)%",
                body: "Switch Claude Code to \(target.title)?",
                categoryIdentifier: autoSwitchNotificationCategory,
                userInfo: ["claudeProfileID": target.id]
            )
        }
    }
}
