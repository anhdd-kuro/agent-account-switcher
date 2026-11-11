import AppKit
import Foundation

extension AppDelegate {
    func handleSettingsPanelAction(_ action: SettingsPanelAction) {
        switch action {
        case .usageView:
            clearArmedSwitch()
            accountPanelMode = .usage
            claude.refreshIfNeeded(maximumAge: 30)
        case .addClaudeAccount:
            signInToClaude(email: nil)
        case .analyticsView:
            clearArmedSwitch()
            accountPanelMode = .analytics
            if !demoMode { analytics.refresh() }
        case .settingsView:
            accountPanelMode = .settings
        case .routeBView:
            accountPanelMode = .routeB
        case .resetCreditsView:
            accountPanelMode = .resets
            refreshResetCreditsIfNeeded(force: false)
        case .addAccount:
            addAccountBrowser()
        case .addDeviceAccount:
            addAccountDeviceCode()
        case .editLabels:
            showAccountDisplayLabelsDialog()
        case .removeAccount:
            showRemoveAccountDialog()
        case .usageWeekly:
            preferences.usageMode = .weekly
            refreshUI()
        case .usageFiveHour:
            preferences.usageMode = .fiveHour
            refreshUI()
        case .claudeUsageWeekly:
            preferences.claudeUsageMode = .weekly
            refreshUI()
        case .claudeUsageFiveHour:
            preferences.claudeUsageMode = .fiveHour
            refreshUI()
        case .usageBoth:
            preferences.usageMode = .both
            refreshUI()
        case .usageOff:
            preferences.usageMode = .off
            refreshUI()
        case .claudeUsageBoth:
            preferences.claudeUsageMode = .both
            refreshUI()
        case .claudeUsageOff:
            preferences.claudeUsageMode = .off
            refreshUI()
        case .cursorBarOff, .cursorBarAuto, .cursorBarApi, .cursorBarBoth:
            preferences.cursorLane = action == .cursorBarAuto ? .auto : action == .cursorBarApi ? .api : action == .cursorBarBoth ? .both : .off
            refreshUI()
        case .testCelebration:
            Celebration.celebrate([WatchedLimit(key: "test", title: "Claude 5h", remaining: 100)], anchor: statusItem.button?.window?.frame)
        case .toggleReopenOnSameDesktop:
            SpaceRestorer.isEnabled.toggle()
            refreshUI()
        case .toggleToastOnReset:
            Celebration.toastEnabled.toggle()
            refreshUI()
        case .toggleConfettiOnReset:
            Celebration.confettiEnabled.toggle()
            refreshUI()
        case .styleDetailed:
            preferences.toolbarDisplayStyle = .detailed
            refreshUI()
        case .styleCompact:
            preferences.toolbarDisplayStyle = .compact
            refreshUI()
        case .toggleLaunchAtLogin:
            toggleLaunchAtLogin()
        case .toggleUsageReminder:
            toggleUsageReminder()
        case .editUsageReminder:
            showUsageReminderDialog()
        case .toggleAutoSwitch:
            toggleAutoSwitch()
        case .editAutoSwitch:
            showAutoSwitchDialog()
        case .editAutoResume:
            showAutoResumeDialog()
        case .toggleConfirmSwitch:
            toggleConfirmBeforeSwitching()
        case .toggleProtectCodex:
            toggleProtectFrontmostCodex()
        case .editRefresh:
            showRefreshSettingsDialog()
        case .forceRefresh:
            refreshNow()
        case .checkUpdates:
            checkForUpdates(showResult: true)
        case .cleanBackups:
            cleanAccountBackups()
        case .diagnostics:
            showDiagnostics()
        case .quit:
            NSApp.terminate(nil)
        }
        if accountPanel?.isVisible == true {
            refreshAccountPanelContentIfVisible()
        }
    }

    func selectRouteBProfile(_ profileID: String) {
        guard routeBProviderProfiles.contains(where: { $0.id == profileID }) else { return }
        UserDefaults.standard.set(profileID, forKey: selectedRouteBProfileDefaultsKey)
        if accountPanel?.isVisible == true {
            refreshAccountPanelContentIfVisible()
        }
    }

    func accountPopup(width: CGFloat) -> NSPopUpButton {
        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: width, height: 26), pullsDown: false)
        for account in toolbarAccounts() {
            addPopupItem(
                to: popup,
                title: "\(toolbarLabel(for: account))  \(preferences.compactEmail(account.email))",
                representedObject: account.email
            )
        }
        if let active = accounts.first(where: { $0.isActive }) {
            popup.selectItem(withTitle: "\(toolbarLabel(for: active))  \(preferences.compactEmail(active.email))")
        }
        return popup
    }

    func refreshIntervalPopup(width: CGFloat, values: [Int], selected: Int) -> NSPopUpButton {
        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: width, height: 26), pullsDown: false)
        for value in values {
            addPopupItem(to: popup, title: "\(value)s", representedObject: value)
        }
        popup.selectItem(withTitle: "\(selected)s")
        return popup
    }

    func addPopupItem(to popup: NSPopUpButton, title: String, representedObject: Any) {
        popup.addItem(withTitle: title)
        popup.lastItem?.representedObject = representedObject
    }

    func selectPopupItem(_ popup: NSPopUpButton, representedObject: Any) {
        for item in popup.itemArray where String(describing: item.representedObject ?? "") == String(describing: representedObject) {
            popup.select(item)
            return
        }
    }

    func selectedAccountEmail(from popup: NSPopUpButton) -> String? {
        popup.selectedItem?.representedObject as? String
    }

    func settingsRow(label: String, control: NSView) -> NSView {
        let labelView = NSTextField(labelWithString: label)
        labelView.frame = NSRect(x: 0, y: 0, width: 110, height: 24)
        let row = NSStackView(views: [labelView, control])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 10
        row.frame = NSRect(x: 0, y: 0, width: 250, height: 26)
        return row
    }

    @objc func showAccountDisplayLabelsDialog() {
        showAccountDisplayLabelsDialogForAccount(nil)
    }

    func showAccountDisplayLabelsDialogForAccount(_ preferredEmail: String?) {
        guard !accounts.isEmpty else { return }
        let popup = accountPopup(width: 300)
        if let preferredEmail,
           let preferredAccount = accounts.first(where: { $0.email.caseInsensitiveCompare(preferredEmail) == .orderedSame }) {
            popup.selectItem(withTitle: "\(toolbarLabel(for: preferredAccount))  \(preferences.compactEmail(preferredAccount.email))")
        }
        accountLabelDialogPopup = popup
        let selectedEmail = selectedAccountEmail(from: popup)
        let selectedAccount = selectedEmail.flatMap { email in accounts.first(where: { $0.email == email }) }
        popup.target = self
        popup.action = #selector(accountLabelPopupChanged(_:))

        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        accountLabelDialogField = field
        if let selectedAccount {
            field.stringValue = preferences.displayLabel(for: selectedAccount)
            field.placeholderString = preferences.defaultLabel(forEmail: selectedAccount.email)
        } else {
            field.placeholderString = "A"
        }

        let stack = NSStackView(views: [popup, field])
        stack.orientation = .vertical
        stack.spacing = 8
        stack.frame = NSRect(x: 0, y: 0, width: 300, height: 58)

        let alert = NSAlert()
        alert.messageText = "Account display label"
        alert.informativeText = "Choose an account and set a label up to four characters. Leave it blank to clear the custom label."
        alert.accessoryView = stack
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Clear")
        alert.addButton(withTitle: "Cancel")

        let response = alert.runAbovePanel()
        guard let email = selectedAccountEmail(from: popup) else { return }
        if response == .alertFirstButtonReturn {
            let value = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if value.isEmpty {
                preferences.clearCustomLabel(forEmail: email)
            } else {
                preferences.setCustomLabel(preferences.limitedLabel(value), forEmail: email)
            }
            refreshUI()
        } else if response == .alertSecondButtonReturn {
            preferences.clearCustomLabel(forEmail: email)
            refreshUI()
        }
        accountLabelDialogField = nil
        accountLabelDialogPopup = nil
    }

    @objc func accountLabelPopupChanged(_ sender: NSPopUpButton) {
        guard let field = accountLabelDialogField,
              let email = selectedAccountEmail(from: sender),
              let account = accounts.first(where: { $0.email == email }) else { return }
        field.stringValue = preferences.displayLabel(for: account)
        field.placeholderString = preferences.defaultLabel(forEmail: account.email)
    }

    @objc func showRemoveAccountDialog() {
        guard !accounts.isEmpty else { return }
        let popup = accountPopup(width: 320)
        let alert = NSAlert()
        alert.messageText = "Remove account?"
        alert.informativeText = "Remove the selected account from codex-auth switching."
        alert.alertStyle = .warning
        alert.accessoryView = popup
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Cancel")

        if alert.runAbovePanel() == .alertFirstButtonReturn,
           let email = selectedAccountEmail(from: popup) {
            runAccountMaintenance(title: "Removing account", args: ["remove", email])
        }
    }

    func confirmLogoutAccount(_ email: String) {
        guard let account = accounts.first(where: { $0.email == email }) else { return }

        let alert = NSAlert()
        alert.messageText = "Log out of this account?"
        alert.informativeText = "This removes \(account.email) from AI Account Switcher on this Mac. You can add it again later by signing in."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Log out")
        alert.addButton(withTitle: "Cancel")

        if alert.runAbovePanel() == .alertFirstButtonReturn {
            runAccountMaintenance(title: "Logging out", args: ["remove", email])
        }
    }

    @objc func showUsageReminderDialog() {
        let notifyCheck = NSButton(checkboxWithTitle: "Notify on low usage", target: nil, action: nil)
        notifyCheck.state = preferences.remindersEnabled ? .on : .off

        let notifyField = NSTextField(frame: NSRect(x: 0, y: 0, width: 70, height: 24))
        notifyField.stringValue = "\(preferences.reminderThreshold)"

        let notifyRow = settingsRow(label: "Notify %", control: notifyField)
        let stack = NSStackView(views: [notifyCheck, notifyRow])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.frame = NSRect(x: 0, y: 0, width: 320, height: 58)

        let alert = NSAlert()
        alert.messageText = "Usage reminder"
        alert.accessoryView = stack
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Test")
        alert.addButton(withTitle: "Cancel")

        let response = alert.runAbovePanel()
        if response == .alertSecondButtonReturn {
            testUsageReminder()
            return
        }
        guard response == .alertFirstButtonReturn else { return }

        let notifyValue = Int(notifyField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines))
        guard let notifyValue, (1...99).contains(notifyValue) else {
            showAlert(title: "Invalid percentage", message: "Enter a number from 1 to 99.")
            return
        }

        preferences.remindersEnabled = notifyCheck.state == .on
        preferences.reminderThreshold = notifyValue
        if preferences.remindersEnabled {
            configureNotifications()
        }
        checkUsageReminder()
        refreshUI()
    }

    @objc func showAutoSwitchDialog() {
        let modePopup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 220, height: 26), pullsDown: false)
        addPopupItem(to: modePopup, title: "Off", representedObject: AutoSwitchMode.off.rawValue)
        addPopupItem(to: modePopup, title: "Ask at threshold", representedObject: AutoSwitchMode.ask.rawValue)
        addPopupItem(to: modePopup, title: "Switch at threshold", representedObject: AutoSwitchMode.threshold.rawValue)
        addPopupItem(to: modePopup, title: "Ask at 0%", representedObject: AutoSwitchMode.zero.rawValue)
        selectPopupItem(modePopup, representedObject: preferences.autoSwitchMode.rawValue)

        let thresholdField = NSTextField(frame: NSRect(x: 0, y: 0, width: 70, height: 24))
        thresholdField.stringValue = "\(preferences.autoSwitchThreshold)"

        let protectCheck = NSButton(checkboxWithTitle: "Pause while Codex is frontmost", target: nil, action: nil)
        protectCheck.state = preferences.protectFrontmostCodex ? .on : .off

        let stack = NSStackView(views: [
            settingsRow(label: "Mode", control: modePopup),
            settingsRow(label: "Switch %", control: thresholdField),
            protectCheck
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.frame = NSRect(x: 0, y: 0, width: 340, height: 96)

        let alert = NSAlert()
        alert.messageText = "Auto switch"
        alert.informativeText = "Choose whether the switcher asks first or changes accounts automatically when 5-hour usage is low. At 0%, it asks so Codex can finish any running task."
        alert.accessoryView = stack
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")

        guard alert.runAbovePanel() == .alertFirstButtonReturn else { return }
        let switchValue = Int(thresholdField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines))
        guard let switchValue, (1...99).contains(switchValue) else {
            showAlert(title: "Invalid percentage", message: "Enter a number from 1 to 99.")
            return
        }
        if let rawValue = modePopup.selectedItem?.representedObject as? String,
           let mode = AutoSwitchMode(rawValue: rawValue) {
            preferences.autoSwitchMode = mode
        }
        preferences.autoSwitchThreshold = switchValue
        preferences.protectFrontmostCodex = protectCheck.state == .on
        notifiedAutoSwitchPauseKeys.removeAll()
        if preferences.autoSwitchEnabled {
            configureNotifications()
            checkAutoSwitch()
        }
        refreshUI()
    }

    @objc func showAutoResumeDialog() {
        let modePopup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 240, height: 26), pullsDown: false)
        addPopupItem(to: modePopup, title: "Off", representedObject: AutoResumeMode.off.rawValue)
        addPopupItem(to: modePopup, title: "Ask first", representedObject: AutoResumeMode.ask.rawValue)
        addPopupItem(to: modePopup, title: "Auto after 5s idle", representedObject: AutoResumeMode.idle5.rawValue)
        addPopupItem(to: modePopup, title: "Auto after 10s idle", representedObject: AutoResumeMode.idle10.rawValue)
        addPopupItem(to: modePopup, title: "Always auto-resume", representedObject: AutoResumeMode.always.rawValue)
        selectPopupItem(modePopup, representedObject: preferences.autoResumeMode.rawValue)

        let promptField = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        promptField.stringValue = preferences.autoResumePrompt

        let stack = NSStackView(views: [
            settingsRow(label: "Mode", control: modePopup),
            settingsRow(label: "Prompt", control: promptField)
        ])
        stack.orientation = .vertical
        stack.spacing = 8
        stack.frame = NSRect(x: 0, y: 0, width: 380, height: 62)

        let alert = NSAlert()
        alert.messageText = "Auto resume"
        alert.informativeText = "After a successful account switch, the app can copy or paste a short prompt into Codex. Automatic paste requires Accessibility permission and only runs when Codex is frontmost."
        alert.accessoryView = stack
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")

        guard alert.runAbovePanel() == .alertFirstButtonReturn else { return }
        if let rawValue = modePopup.selectedItem?.representedObject as? String,
           let mode = AutoResumeMode(rawValue: rawValue) {
            preferences.autoResumeMode = mode
        }
        preferences.autoResumePrompt = promptField.stringValue
        if preferences.autoResumeMode != .off {
            configureNotifications()
        }
        refreshUI()
    }

    @objc func showRefreshSettingsDialog() {
        let activePopup = refreshIntervalPopup(width: 120, values: [5, 15, 30, 60], selected: preferences.activeRefreshInterval)
        let idlePopup = refreshIntervalPopup(width: 120, values: [15, 30, 60], selected: preferences.idleRefreshInterval)
        let stack = NSStackView(views: [
            settingsRow(label: "Codex active", control: activePopup),
            settingsRow(label: "Idle", control: idlePopup)
        ])
        stack.orientation = .vertical
        stack.spacing = 8
        stack.frame = NSRect(x: 0, y: 0, width: 260, height: 62)

        let alert = NSAlert()
        alert.messageText = "Refresh settings"
        alert.accessoryView = stack
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")

        if alert.runAbovePanel() == .alertFirstButtonReturn,
           let active = activePopup.selectedItem?.representedObject as? Int,
           let idle = idlePopup.selectedItem?.representedObject as? Int {
            preferences.activeRefreshInterval = active
            preferences.idleRefreshInterval = idle
            refreshUI()
        }
    }

    @objc func addAccountBrowser() {
        runAccountMaintenance(title: "Adding account", args: ["login"], restartAfterSuccess: true)
    }

    @objc func addAccountDeviceCode() {
        let path = commands.codexAuthPath() ?? "codex-auth"
        guard let restartPath = Bundle.main.executableURL?.path else { return }
        let setupCommand = commands.shellEnvironmentSetupCommand()
        let script = """
        tell application "Terminal"
          activate
          do script "\(setupCommand); \(CodexCommands.shellEscaped(path)) login --device-auth && \(CodexCommands.shellEscaped(restartPath)) --restart-desktop; echo; echo 'Codex account login finished and Codex App was relaunched. You can close this window.'"
        end tell
        """
        let result = commands.run("/usr/bin/osascript", ["-e", script])
        if result.status != 0 {
            showAlert(title: "Device-code login failed", message: result.output)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            self?.refreshAccounts(force: true)
        }
    }

    @objc func toggleUsageReminder() {
        preferences.remindersEnabled.toggle()
        if preferences.remindersEnabled {
            configureNotifications()
            checkUsageReminder()
        } else {
            notifiedLowUsageKeys.removeAll()
        }
        refreshUI()
    }

    @objc func toggleAutoSwitch() {
        preferences.autoSwitchEnabled.toggle()
        if preferences.autoSwitchEnabled {
            configureNotifications()
            checkAutoSwitch()
        }
        refreshUI()
    }

    @objc func toggleConfirmBeforeSwitching() {
        preferences.confirmBeforeSwitching.toggle()
        clearArmedSwitch()
        refreshUI()
    }

    @objc func toggleProtectFrontmostCodex() {
        preferences.protectFrontmostCodex.toggle()
        refreshUI()
    }

    @objc func testUsageReminder() {
        if let active = accounts.first(where: { $0.isActive }) {
            sendUsageReminder(account: active, metric: "5hr", percent: active.fiveHourRemaining ?? preferences.reminderThreshold, reportResult: true)
        } else {
            sendNotification(
                title: "Codex usage reminder",
                subtitle: "No active account",
                body: "Open the switcher after adding a Codex account.",
                reportResult: true
            )
        }
    }

    @objc func cleanAccountBackups() {
        runAccountMaintenance(title: "Cleaning backups", args: ["clean"])
    }

    @objc func toggleLaunchAtLogin() {
        do {
            if launchAtLoginEnabled() {
                try removeLaunchAgent()
            } else {
                try installLaunchAgent()
            }
        } catch {
            showAlert(title: "Launch at Login failed", message: error.localizedDescription)
        }
        refreshUI()
    }
}
