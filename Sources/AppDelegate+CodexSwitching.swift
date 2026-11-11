import AppKit
import Foundation

extension AppDelegate {
    func confirmSwitchPreview(for account: CodexAccount) -> Bool {
        let alert = NSAlert()
        alert.messageText = "Switch to \(preferences.displayLabel(for: account))?"
        alert.informativeText = "5H \(remainingPercentText( account.fiveHourRemaining)) left · Weekly \(remainingPercentText( account.weeklyRemaining)) left\n\nCodex will relaunch after switching."
        alert.addButton(withTitle: "Switch")
        alert.addButton(withTitle: "Cancel")
        return alert.runAbovePanel() == .alertFirstButtonReturn
    }

    func switchTo(query: String, allowAutoResume: Bool = false) {
        guard !isSwitching else { return }
        clearArmedSwitch()
        let target = accounts.first(where: { $0.email == query || $0.selector == query })
        if let target, target.needsLogin {
            showAlert(
                title: "Account needs login",
                message: "Account \(preferences.displayLabel(for: target)) has an expired Codex session. Re-login it with Add Account with Device Code, then refresh."
            )
            refreshAccounts(force: true)
            return
        }
        if let target, !target.isActive, !allowAutoResume, !preferences.confirmBeforeSwitching, !confirmSwitchPreview(for: target) {
            return
        }
        isSwitching = true
        let previous = accounts.first(where: { $0.isActive })
        let automatic = allowAutoResume
        let switchStatusAnimationGeneration = beginStatusAnimation(title: "Switching")
        refreshAccountPanelContentIfVisible()

        DispatchQueue.global(qos: .userInitiated).async { [self] in
            if let syncError = self.codexAuthStore.syncActiveAuthSnapshot() {
                DispatchQueue.main.async {
                    self.isSwitching = false
                    self.endStatusAnimation()
                    self.updateStatusTitle()
                    self.showAlert(title: "Could not save active token", message: syncError)
                    self.refreshAccounts(force: true)
                }
                return
            }

            let switchResult = self.commands.runCodexAuth(["switch", query])
            if switchResult.status != 0 {
                DispatchQueue.main.async {
                    self.recordSwitch(from: previous, to: target, automatic: automatic, reason: "auth switch", result: "failed")
                    self.isSwitching = false
                    self.endStatusAnimation()
                    self.updateStatusTitle()
                    self.showAlert(title: "Switch failed", message: switchResult.output)
                    self.refreshAccounts(force: true)
                }
                return
            }

            let verification = self.commands.verifyActiveAccount(expectedEmail: target?.email ?? query)
            guard verification.status == 0 else {
                var rollbackMessage = "Verification failed: \(verification.output)"
                if let previous {
                    let rollback = self.commands.runCodexAuth(["switch", previous.email])
                    rollbackMessage += rollback.status == 0 ? "\nThe previous account was restored." : "\nRollback also failed: \(rollback.output)"
                }
                DispatchQueue.main.async {
                    self.recordSwitch(from: previous, to: target, automatic: automatic, reason: "verification", result: "rolled back")
                    self.isSwitching = false
                    self.endStatusAnimation()
                    self.updateStatusTitle()
                    self.showAlert(title: "Switch could not be verified", message: rollbackMessage)
                    self.refreshAccounts(force: true)
                }
                return
            }

            DispatchQueue.main.sync {
                self.isSwitching = false
                self.refreshAccounts(force: true, refreshResets: false)
            }

            let restartResult = self.restartCodexApp()
            if restartResult.status == 0, allowAutoResume, self.preferences.autoResumeMode != .off {
                // The relaunch now returns as soon as ChatGPT is up; give its window a
                // moment to finish loading before an automatic resume pastes into it.
                Thread.sleep(forTimeInterval: 3)
            }
            DispatchQueue.main.async {
                if restartResult.status != 0 {
                    self.recordSwitch(from: previous, to: target, automatic: automatic, reason: "desktop relaunch", result: "account changed; relaunch failed")
                    self.showAlert(title: "Codex relaunch failed", message: restartResult.output)
                } else {
                    UserDefaults.standard.set(Date(), forKey: self.lastSwitchDateDefaultsKey)
                    self.recordSwitch(from: previous, to: target, automatic: automatic, reason: automatic ? "automatic best account" : "manual", result: "verified")
                    if allowAutoResume {
                        self.handleAutoResumeAfterSwitch(to: target)
                    }
                }
                self.refreshAccounts(force: true, refreshResets: false)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                    guard let self, !self.isSwitching else { return }
                    self.endStatusAnimation(expectedGeneration: switchStatusAnimationGeneration)
                    self.updateStatusTitle()
                }
            }
        }
    }

    func checkUsageReminder() {
        guard preferences.remindersEnabled, let active = accounts.first(where: { $0.isActive }) else { return }
        checkUsageReminder(account: active, metric: "5hr", percent: active.fiveHourRemaining)
        checkUsageReminder(account: active, metric: "Weekly", percent: active.weeklyRemaining)
    }

    func checkUsageReminder(account: CodexAccount, metric: String, percent: Int?) {
        guard let percent else { return }
        let threshold = preferences.reminderThreshold
        let key = "\(account.email)|\(metric)|\(threshold)"
        if percent <= threshold {
            guard !notifiedLowUsageKeys.contains(key) else { return }
            notifiedLowUsageKeys.insert(key)
            sendUsageReminder(account: account, metric: metric, percent: percent)
        } else {
            notifiedLowUsageKeys.remove(key)
        }
    }

    func checkAutoSwitch() {
        let mode = preferences.autoSwitchMode
        guard mode != .off,
              !isSwitching,
              Date().timeIntervalSince(UserDefaults.standard.object(forKey: lastSwitchDateDefaultsKey) as? Date ?? .distantPast) >= switchCooldown,
              accounts.count > 1,
              let active = accounts.first(where: { $0.isActive }),
              let activeFiveHour = active.fiveHourRemaining,
              let target = bestAutoSwitchTarget(excluding: active.email) else {
            return
        }
        if preferences.protectFrontmostCodex, codexIsFrontmost() {
            return
        }
        switch mode {
        case .off:
            return
        case .ask, .threshold:
            guard activeFiveHour <= preferences.autoSwitchThreshold else { return }
        case .zero:
            guard activeFiveHour <= 0 else { return }
        }

        let key = "\(active.email)|\(target.email)|\(preferences.autoSwitchThreshold)|\(mode.rawValue)"
        guard !notifiedAutoSwitchPauseKeys.contains(key) else { return }
        notifiedAutoSwitchPauseKeys.insert(key)
        if mode == .ask || mode == .zero {
            sendAutoSwitchPrompt(active: active, target: target, activeFiveHour: activeFiveHour)
        } else {
            switchTo(query: target.email, allowAutoResume: true)
        }
    }

    func bestAutoSwitchTarget(excluding activeEmail: String) -> CodexAccount? {
        accounts
            .filter { $0.email != activeEmail }
            .filter { ($0.fiveHourRemaining ?? -1) > preferences.autoSwitchThreshold }
            .filter { !$0.needsLogin }
            .sorted { accountScore($0) > accountScore($1) }
            .first
    }

    func accountScore(_ account: CodexAccount) -> Int {
        let fiveHour = account.fiveHourRemaining ?? -100
        let weekly = account.weeklyRemaining ?? -100
        let resets = resetCreditsByEmail[account.email]?.displayCount ?? 0
        return (fiveHour * 3) + weekly + min(resets, 5) * 4
    }

    func sendAutoSwitchPrompt(active: CodexAccount, target: CodexAccount, activeFiveHour: Int) {
        sendNotification(
            title: "Codex usage is low",
            subtitle: "\(toolbarLabel(for: active)) \(activeFiveHour)% -> \(toolbarLabel(for: target)) \(remainingPercentText( target.fiveHourRemaining))",
            body: "Switch to \(target.email) and relaunch Codex?",
            categoryIdentifier: autoSwitchNotificationCategory,
            userInfo: ["targetEmail": target.email]
        )
    }

    func sendUsageReminder(account: CodexAccount, metric: String, percent: Int, reportResult: Bool = false) {
        let label = preferences.displayLabel(for: account)
        sendNotification(
            title: "Codex usage is low",
            subtitle: "\(label) · \(metric) \(percent)%",
            body: preferences.autoSwitchEnabled
                ? "\(account.email) is at or below \(preferences.reminderThreshold)%. Auto-switch is enabled at \(preferences.autoSwitchThreshold)% for 5hr usage."
                : "\(account.email) is at or below \(preferences.reminderThreshold)%. Switch to another saved account from the menu bar when you are ready.",
            reportResult: reportResult
        )
    }

    func runAccountMaintenance(title: String, args: [String], restartAfterSuccess: Bool = false) {
        guard !isSwitching else { return }
        isSwitching = true
        statusItem.button?.image = nil
        statusItem.button?.imagePosition = .noImage
        statusItem.button?.attributedTitle = NSAttributedString(string: "")
        statusItem.button?.title = title
        currentStatusTitleKey = ""
        refreshUI()

        DispatchQueue.global(qos: .userInitiated).async { [self] in
            let result = self.commands.runCodexAuth(args)
            var restartResult: CommandResult?
            if result.status == 0, restartAfterSuccess {
                restartResult = self.restartCodexApp()
            }
            DispatchQueue.main.async {
                self.isSwitching = false
                if result.status != 0 {
                    self.showAlert(title: "\(title) failed", message: result.output)
                } else if let restartResult, restartResult.status != 0 {
                    self.showAlert(title: "Codex relaunch failed", message: restartResult.output)
                }
                self.refreshAccounts(force: true)
            }
        }
    }
}
