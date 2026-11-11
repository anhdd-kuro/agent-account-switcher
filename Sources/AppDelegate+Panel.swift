import AppKit
import Foundation

extension AppDelegate {
    func installPanelDismissHandlers() {
        didResignActiveObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: NSApp,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            if self.accountPanel?.isVisible == true, self.mouseIsOverStatusButton() {
                self.suppressStatusToggleOpenUntil = Date().addingTimeInterval(0.5)
            }
            self.closeAccountPanel()
        }

        localClickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] event in
            guard let self else { return event }
            if self.accountPanel?.isVisible == true, self.mouseIsOverStatusButton() {
                self.suppressStatusToggleOpenUntil = Date().addingTimeInterval(0.5)
                self.closeAccountPanel()
            }
            return event
        }

        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self else { return }
                if self.accountPanel?.isVisible == true, self.mouseIsOverStatusButton() {
                    self.suppressStatusToggleOpenUntil = Date().addingTimeInterval(0.5)
                }
                self.closeAccountPanel()
            }
        }
    }

    @objc func toggleAccountPanel() {
        if accountPanel?.isVisible == true {
            closeAccountPanel()
            return
        }
        if let suppressUntil = suppressStatusToggleOpenUntil, Date() < suppressUntil {
            suppressStatusToggleOpenUntil = nil
            return
        }
        showAccountPanel()
    }

    func mouseIsOverStatusButton() -> Bool {
        guard let button = statusItem.button,
              let window = button.window else {
            return false
        }
        let buttonFrameInWindow = button.convert(button.bounds, to: nil)
        let buttonFrame = window.convertToScreen(buttonFrameInWindow).insetBy(dx: -6, dy: -6)
        return buttonFrame.contains(NSEvent.mouseLocation)
    }

    func showAccountPanel() {
        accountPanelMode = .usage
        claude.refreshIfNeeded(maximumAge: 30)
        presentPanel(mode: .usage)
        let isStale = lastUpdatedAt.map { Date().timeIntervalSince($0) > 10 } ?? true
        if isStale {
            refreshAccounts(force: true, refreshResets: false)
        }
    }

    func showSettingsPanel() { presentPanel(mode: .settings) }

    func showRouteBPanel() { presentPanel(mode: .routeB) }

    func presentPanel(mode: AccountPanelMode) {
        accountPanelMode = mode
        let panel = accountPanel ?? makeAccountPanel()
        accountPanel = panel
        refreshAccountPanelContent(force: true)
        refreshNotificationHealth(rebuildVisiblePanel: true)
        positionAccountPanel()
        NSApp.activate(ignoringOtherApps: true)
        panel.orderFrontRegardless()
        panel.makeKey()
    }

    func makeAccountPanel() -> NSPanel {
        let panel = AccountFloatingPanel(
            contentRect: NSRect(origin: .zero, size: currentAccountPanelSize()),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .transient]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        return panel
    }

    func currentAccountPanelSize() -> NSSize {
        if let size = accountPanel?.contentViewController?.view.frame.size, size.width > 0, size.height > 0 {
            return size
        }
        return AccountSwitcherPanelView.preferredSize(mode: accountPanelMode, accountCount: toolbarAccounts().count)
    }

    func refreshAccountPanelContent(force: Bool = false) {
        let state = AccountPanelState(
            accounts: toolbarAccounts(), activeAccount: accounts.first(where: \.isActive), mode: accountPanelMode,
            lastUpdatedText: lastUpdatedText(), lastError: lastError, isSwitching: isSwitching,
            launchAtLoginEnabled: launchAtLoginEnabled(), remindersEnabled: preferences.remindersEnabled,
            reminderThreshold: preferences.reminderThreshold, autoSwitchThreshold: preferences.autoSwitchThreshold,
            autoSwitchMode: preferences.autoSwitchMode, autoResumeMode: preferences.autoResumeMode,
            confirmBeforeSwitching: demoScenario == "four" ? true : preferences.confirmBeforeSwitching,
            armedSwitchEmail: demoScenario == "four" ? "creative@example.com" : armedSwitchEmail,
            resetCreditsByEmail: resetCreditsByEmail, healthStatuses: healthStatusRows(),
            routeBProfiles: routeBProviderProfiles,
            selectedRouteBProfileID: UserDefaults.standard.string(forKey: selectedRouteBProfileDefaultsKey),
            usageMode: preferences.usageMode, claudeUsageMode: preferences.claudeUsageMode, toolbarDisplayStyle: preferences.toolbarDisplayStyle,
            activeRefreshInterval: preferences.activeRefreshInterval, idleRefreshInterval: preferences.idleRefreshInterval,
            accountLabels: Dictionary(uniqueKeysWithValues: accounts.map { ($0.email, toolbarLabel(for: $0)) }),
            claude: ClaudePanelState(accounts: claude.accounts, lastError: claude.lastError, updatedText: claude.updatedText,
                                     isSwitching: claude.isSwitching, isClaimingReset: claude.isClaimingReset),
            codexUsageByEmail: directUsageSnapshotsByEmail, cursor: cursor.state, cursorLane: preferences.cursorLane,
            menuBarPreview: menuBarUsageParts().map(\.part),
            analytics: AnalyticsPanelState(snapshot: analytics.snapshot, status: analytics.status, period: analytics.period),
            toastOnReset: Celebration.toastEnabled, confettiOnReset: Celebration.confettiEnabled,
            reopenOnSameDesktop: SpaceRestorer.isEnabled
        )
        if !force, state == lastPanelState, accountPanel?.contentViewController != nil { return }
        lastPanelState = state
        let actions = AccountPanelActions(
            switchAccount: { [weak self] in self?.handlePanelSwitchRequest($0) },
            logoutAccount: { [weak self] in self?.confirmLogoutAccount($0) },
            refresh: { [weak self] in self?.refreshNow() },
            checkUpdates: { [weak self] in self?.checkForUpdates(showResult: true) },
            editAccountLabel: { [weak self] in self?.showAccountDisplayLabelsDialogForAccount($0) },
            showResetCredits: { [weak self] in self?.showResetCreditsPanel() },
            redeemResetCredit: { [weak self] in self?.redeemResetCreditFromPanel(email: $0, creditID: $1) },
            selectRouteBProfile: { [weak self] in self?.selectRouteBProfile($0) },
            performSettingsAction: { [weak self] in self?.handleSettingsPanelAction($0) },
            close: { NSApp.terminate(nil) },
            claude: ClaudePanelActions(
                switchAccount: { [weak self] in self?.switchClaudeAccount($0) },
                signIn: { [weak self] in self?.signInToClaude(email: $0) },
                remove: { [weak self] in self?.confirmRemoveClaudeAccount($0) },
                useReset: { [weak self] in self?.confirmClaudeReset(profileID: $0, grantID: $1) }
            ),
            analytics: AnalyticsPanelActions(selectPeriod: { [weak self] in self?.analytics.select($0) },
                                            refresh: { [weak self] in self?.analytics.refresh() })
        )
        let panel = AccountSwitcherPanelView(state: state, actions: actions)
        let controller = NSViewController()
        controller.view = panel
        accountPanel?.contentViewController = controller
        accountPanel?.setContentSize(panel.frame.size)
        if accountPanel?.isVisible == true { positionAccountPanel() }
    }

    func handlePanelSwitchRequest(_ email: String) {
        guard !isSwitching else { return }
        if preferences.confirmBeforeSwitching {
            if armedSwitchEmail == email {
                clearArmedSwitch()
                closeAccountPanel()
                switchTo(query: email)
            } else {
                armSwitchConfirmation(for: email)
            }
            return
        }

        closeAccountPanel()
        switchTo(query: email)
    }

    func armSwitchConfirmation(for email: String) {
        armedSwitchClearWorkItem?.cancel()
        armedSwitchEmail = email
        refreshAccountPanelContentIfVisible()

        let workItem = DispatchWorkItem { [weak self] in
            guard let self, self.armedSwitchEmail == email else { return }
            self.armedSwitchEmail = nil
            if self.accountPanel?.isVisible == true {
                self.refreshAccountPanelContentIfVisible()
            }
        }
        armedSwitchClearWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 4, execute: workItem)
    }

    func clearArmedSwitch() {
        armedSwitchClearWorkItem?.cancel()
        armedSwitchClearWorkItem = nil
        armedSwitchEmail = nil
    }

    func healthStatusRows() -> [HealthStatus] {
        // Never resolve codex-auth here: this runs on the main thread for every panel build.
        let codexAuthOK = commands.cachedPath != nil
        if !codexAuthOK {
            resolveCodexAuthPathInBackground()
        }
        let authStillChecking = !codexAuthOK && !codexAuthResolveFinished
        let codexAppOK = FileManager.default.fileExists(atPath: DesktopApplication.path)
        return [
            HealthStatus(
                title: "Auth",
                value: codexAuthOK ? "OK" : (authStillChecking ? "Checking" : "Missing"),
                color: codexAuthOK ? .systemGreen : (authStillChecking ? .systemOrange : .systemRed)
            ),
            HealthStatus(title: "Codex", value: codexAppOK ? "Found" : "Missing", color: codexAppOK ? .systemGreen : .systemRed),
            HealthStatus(title: "Mode", value: "ChatGPT", color: .systemGreen),
            HealthStatus(title: "Refresh", value: lastUpdatedText(), color: refreshHealthColor()),
            HealthStatus(title: "Notify", value: notificationHealthTitle, color: notificationHealthColor),
            HealthStatus(title: "Update", value: updateHealthTitle, color: updateHealthColor),
            HealthStatus(
                title: "Claude",
                value: ClaudeCLI.executable() == nil ? "No CLI" : (claude.active.map { !$0.needsLogin } == true ? "OK" : "Signed out"),
                color: ClaudeCLI.executable() != nil && claude.active.map({ !$0.needsLogin }) == true ? .systemGreen : .systemRed
            ),
            HealthStatus(title: "Usage", value: claude.updatedText, color: claude.accounts.contains { $0.usageError != nil } ? .systemOrange : .systemGreen)
        ]
    }

    func positionAccountPanel() {
        guard let panel = accountPanel else { return }

        guard let button = statusItem.button,
              let window = button.window,
              let screen = window.screen ?? NSScreen.main else {
            positionAccountPanelAtScreenFallback(panel)
            return
        }

        let buttonFrameInWindow = button.convert(button.bounds, to: nil)
        let buttonFrame = window.convertToScreen(buttonFrameInWindow)
        let visibleFrame = screen.visibleFrame
        let margin: CGFloat = 8
        let panelSize = currentAccountPanelSize()

        var x = buttonFrame.midX - panelSize.width / 2
        x = max(visibleFrame.minX + margin, min(x, visibleFrame.maxX - panelSize.width - margin))

        var y = buttonFrame.minY - panelSize.height - margin
        if y < visibleFrame.minY + margin {
            y = min(buttonFrame.maxY + margin, visibleFrame.maxY - panelSize.height - margin)
        }

        panel.setFrame(NSRect(x: x, y: y, width: panelSize.width, height: panelSize.height), display: true)
    }

    func positionAccountPanelAtScreenFallback(_ panel: NSPanel) {
        guard let screen = NSScreen.main else { return }
        let visibleFrame = screen.visibleFrame
        let margin: CGFloat = 12
        let panelSize = currentAccountPanelSize()
        let x = visibleFrame.maxX - panelSize.width - margin
        let y = visibleFrame.maxY - panelSize.height - margin
        panel.setFrame(NSRect(x: x, y: y, width: panelSize.width, height: panelSize.height), display: true)
    }

    func closeAccountPanel() {
        clearArmedSwitch()
        accountPanel?.orderOut(nil)
    }

    func refreshAccountPanelContentIfVisible() {
        guard accountPanel?.isVisible == true, !panelRefreshScheduled else { return }
        panelRefreshScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.panelRefreshScheduled = false
            guard self.accountPanel?.isVisible == true else { return }
            self.refreshAccountPanelContent()
        }
    }
}
