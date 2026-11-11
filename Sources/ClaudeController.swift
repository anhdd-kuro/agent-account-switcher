import Foundation

final class ClaudeController {
    private(set) var accounts: [ClaudeAccountSummary] = []
    private(set) var lastError: String?
    private(set) var lastUpdatedAt: Date?
    private(set) var isSwitching = false
    var isClaimingReset = false
    private(set) var isRefreshing = false
    private var pendingRefresh = false
    private var lastRefreshStartedAt: Date?
    private var pendingSwitch: (id: String, completion: (String?) -> Void)?
    /// Request ids of claims whose outcome is unknown, keyed by profile, grant and resets left.
    /// A retry reuses the id so Anthropic does not spend a second reset.
    var resetRequestIDs: [String: String] = [:]
    private let refreshInterval: TimeInterval = 90
    var onChange: (() -> Void)?
    var isEnabled = true

    private let loadAccounts: () async -> [ClaudeAccountSummary]
    let submitResetClaim: (String, ClaudeResetGrant, String) async -> Result<ClaudeResetClaimResult, ClaudeError>

    init(
        loadAccounts: @escaping () async -> [ClaudeAccountSummary] = {
            let snapshot = ClaudeAccountStore.synchronize()
            return await ClaudeAPI.summaries(snapshot.profiles, credentials: snapshot.credentials)
        },
        submitResetClaim: @escaping (String, ClaudeResetGrant, String) async -> Result<ClaudeResetClaimResult, ClaudeError> = {
            await ClaudeAPI.claimReset(profileID: $0, grant: $1, requestID: $2)
        }
    ) {
        self.loadAccounts = loadAccounts
        self.submitResetClaim = submitResetClaim
    }

    var active: ClaudeAccountSummary? { accounts.first(where: \.isActive) }

    var updatedText: String {
        if isRefreshing && lastUpdatedAt == nil { return "refreshing..." }
        guard let lastUpdatedAt else { return "never" }
        let seconds = Int(Date().timeIntervalSince(lastUpdatedAt))
        if seconds < 60 { return "just now" }
        if seconds < 3600 { return "\(seconds / 60)m ago" }
        return "\(seconds / 3600)h ago"
    }

    func refreshIfNeeded(maximumAge: TimeInterval? = nil) {
        if let lastRefreshStartedAt, Date().timeIntervalSince(lastRefreshStartedAt) < (maximumAge ?? refreshInterval) { return }
        refresh()
    }

    func refresh() {
        guard isEnabled, !isSwitching, !isClaimingReset else { return }
        guard !isRefreshing else {
            pendingRefresh = true
            return
        }
        isRefreshing = true
        lastRefreshStartedAt = Date()
        Task.detached(priority: .utility) {
            let summaries = await self.loadAccounts()
            await MainActor.run { self.apply(summaries) }
        }
    }

    private func apply(_ summaries: [ClaudeAccountSummary]) {
        let previous = Dictionary(accounts.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        accounts = summaries.map { $0.retainingUsage(from: previous[$0.id]) }
        lastError = ClaudeCLI.executable() == nil && accounts.isEmpty ? "Claude Code CLI not found" : nil
        if summaries.contains(where: { $0.usageError == nil && !$0.needsLogin }) {
            lastUpdatedAt = Date()
        }
        isRefreshing = false
        // Start a queued switch before onChange, which may run auto-switch.
        if let pendingSwitch {
            self.pendingSwitch = nil
            pendingRefresh = false
            switchTo(pendingSwitch.id, completion: pendingSwitch.completion)
            return
        }
        onChange?()
        if pendingRefresh {
            pendingRefresh = false
            refresh()
        }
    }

    /// Waits for an in-flight refresh: it may be rotating the target's token.
    func switchTo(_ id: String, completion: @escaping (String?) -> Void) {
        guard isEnabled else { return completion("Claude switching is disabled in demo mode.") }
        guard !isSwitching, pendingSwitch == nil else { return completion("Another Claude switch is already in progress.") }
        guard !isClaimingReset else { return completion("Wait for the Claude reset to finish, then switch.") }
        guard !isRefreshing else {
            pendingSwitch = (id, completion)
            return
        }
        isSwitching = true
        onChange?()
        Task.detached(priority: .userInitiated) {
            let failure: String?
            do {
                try ClaudeAccountStore.switchTo(profileID: id)
                failure = nil
            } catch {
                failure = error.localizedDescription
            }
            await MainActor.run {
                self.isSwitching = false
                self.lastError = failure
                if failure == nil {
                    self.accounts = self.accounts.map { $0.settingActive($0.id == id) }
                }
                self.onChange?()
                completion(failure)
                self.refresh()
            }
        }
    }

    func remove(_ id: String) throws {
        try ClaudeAccountStore.remove(profileID: id)
        accounts.removeAll { $0.id == id }
        onChange?()
    }

    func signIn(email: String?, completion: @escaping (String?) -> Void) {
        guard isEnabled else {
            completion("Claude sign-in is disabled in demo mode.")
            return
        }
        Task.detached(priority: .userInitiated) {
            let failure: String?
            do {
                try ClaudeCLI.openLoginTerminal(email: email)
                failure = nil
            } catch {
                failure = error.localizedDescription
            }
            await MainActor.run { completion(failure) }
        }
    }
}
