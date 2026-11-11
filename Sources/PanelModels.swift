import AppKit
import Foundation

struct AccountPanelState: Equatable {
    let accounts: [CodexAccount]
    let activeAccount: CodexAccount?
    let mode: AccountPanelMode
    let lastUpdatedText: String
    let lastError: String?
    let isSwitching: Bool
    let launchAtLoginEnabled: Bool
    let remindersEnabled: Bool
    let reminderThreshold: Int
    let autoSwitchThreshold: Int
    let autoSwitchMode: AutoSwitchMode
    let autoResumeMode: AutoResumeMode
    let confirmBeforeSwitching: Bool
    let armedSwitchEmail: String?
    let resetCreditsByEmail: [String: ResetCreditsSnapshot]
    let healthStatuses: [HealthStatus]
    let routeBProfiles: [RouteBProviderProfile]
    let selectedRouteBProfileID: String?
    let usageMode: UsageDisplayMode
    let claudeUsageMode: UsageDisplayMode
    let toolbarDisplayStyle: ToolbarDisplayStyle
    let activeRefreshInterval: Int
    let idleRefreshInterval: Int
    let accountLabels: [String: String]
    let claude: ClaudePanelState
    let codexUsageByEmail: [String: DirectUsageSnapshot]
    let cursor: CursorUsageState
    let cursorLane: CursorMenuBarLane
    let menuBarPreview: [MenuBarGlyph.UsagePart]
    let analytics: AnalyticsPanelState
    let toastOnReset: Bool
    let confettiOnReset: Bool
    let reopenOnSameDesktop: Bool

    func label(for account: CodexAccount) -> String {
        accountLabels[account.email] ?? String(account.selector.prefix(1))
    }
}

struct AccountPanelActions {
    let switchAccount: (String) -> Void
    let logoutAccount: (String) -> Void
    let refresh: () -> Void
    let checkUpdates: () -> Void
    let editAccountLabel: (String) -> Void
    let showResetCredits: () -> Void
    let redeemResetCredit: (String, String) -> Void
    let selectRouteBProfile: (String) -> Void
    let performSettingsAction: (SettingsPanelAction) -> Void
    let close: () -> Void
    let claude: ClaudePanelActions
    let analytics: AnalyticsPanelActions
}

struct ClaudePanelState: Equatable {
    let accounts: [ClaudeAccountSummary]
    let lastError: String?
    let updatedText: String
    let isSwitching: Bool
    let isClaimingReset: Bool

    var active: ClaudeAccountSummary? { accounts.first(where: \.isActive) }
}

struct ClaudePanelActions {
    let switchAccount: (String) -> Void
    let signIn: (String?) -> Void
    let remove: (String) -> Void
    let useReset: (String, String) -> Void
}

struct AnalyticsPanelState: Equatable {
    let snapshot: AnalyticsSnapshot?
    let status: AnalyticsScanStatus
    let period: AnalyticsPeriod

    func model(actions: AnalyticsPanelActions) -> AnalyticsPanelModel {
        AnalyticsPanelModel(snapshot: snapshot, status: status, period: period,
                            selectPeriod: actions.selectPeriod, refresh: actions.refresh)
    }
}

struct AnalyticsPanelActions {
    let selectPeriod: (AnalyticsPeriod) -> Void
    let refresh: () -> Void
}
