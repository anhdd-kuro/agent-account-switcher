import AppKit
import Foundation

extension AppDelegate {
    func showResetCreditsPanel() {
        accountPanelMode = .resets
        refreshAccountPanelContentIfVisible()
        refreshResetCreditsIfNeeded(force: false)
        claude.refreshIfNeeded(maximumAge: 60)
    }

    func refreshResetCreditsIfNeeded(force: Bool) {
        guard !demoMode, !isRedeemingReset, !isRefreshingResetCredits else { return }
        guard RefreshPolicy.shouldRefresh(
            lastRefresh: lastResetCreditsRefreshAt,
            ttl: resetCreditsRefreshInterval,
            force: force
        ) else { return }

        let accountSnapshot = accounts
        guard !accountSnapshot.isEmpty else { return }
        isRefreshingResetCredits = true
        Task {
            let refreshed = await codex.fetchResetCredits(for: accountSnapshot)
            await MainActor.run {
                self.isRefreshingResetCredits = false
                self.lastResetCreditsRefreshAt = Date()
                self.resetCreditsByEmail = refreshed
                self.refreshUI()
            }
        }
    }

    func redeemResetCreditFromPanel(email: String, creditID: String) {
        guard
            let account = accounts.first(where: { $0.email == email }),
            let credit = resetCreditsByEmail[email]?.credits.first(where: { $0.id == creditID })
        else {
            showAlert(title: "Reset unavailable", message: "The selected reset credit could not be found. Refresh the switcher and try again.")
            return
        }

        confirmAndRedeemResetCredit(account: account, credit: credit)
    }

    func confirmAndRedeemResetCredit(account: CodexAccount, credit: ResetCredit) {
        guard !isRedeemingReset else {
            showAlert(title: "Reset already running", message: "Wait for the current reset verification to finish before using another credit.")
            return
        }
        let expires = credit.expiresAt.map { DateFormatter.resetCreditDisplay.string(from: $0) } ?? "unknown expiry"
        let alert = NSAlert()
        alert.messageText = "Redeem reset for \(toolbarLabel(for: account))?"
        alert.informativeText = "This will spend one Codex reset credit for \(preferences.compactEmail(account.email)) and refresh the account's rate-limit window.\n\nExpires: \(expires)"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Redeem Reset")
        alert.addButton(withTitle: "Cancel")

        // The account panel deliberately sits at status-bar level, above a normal
        // modal alert. Hide it before presenting the spending confirmation so the
        // confirmation cannot be obscured underneath the menu-bar panel.
        closeAccountPanel()
        alert.window.center()
        guard alert.runAbovePanel() == .alertFirstButtonReturn else { return }

        redeemResetCredit(account: account, credit: credit)
    }

    func redeemResetCredit(account: CodexAccount, credit: ResetCredit) {
        guard !isRedeemingReset else { return }
        guard case .success(let auth) = codexAuthStore.savedAuth(forEmail: account.email) else {
            showAlert(title: "Reset failed", message: "The saved ChatGPT session for this account could not be read.")
            return
        }

        closeAccountPanel()
        let label = toolbarLabel(for: account)
        let creditBefore = resetCreditsByEmail[account.email]?.displayCount
        isRedeemingReset = true
        beginStatusAnimation(title: "Resetting")

        Task {
            let result = await self.codex.consumeResetCredit(using: auth, creditID: credit.id)
            switch result {
            case .failure(let message):
                await MainActor.run {
                    self.isRedeemingReset = false
                    self.endStatusAnimation()
                    self.setResetStatus("\(label) · reset failed")
                    self.recordReset(
                        label: label,
                        result: "failed",
                        creditBefore: creditBefore,
                        creditAfter: nil,
                        usage: nil,
                        detail: message
                    )
                    self.showAlert(title: "Reset failed", message: message)
                    self.setResetStatus(nil)
                    self.refreshUI()
                }

            case .success(let receipt):
                await MainActor.run {
                    _ = self.beginStatusAnimation(title: "Verifying")
                }

                let verification = await self.verifyResetRedemption(
                    auth: auth,
                    previousCreditCount: creditBefore,
                    receipt: receipt
                )

                await MainActor.run {
                    if let resetSnapshot = verification.resetSnapshot {
                        self.resetCreditsByEmail[account.email] = resetSnapshot
                        self.lastResetCreditsRefreshAt = Date()
                    }
                    if let usageSnapshot = verification.usageSnapshot {
                        self.applyDirectUsage(usageSnapshot, toEmail: account.email)
                    }
                    self.lastUpdatedAt = Date()
                    self.lastError = nil
                    self.isRedeemingReset = false

                    let creditAfter = verification.resetSnapshot?.displayCount
                    let confirmed = verification.creditConfirmed && verification.usageConfirmed
                    let resultName = confirmed ? "confirmed" : "pending"
                    self.endStatusAnimation()
                    self.setResetStatus(confirmed ? "\(label) · reset ✓" : "\(label) · pending")
                    self.recordReset(
                        label: label,
                        result: resultName,
                        creditBefore: creditBefore,
                        creditAfter: creditAfter,
                        usage: verification.usageSnapshot,
                        detail: verification.detail
                    )
                    self.refreshUI()

                    if confirmed {
                        self.showAlert(
                            title: "Reset confirmed",
                            message: self.resetConfirmationMessage(
                                label: label,
                                creditBefore: creditBefore,
                                creditAfter: creditAfter,
                                usage: verification.usageSnapshot,
                                attempts: verification.attempts
                            )
                        )
                    } else {
                        self.scheduleResetFollowUps(
                            auth: auth,
                            label: label,
                            previousCreditCount: creditBefore,
                            receipt: receipt
                        )
                        self.showAlert(
                            title: "Reset accepted — verification pending",
                            message: self.resetPendingMessage(
                                label: label,
                                creditBefore: creditBefore,
                                creditAfter: creditAfter,
                                usage: verification.usageSnapshot,
                                detail: verification.detail
                            )
                        )
                    }

                    self.setResetStatus(nil)
                    self.refreshUI()
                    self.scheduleAllResetCreditsRefresh()
                }
            }
        }
    }

    func verifyResetRedemption(
        auth: SavedAccountAuth,
        previousCreditCount: Int?,
        receipt: ResetConsumeReceipt
    ) async -> ResetVerificationOutcome {
        let delays: [TimeInterval] = [0, 0.8, 1.5, 3.0]
        var latestReset: ResetCreditsSnapshot?
        var latestUsage: DirectUsageSnapshot?
        var creditConfirmed = false
        var usageConfirmed = false
        var details: [String] = []

        for (index, delay) in delays.enumerated() {
            if delay > 0 {
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }

            async let resetResult = codex.fetchResetCredits(using: auth)
            async let usageResult = codex.fetchDirectUsage(using: auth)
            let (resolvedReset, resolvedUsage) = await (resetResult, usageResult)

            switch resolvedReset {
            case .success(let snapshot):
                latestReset = snapshot
                if snapshot.displayCount != nil || previousCreditCount == nil {
                    creditConfirmed = ResetConfirmation(previousCreditCount: previousCreditCount, currentCreditCount: snapshot.displayCount, receipt: receipt, usage: nil).creditConfirmed
                }
            case .failure(let message):
                details.append("credit check \(index + 1): \(message)")
            }

            switch resolvedUsage {
            case .success(let snapshot):
                latestUsage = snapshot
                usageConfirmed = ResetConfirmation(previousCreditCount: previousCreditCount, currentCreditCount: nil, receipt: receipt, usage: snapshot).usageConfirmed
            case .failure(let message):
                details.append("usage check \(index + 1): \(message)")
            }

            if creditConfirmed && usageConfirmed {
                return ResetVerificationOutcome(
                    resetSnapshot: latestReset,
                    usageSnapshot: latestUsage,
                    creditConfirmed: true,
                    usageConfirmed: true,
                    attempts: index + 1,
                    detail: "Backend credit and usage windows confirmed."
                )
            }
        }

        let status = [
            creditConfirmed ? "credit confirmed" : "credit not yet confirmed",
            usageConfirmed ? "usage confirmed" : "usage not yet confirmed"
        ].joined(separator: "; ")
        let detail = details.isEmpty ? status : "\(status). \(details.suffix(2).joined(separator: "; "))"
        return ResetVerificationOutcome(
            resetSnapshot: latestReset,
            usageSnapshot: latestUsage,
            creditConfirmed: creditConfirmed,
            usageConfirmed: usageConfirmed,
            attempts: delays.count,
            detail: detail
        )
    }

    func applyDirectUsage(_ usage: DirectUsageSnapshot, toEmail email: String) {
        directUsageSnapshotsByEmail[email] = usage
        accounts = applyingDirectUsageSnapshots(to: accounts)
    }

    func applyingDirectUsageSnapshots(to source: [CodexAccount]) -> [CodexAccount] {
        source.map { account in
            directUsageSnapshotsByEmail[account.email].map { account.applying($0) } ?? account
        }
    }

    func resetConfirmationMessage(
        label: String,
        creditBefore: Int?,
        creditAfter: Int?,
        usage: DirectUsageSnapshot?,
        attempts: Int
    ) -> String {
        let creditText = resetCreditChangeText(before: creditBefore, after: creditAfter)
        let usageText = resetUsageSummary(usage)
        return "ChatGPT confirmed the reset for account \(label).\n\n\(usageText)\n\(creditText)\nVerified after \(attempts) check\(attempts == 1 ? "" : "s")."
    }

    func resetPendingMessage(
        label: String,
        creditBefore: Int?,
        creditAfter: Int?,
        usage: DirectUsageSnapshot?,
        detail: String
    ) -> String {
        "ChatGPT accepted the reset request for account \(label), but both the credit count and live usage window have not agreed yet.\n\n\(resetUsageSummary(usage))\n\(resetCreditChangeText(before: creditBefore, after: creditAfter))\n\nThe switcher will retry silently. \(detail)"
    }

    func resetCreditChangeText(before: Int?, after: Int?) -> String {
        switch (before, after) {
        case let (before?, after?):
            return "Reset credits: \(before) → \(after)"
        case let (nil, after?):
            return "Reset credits now available: \(after)"
        default:
            return "Reset-credit count is still being checked."
        }
    }

    func resetUsageSummary(_ usage: DirectUsageSnapshot?) -> String {
        guard let usage else { return "Live usage is still being checked." }
        return "5-hour: \(usage.fiveHour.remainingPercent)% remaining · Weekly: \(usage.weekly.remainingPercent)% remaining"
    }

    func scheduleResetFollowUps(
        auth: SavedAccountAuth,
        label: String,
        previousCreditCount: Int?,
        receipt: ResetConsumeReceipt
    ) {
        runResetFollowUp(
            auth: auth,
            label: label,
            previousCreditCount: previousCreditCount,
            receipt: receipt,
            remainingDelays: [8, 22, 60, 120]
        )
    }

    func runResetFollowUp(
        auth: SavedAccountAuth,
        label: String,
        previousCreditCount: Int?,
        receipt: ResetConsumeReceipt,
        remainingDelays: [TimeInterval]
    ) {
        guard let delay = remainingDelays.first else { return }
        Task {
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            async let pendingReset = self.codex.fetchResetCredits(using: auth)
            async let pendingUsage = self.codex.fetchDirectUsage(using: auth)
            let (resetResult, usageResult) = await (pendingReset, pendingUsage)
            let resetSnapshot: ResetCreditsSnapshot?
            let usageSnapshot: DirectUsageSnapshot?

            switch resetResult {
            case .success(let snapshot): resetSnapshot = snapshot
            case .failure: resetSnapshot = nil
            }
            switch usageResult {
            case .success(let snapshot): usageSnapshot = snapshot
            case .failure: usageSnapshot = nil
            }

            let confirmation = ResetConfirmation(previousCreditCount: previousCreditCount, currentCreditCount: resetSnapshot?.displayCount, receipt: receipt, usage: usageSnapshot)
            let creditConfirmed = confirmation.creditConfirmed
            let usageConfirmed = confirmation.usageConfirmed

            await MainActor.run {
                if let resetSnapshot {
                    self.resetCreditsByEmail[auth.email] = resetSnapshot
                    self.lastResetCreditsRefreshAt = Date()
                }
                if let usageSnapshot {
                    self.applyDirectUsage(usageSnapshot, toEmail: auth.email)
                    self.lastUpdatedAt = Date()
                }
                self.refreshUI()

                if creditConfirmed && usageConfirmed {
                    self.recordReset(
                        label: label,
                        result: "confirmed-later",
                        creditBefore: previousCreditCount,
                        creditAfter: resetSnapshot?.displayCount,
                        usage: usageSnapshot,
                        detail: "Silent follow-up confirmed the backend credit and usage windows."
                    )
                } else {
                    self.runResetFollowUp(
                        auth: auth,
                        label: label,
                        previousCreditCount: previousCreditCount,
                        receipt: receipt,
                        remainingDelays: Array(remainingDelays.dropFirst())
                    )
                }
            }
        }
    }

    func scheduleAllResetCreditsRefresh() {
        let accountSnapshot = accounts
        Task {
            try? await Task.sleep(nanoseconds: 45_000_000_000)
            let refreshed = await self.codex.fetchResetCredits(for: accountSnapshot)
            await MainActor.run {
                for (email, snapshot) in refreshed where snapshot.lastError == nil {
                    self.resetCreditsByEmail[email] = snapshot
                }
                self.lastResetCreditsRefreshAt = Date()
                self.refreshUI()
            }
        }
    }
}
