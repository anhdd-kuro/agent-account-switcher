import AppKit
import ApplicationServices
import Foundation
import Security
import UserNotifications

final class AccountFloatingPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    var limitResetWatcher = LimitResetWatcher()
    let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    var accountPanel: NSPanel?
    var accountPanelMode: AccountPanelMode = .usage
    let timerTickInterval: TimeInterval = 5
    let fiveHourMenuBarMigrationDefaultsKey = "fiveHourMenuBarMigrationV1"
    let selectedRouteBProfileDefaultsKey = "selectedRouteBProfileID"
    let apiModeActiveDefaultsKey = "apiModeActive"
    let apiTokenUsageService = "com.mohamedfuad.codexaccountswitcher.openai"
    let apiCodexKeyAccount = "codex-api-key"
    let apiUsageKeyAccount = "usage-api-key"
    let autoSwitchNotificationCategory = "AUTO_SWITCH_CONFIRM"
    let resumeNotificationCategory = "AUTO_RESUME_CONFIRM"
    let switchNowActionIdentifier = "SWITCH_NOW"
    let resumeNowActionIdentifier = "RESUME_NOW"
    let cancelResumeActionIdentifier = "CANCEL_RESUME"
    let autoResumeCodexReadyDelay: TimeInterval = 3.0
    let launchAgentIdentifier = "com.mohamedfuad.codexaccountswitcher"
    let switchHistoryDefaultsKey = "switchHistoryV1"
    let resetHistoryDefaultsKey = "resetHistoryV1"
    let lastSwitchDateDefaultsKey = "lastSuccessfulSwitchDate"
    let switchCooldown: TimeInterval = 90
    let resetCreditsRefreshInterval: TimeInterval = 300
    let directUsageRefreshInterval: TimeInterval = 30
    var refreshTimer: Timer?
    let preferences = AppPreferences()
    let commands = CodexCommands()
    var isResolvingCodexAuthPath = false
    var codexAuthResolveFinished = false
    var lastPanelState: AccountPanelState?
    var currentStatusTitleKey = ""
    var statusSpinnerFrame: Int?
    var accounts: [CodexAccount] = []
    var lastError: String?
    var lastUpdatedAt: Date?
    var lastRefreshStartedAt: Date?
    var lastResetCreditsRefreshAt: Date?
    var lastDirectUsageRefreshAt: Date?
    var isRefreshing = false
    var isRefreshingResetCredits = false
    var pendingForceRefresh = false
    var isSwitching = false
    var isRedeemingReset = false
    var resetStatusText: String?
    var directUsageSnapshotsByEmail: [String: DirectUsageSnapshot] = [:]
    var armedSwitchEmail: String?
    var armedSwitchClearWorkItem: DispatchWorkItem?
    var switchAnimationTimer: Timer?
    var switchAnimationFrame = 0
    var outsideClickMonitor: Any?
    var localClickMonitor: Any?
    var didResignActiveObserver: NSObjectProtocol?
    var suppressStatusToggleOpenUntil: Date?
    var panelRefreshScheduled = false
    var statusAnimationTitle = "Switching"
    var statusAnimationGeneration = 0
    var notifiedLowUsageKeys = Set<String>()
    var notifiedAutoSwitchPauseKeys = Set<String>()
    var pendingResumeWorkItems: [String: DispatchWorkItem] = [:]
    var savedClipboardString: String?
    weak var accountLabelDialogField: NSTextField?
    weak var accountLabelDialogPopup: NSPopUpButton?
    var notificationHealthTitle = "Checking"
    var notificationHealthColor = NSColor.systemOrange
    var updateHealthTitle = "Check"
    var updateHealthColor = NSColor.systemOrange
    var resetCreditsByEmail: [String: ResetCreditsSnapshot] = [:]
    let codexAuthStore = CodexAuthStore()
    lazy var codex = CodexClient(authStore: codexAuthStore)
    let claude = ClaudeController()
    let cursor = CursorUsageController()
    var cursorTimer: Timer?
    let analytics = AnalyticsController()
    var analyticsTimer: Timer?
    var notifiedClaudeKeys = Set<String>()
    var demoMode: Bool {
        ProcessInfo.processInfo.environment["CODEX_ACCOUNT_SWITCHER_DEMO"] == "1"
    }
    var showPanelOnLaunch: Bool {
        ProcessInfo.processInfo.environment["CODEX_ACCOUNT_SWITCHER_SHOW_PANEL"] == "1"
    }
    var showSettingsOnLaunch: Bool {
        ProcessInfo.processInfo.environment["CODEX_ACCOUNT_SWITCHER_SHOW_SETTINGS"] == "1"
    }
    var showRouteBOnLaunch: Bool {
        ProcessInfo.processInfo.environment["CODEX_ACCOUNT_SWITCHER_SHOW_ROUTE_B"] == "1"
    }
    var showResetsOnLaunch: Bool {
        ProcessInfo.processInfo.environment["CODEX_ACCOUNT_SWITCHER_SHOW_RESETS"] == "1"
    }

    func removeLegacyApiModeDataIfNeeded() {
        let migrationKey = "legacyApiModeRemovedV3"
        guard !UserDefaults.standard.bool(forKey: migrationKey) else { return }
        UserDefaults.standard.set(false, forKey: apiModeActiveDefaultsKey)
        deleteKeychainSecret(account: apiCodexKeyAccount)
        deleteKeychainSecret(account: apiUsageKeyAccount)
        UserDefaults.standard.set(true, forKey: migrationKey)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        if demoMode, let appearance = ProcessInfo.processInfo.environment["CODEX_ACCOUNT_SWITCHER_APPEARANCE"] {
            NSApp.appearance = NSAppearance(named: appearance == "light" ? .aqua : .darkAqua)
        }
        if ProcessInfo.processInfo.arguments.contains("--restart-desktop") {
            DispatchQueue.global(qos: .userInitiated).async {
                let result = self.restartCodexApp()
                FileHandle.standardOutput.write(Data((result.output + "\n").utf8))
                exit(result.status)
            }
            return
        }
        if ProcessInfo.processInfo.arguments.contains("--install-lifecycle-monitor") {
            do {
                try installLaunchAgent()
            } catch {
                NSLog("AI Account Switcher lifecycle monitor install failed: \(error.localizedDescription)")
            }
            NSApp.terminate(nil)
            return
        }
        migrateMenuBarUsageModeToFiveHourIfNeeded()
        removeLegacyApiModeDataIfNeeded()
        DispatchQueue.global(qos: .utility).async {
            let accountsDirectory = URL(fileURLWithPath: NSHomeDirectory())
                .appendingPathComponent(".codex/accounts", isDirectory: true)
            _ = AuthBackupPruner.prune(in: accountsDirectory, keepingPerAccount: 10)
        }
        _ = codex
        configureNotifications()
        configureStatusButton()
        claude.isEnabled = !demoMode
        claude.onChange = { [weak self] in
            self?.refreshUI()
            self?.checkClaudeAutomation()
        }
        claude.refresh()
        if !demoMode {
            analytics.onChange = { [weak self] in self?.refreshAccountPanelContentIfVisible() }
            cursor.onChange = { [weak self] in self?.refreshAccountPanelContentIfVisible() }
            cursor.refresh()
            cursorTimer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in self?.cursor.refresh() }
            analytics.refresh()
            analyticsTimer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in self?.analytics.refresh() }
        }
        refreshAccounts(force: true)
        if ProcessInfo.processInfo.environment["CODEX_ACCOUNT_SWITCHER_CELEBRATE"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                Celebration.celebrate([WatchedLimit(key: "demo", title: "Claude 5h", remaining: 100)], anchor: self?.statusItem.button?.window?.frame)
            }
        }
        if showPanelOnLaunch {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                self?.showAccountPanel()
            }
            if showResetsOnLaunch {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                    self?.showResetCreditsPanel()
                }
            } else if showRouteBOnLaunch {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                    self?.showRouteBPanel()
                }
            } else if showSettingsOnLaunch {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                    self?.showSettingsPanel()
                }
            }
        }
        let timer = Timer(timeInterval: timerTickInterval, repeats: true) { [weak self] _ in
            self?.refreshAccountsIfNeeded()
            self?.claude.refreshIfNeeded()
        }
        timer.tolerance = 1
        RunLoop.current.add(timer, forMode: .common)
        refreshTimer = timer

        installPanelDismissHandlers()
    }

    func migrateMenuBarUsageModeToFiveHourIfNeeded() {
        guard !UserDefaults.standard.bool(forKey: fiveHourMenuBarMigrationDefaultsKey) else { return }
        preferences.usageMode = .fiveHour
        UserDefaults.standard.set(true, forKey: fiveHourMenuBarMigrationDefaultsKey)
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let outsideClickMonitor {
            NSEvent.removeMonitor(outsideClickMonitor)
        }
        if let localClickMonitor {
            NSEvent.removeMonitor(localClickMonitor)
        }
        if let didResignActiveObserver {
            NotificationCenter.default.removeObserver(didResignActiveObserver)
        }
    }

    func refreshAccountsIfNeeded() {
        let interval = codexIsFrontmost() ? preferences.activeRefreshInterval : preferences.idleRefreshInterval
        if let lastRefreshStartedAt,
           Date().timeIntervalSince(lastRefreshStartedAt) < TimeInterval(interval) {
            return
        }
        refreshAccounts(force: false)
    }

    func refreshAccounts(force: Bool = false, refreshResets: Bool = true) {
        guard !isSwitching, !isRedeemingReset else { return }
        if demoMode {
            accounts = demoAccounts()
            resetCreditsByEmail = demoResetCreditsByEmail(for: accounts)
            lastError = nil
            lastUpdatedAt = Date()
            refreshUI()
            return
        }
        guard !isRefreshing else {
            if force {
                pendingForceRefresh = true
                refreshUI()
            }
            return
        }
        if !force, let lastRefreshStartedAt {
            let interval = codexIsFrontmost() ? preferences.activeRefreshInterval : preferences.idleRefreshInterval
            if Date().timeIntervalSince(lastRefreshStartedAt) < TimeInterval(interval) {
                return
            }
        }
        isRefreshing = true
        lastRefreshStartedAt = Date()
        let shouldRefreshResets = !isRefreshingResetCredits && RefreshPolicy.shouldRefresh(
            lastRefresh: lastResetCreditsRefreshAt,
            ttl: resetCreditsRefreshInterval,
            force: force && refreshResets
        )
        if shouldRefreshResets {
            isRefreshingResetCredits = true
        }
        let shouldRefreshDirectUsage = RefreshPolicy.shouldRefresh(
            lastRefresh: lastDirectUsageRefreshAt,
            ttl: directUsageRefreshInterval,
            force: force
        )
        if force {
            refreshUI()
        }
        DispatchQueue.global(qos: .utility).async {
            let (completedResult, parsed) = self.commands.listCodexAccounts()
            Task {
                async let resetTask: [String: ResetCreditsSnapshot] = completedResult.status == 0 && shouldRefreshResets
                    ? self.codex.fetchResetCredits(for: parsed) : [:]
                async let directUsageTask: [String: DirectUsageSnapshot] = completedResult.status == 0 && shouldRefreshDirectUsage
                    ? self.codex.fetchDirectUsage(for: parsed) : [:]
                let (resetResults, directUsageResults) = await (resetTask, directUsageTask)
                await MainActor.run {
                self.isRefreshing = false
                if shouldRefreshResets {
                    self.isRefreshingResetCredits = false
                }
                var newAccounts: [CodexAccount]
                let newError: String?
                if completedResult.status == 0 {
                    newAccounts = parsed
                    newError = parsed.isEmpty ? "No codex-auth accounts found." : nil
                } else {
                    newAccounts = []
                    newError = completedResult.output.trimmingCharacters(in: .whitespacesAndNewlines)
                }
                if completedResult.status == 0 {
                    let validEmails = Set(newAccounts.map(\.email))
                    self.directUsageSnapshotsByEmail = LastKnownGoodSnapshotPolicy.merged(
                        current: self.directUsageSnapshotsByEmail,
                        successful: directUsageResults,
                        validKeys: validEmails
                    )
                    if shouldRefreshDirectUsage {
                        self.lastDirectUsageRefreshAt = Date()
                    }
                }
                newAccounts = self.applyingDirectUsageSnapshots(to: newAccounts)

                let previousResetCredits = self.resetCreditsByEmail
                if completedResult.status == 0 && shouldRefreshResets {
                    self.resetCreditsByEmail = resetResults
                    self.lastResetCreditsRefreshAt = Date()
                }

                let stateChanged = newAccounts != self.accounts || newError != self.lastError || self.resetCreditsByEmail != previousResetCredits
                if completedResult.status == 0 {
                    self.lastUpdatedAt = Date()
                }
                if stateChanged || force || self.accountPanel?.isVisible == true {
                    self.accounts = newAccounts
                    self.lastError = newError
                    self.checkUsageReminder()
                    self.checkAutoSwitch()
                    self.refreshUI()
                }

                if self.pendingForceRefresh {
                    self.pendingForceRefresh = false
                    self.refreshAccounts(force: true, refreshResets: false)
                }
                }
            }
        }
    }

    func refreshUI() {
        celebrateLimitResets()
        if !isSwitching {
            if accounts.contains(where: { $0.isActive }) || claude.active != nil {
                updateStatusTitle()
            } else {
                clearStatusTitle()
            }
        }
        if accountPanel?.isVisible == true {
            refreshAccountPanelContentIfVisible()
        } else {
            accountPanel = nil
            lastPanelState = nil
        }
    }

    func lastUpdatedText() -> String {
        if isRefreshing {
            return "refreshing..."
        }
        guard let lastUpdatedAt else {
            return "never"
        }
        let elapsed = max(0, Int(Date().timeIntervalSince(lastUpdatedAt)))
        if elapsed < 15 {
            return "just now"
        }
        if elapsed < 60 {
            return "\(elapsed)s ago"
        }
        let minutes = elapsed / 60
        if minutes < 10 {
            return "\(minutes)m ago"
        }
        if minutes < 60 {
            return "stale \(minutes)m"
        }
        return "stale \(minutes / 60)h"
    }

    func refreshHealthColor() -> NSColor {
        if isRefreshing { return .systemOrange }
        guard let lastUpdatedAt else { return .systemRed }
        let elapsed = Date().timeIntervalSince(lastUpdatedAt)
        if elapsed < 60 { return .systemGreen }
        if elapsed < 600 { return .systemOrange }
        return .systemRed
    }

    @objc func refreshNow() {
        refreshAccounts(force: true)
        claude.refresh()
    }

    var demoScenario: String? {
        guard demoMode else { return nil }
        return ProcessInfo.processInfo.environment["CODEX_ACCOUNT_SWITCHER_DEMO_SCENARIO"]
    }

    func deleteKeychainSecret(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: apiTokenUsageService,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }

    func resolveCodexAuthPathInBackground() {
        guard !isResolvingCodexAuthPath else { return }
        isResolvingCodexAuthPath = true
        DispatchQueue.global(qos: .utility).async {
            _ = self.commands.codexAuthPath()
            DispatchQueue.main.async {
                self.isResolvingCodexAuthPath = false
                self.codexAuthResolveFinished = true
                self.refreshAccountPanelContentIfVisible()
            }
        }
    }

    func showAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message.trimmingCharacters(in: .whitespacesAndNewlines)
        alert.alertStyle = .warning
        _ = alert.runAbovePanel()
    }

}
