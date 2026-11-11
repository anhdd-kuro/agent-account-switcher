import AppKit
import Foundation

extension AccountSwitcherPanelView {

    func buildResetsBody(into body: NSView, theme: PanelTheme) -> CGFloat {
        var y: CGFloat = 0
        let summary = resetSummaryTile(theme: theme, y: y)
        body.addSubview(summary)
        y = summary.frame.maxY + 14

        if !state.accounts.isEmpty {
            body.place(makeLabel(claudeResetAccounts.isEmpty ? "By account" : "Codex", size: 11, weight: .semibold, color: theme.secondaryText), x: inset + 4, y: y, width: 200)
            y += 20
            for account in orderedAccounts() {
                let group = resetAccountGroup(account, theme: theme, y: y)
                body.addSubview(group)
                y = group.frame.maxY + 10
            }
        }
        if !claudeResetAccounts.isEmpty {
            body.place(makeLabel("Claude", size: 11, weight: .semibold, color: theme.secondaryText), x: inset + 4, y: y, width: 200)
            y += 20
            for account in claudeResetAccounts {
                let group = claudeResetGroup(account, theme: theme, y: y)
                body.addSubview(group)
                y = group.frame.maxY + 10
            }
        }
        return y + 2
    }
    private var claudeResetAccounts: [ClaudeAccountSummary] {
        state.claude.accounts.filter { !$0.needsLogin }.sorted { $0.isActive && !$1.isActive }
    }

    private func claudeResetGroup(_ account: ClaudeAccountSummary, theme: PanelTheme, y: CGFloat) -> NSView {
        let grants = account.resets?.grants ?? []
        let rowHeight: CGFloat = 40
        let group = TileView(frame: NSRect(x: inset, y: y, width: contentWidth, height: rowHeight * CGFloat(1 + max(1, grants.count))), fill: theme.tileFill, border: theme.tileBorder)

        let countText: String
        if let resets = account.resets {
            countText = account.isActive ? "Active · \(resets.availableCount)" : "\(resets.availableCount)"
        } else {
            countText = account.usageError != nil ? "Unavailable" : "Checking…"
        }
        let tag = CapsuleTagView(text: countText, theme: theme, foreground: theme.secondaryText, background: theme.controlFill)
        group.place(tag, x: contentWidth - 12 - tag.frame.width, y: 11)
        if account.isActive {
            group.addSubview(DotView(frame: NSRect(x: 14, y: 17, width: 7, height: 7), color: theme.color(.green)))
        }
        let name = makeLabel("\(account.title) · \(account.email)", size: 12.5, weight: .semibold, color: theme.primaryText)
        name.lineBreakMode = .byTruncatingTail
        group.place(name, x: 28, y: 12, width: contentWidth - 28 - tag.frame.width - 22)

        var rowY = rowHeight
        group.addSubview(HairlineView(frame: NSRect(x: 12, y: rowY, width: contentWidth - 24, height: 0.5), color: theme.hairline))
        guard account.resets != nil, !grants.isEmpty else {
            let text: String
            if account.resets == nil {
                text = account.usageError.map { "Couldn’t check · \($0)" } ?? "Checking resets…"
            } else {
                text = "No resets available"
            }
            let label = makeLabel(text, size: 11.5, color: account.resets == nil && account.usageError != nil ? theme.text(.orange) : theme.secondaryText)
            label.toolTip = account.resets?.ineligibleReason.map { "Not offered: \($0)" } ?? account.usageError
            group.place(label, x: 12, y: rowY + 12, width: contentWidth - 24)
            return group
        }
        for (index, grant) in grants.enumerated() {
            if index > 0 {
                group.addSubview(HairlineView(frame: NSRect(x: 12, y: rowY, width: contentWidth - 24, height: 0.5), color: theme.hairline))
            }
            let days = daysLeft(until: grant.endsAt)
            let tone = days.map { urgencyTone(days: $0) } ?? .blue
            let dueText = days.map { daysLeftText($0) } ?? (grant.program == ClaudeResetGrant.fiveHourProgram ? "1/week" : "no expiry")
            let due = CapsuleTagView(text: dueText, theme: theme, foreground: theme.text(tone), background: theme.tint(tone), height: 20, fontSize: 11, fixedWidth: 64)
            group.place(due, x: 12, y: rowY + 10)

            let use = GlassButton(title: "Use", style: .use, theme: theme, height: 24, fontSize: 11.5, accessibilityLabel: "Use Claude \(grant.title) for \(account.title)") { [weak self] in
                self?.actions.claude.useReset(account.id, grant.id)
            }
            use.isEnabled = grant.usableNow && !state.claude.isClaimingReset && !state.claude.isSwitching
            use.toolTip = grant.unavailableText ?? "Use this reset after confirmation"
            let useX = contentWidth - 12 - use.frame.width
            group.place(use, x: useX, y: rowY + 8)

            var text = grant.title
            if !grant.clearedText.isEmpty, !grant.title.lowercased().hasPrefix(grant.clearedText) {
                text += " · \(grant.clearedText)"
            }
            if grant.resetsLeft > 1 { text += " · ×\(grant.resetsLeft)" }
            if let unavailable = grant.unavailableText { text += " · \(unavailable)" }
            let label = makeLabel(text, size: 12, color: grant.usableNow ? theme.primaryText : theme.secondaryText)
            label.lineBreakMode = .byTruncatingTail
            label.toolTip = [grant.label, grant.endsAt.map { "Use by \(DateFormatter.resetCreditDisplay.string(from: $0))" }]
                .compactMap { $0?.isEmpty == false ? $0 : nil }.joined(separator: "\n")
            group.place(label, x: 86, y: rowY + 12, width: useX - 96)
            rowY += rowHeight
        }
        return group
    }

    private func resetSummaryTile(theme: PanelTheme, y: CGFloat) -> NSView {
        let summary = resetCreditsSummaryState()
        let codexExpiries = state.accounts.flatMap { account in
            (state.resetCreditsByEmail[account.email].map { sortedAvailableResetCredits($0) } ?? []).map(\.expiresAt)
        }
        let claudeExpiries = claudeResetAccounts.flatMap { account in
            (account.resets?.grants ?? []).flatMap { Array(repeating: $0.endsAt, count: $0.resetsLeft) }
        }
        let expiries = codexExpiries + claudeExpiries
        let days = expiries.compactMap { daysLeft(until: $0) }
        let urgent = days.filter { $0 <= 7 }.count
        let soon = days.filter { $0 > 7 && $0 <= 20 }.count
        let later = expiries.count - urgent - soon
        let hasBreakdown = !expiries.isEmpty

        let height: CGFloat = hasBreakdown ? 118 : 76
        let tile = TileView(frame: NSRect(x: inset, y: y, width: contentWidth, height: height), fill: theme.tileFill, border: theme.tileBorder)
        tile.place(makeLabel("Available resets", size: 11, color: theme.secondaryText), x: 14, y: 13, width: 160)

        let countText = summary.knownAccounts == 0 && !summary.hasError ? "…" : "\(summary.knownTotal)"
        let count = makeLabel(countText, size: 34, weight: .semibold, color: theme.primaryText, monospacedDigits: true, kern: -1)
        tile.place(count, x: 13, y: 28)
        let accountsWithCredits = state.accounts.filter { (state.resetCreditsByEmail[$0.email]?.displayCount ?? 0) > 0 }.count
            + claudeResetAccounts.filter { ($0.resets?.availableCount ?? 0) > 0 }.count
        let across = summary.knownTotal == 0
            ? (summary.hasError ? "some accounts could not be checked" : "none right now")
            : (accountsWithCredits == 1 ? "on 1 account" : "across \(accountsWithCredits) accounts")
        let acrossLabel = makeLabel(across, size: 12, color: theme.secondaryText)
        tile.place(acrossLabel, x: count.frame.maxX + 8, y: count.frame.maxY - acrossLabel.frame.height - 5, width: 170)

        if let next = expiries.compactMap({ $0 }).min(), let nextDays = daysLeft(until: next) {
            let tone = urgencyTone(days: nextDays)
            let dateText = DateFormatter.resetCreditShortDate.string(from: next)
            let capsule = CapsuleTagView(text: "\(dateText) · \(daysLeftText(nextDays))", theme: theme, foreground: theme.text(tone), background: theme.tint(tone), height: 20, fontSize: 11)
            tile.place(capsule, x: contentWidth - 14 - capsule.frame.width, y: 38)
            let caption = makeLabel("Next expiry", size: 11, color: theme.secondaryText, alignment: .right)
            tile.place(caption, x: contentWidth - 14 - 120, y: 13, width: 120)
        }

        if hasBreakdown {
            let bar = StackedBarView(frame: NSRect(x: 14, y: 78, width: contentWidth - 28, height: 6), segments: [
                (CGFloat(urgent), theme.color(.red)),
                (CGFloat(soon), theme.color(.orange)),
                (CGFloat(later), theme.color(.green))
            ])
            tile.addSubview(bar)
            var x: CGFloat = 14
            for (value, text, tone) in [(urgent, "within a week", PanelTheme.Tone.red), (soon, "within 20 days", .orange), (later, "later", .green)] where value > 0 {
                tile.addSubview(DotView(frame: NSRect(x: x, y: 96, width: 7, height: 7), color: theme.color(tone)))
                let legend = makeLabel("\(value) \(text)", size: 10.5, color: theme.secondaryText, monospacedDigits: true)
                tile.place(legend, x: x + 11, y: 92)
                x += 11 + legend.frame.width + 14
            }
        }
        return tile
    }

    private func resetAccountGroup(_ account: CodexAccount, theme: PanelTheme, y: CGFloat) -> NSView {
        let snapshot = state.resetCreditsByEmail[account.email]
        let credits = snapshot.map { sortedAvailableResetCredits($0) } ?? []
        let rowHeight: CGFloat = 40
        let bodyRows = max(1, credits.count)
        let group = TileView(frame: NSRect(x: inset, y: y, width: contentWidth, height: rowHeight * CGFloat(1 + bodyRows)), fill: theme.tileFill, border: theme.tileBorder)

        let tone: PanelTheme.Tone = account.isActive ? PanelTheme.usageTone(for: account.fiveHourRemaining) : .neutral
        group.addSubview(MonogramView(frame: NSRect(x: 12, y: 8, width: 24, height: 24), text: state.label(for: account), fill: account.isActive ? theme.tint(tone) : theme.controlFill, textColor: theme.text(tone)))
        let countText: String
        if let count = snapshot?.displayCount {
            countText = account.isActive ? "Active · \(count)" : "\(count)"
        } else {
            countText = snapshot?.lastError != nil ? "Unavailable" : "Checking…"
        }
        let tag = CapsuleTagView(text: countText, theme: theme, foreground: theme.secondaryText, background: theme.controlFill)
        group.place(tag, x: contentWidth - 12 - tag.frame.width, y: 11)
        group.place(makeLabel(account.email, size: 12.5, weight: .semibold, color: theme.primaryText), x: 44, y: 12, width: contentWidth - 44 - tag.frame.width - 22)

        var rowY = rowHeight
        group.addSubview(HairlineView(frame: NSRect(x: 12, y: rowY, width: contentWidth - 24, height: 0.5), color: theme.hairline))

        if let error = snapshot?.lastError {
            let label = makeLabel("Couldn’t check · \(error)", size: 11.5, color: theme.text(.orange))
            label.toolTip = error
            group.place(label, x: 12, y: rowY + 12, width: contentWidth - 24)
            return group
        }
        guard snapshot != nil else {
            group.place(makeLabel("Checking reset credits…", size: 11.5, color: theme.secondaryText), x: 12, y: rowY + 12, width: contentWidth - 24)
            return group
        }
        guard !credits.isEmpty else {
            group.place(makeLabel("No resets available", size: 11.5, color: theme.secondaryText), x: 12, y: rowY + 12, width: contentWidth - 24)
            return group
        }

        for (index, credit) in credits.enumerated() {
            if index > 0 {
                group.addSubview(HairlineView(frame: NSRect(x: 12, y: rowY, width: contentWidth - 24, height: 0.5), color: theme.hairline))
            }
            let days = resetCreditDaysLeft(credit)
            let tone = days.map { urgencyTone(days: $0) } ?? .blue
            let due = CapsuleTagView(text: days.map { daysLeftText($0) } ?? "unknown", theme: theme, foreground: theme.text(tone), background: theme.tint(tone), height: 20, fontSize: 11, fixedWidth: 64)
            group.place(due, x: 12, y: rowY + 10)

            let use = GlassButton(title: "Use", style: .use, theme: theme, height: 24, fontSize: 11.5, accessibilityLabel: "Use reset expiring \(resetCreditExpiryText(credit))") { [weak self] in
                self?.actions.redeemResetCredit(account.email, credit.id)
            }
            use.toolTip = "Redeem this reset credit after confirmation"
            use.isEnabled = !state.isSwitching
            let useX = contentWidth - 12 - use.frame.width
            group.place(use, x: useX, y: rowY + 8)

            let date = makeLabel(resetCreditExpiryText(credit), size: 12, color: theme.primaryText, monospacedDigits: true)
            date.toolTip = "Granted \(credit.grantedAt.map { DateFormatter.resetCreditDisplay.string(from: $0) } ?? "unknown")"
            group.place(date, x: 86, y: rowY + 12, width: useX - 96)
            rowY += rowHeight
        }
        return group
    }

    func resetCreditsSubtitle() -> String {
        let summary = resetCreditsSummaryState()
        if summary.knownAccounts == 0 {
            return summary.hasError ? "Some accounts could not be checked" : "Checking saved accounts…"
        }
        if summary.hasError {
            return "Some accounts could not be checked"
        }
        let count = state.accounts.count + claudeResetAccounts.count
        return "Reset credits for \(count == 1 ? "1 account" : "\(count) accounts")"
    }

    private func urgencyTone(days: Int) -> PanelTheme.Tone {
        if days <= 7 { return .red }
        if days <= 20 { return .orange }
        return .green
    }

    private func daysLeftText(_ days: Int) -> String {
        if days <= 0 { return "today" }
        return days == 1 ? "1 day" : "\(days) days"
    }

    private func resetCreditExpiryText(_ credit: ResetCredit) -> String {
        credit.expiresAt.map { DateFormatter.resetCreditDisplay.string(from: $0) } ?? "Unknown expiry"
    }

    private func resetCreditDaysLeft(_ credit: ResetCredit) -> Int? {
        daysLeft(until: credit.expiresAt)
    }

    private func daysLeft(until date: Date?) -> Int? {
        guard let date else { return nil }
        return max(0, Int(ceil(date.timeIntervalSince(Date()) / 86_400)))
    }

    private func sortedAvailableResetCredits(_ snapshot: ResetCreditsSnapshot) -> [ResetCredit] {
        snapshot.availableCredits.sorted { left, right in
            switch (left.expiresAt, right.expiresAt) {
            case let (left?, right?): return left < right
            case (.some, nil): return true
            case (nil, .some): return false
            case (nil, nil): return left.title.localizedCaseInsensitiveCompare(right.title) == .orderedAscending
            }
        }
    }

    func resetCreditsSummaryState() -> (knownTotal: Int, knownAccounts: Int, hasError: Bool) {
        let snapshots = state.accounts.compactMap { state.resetCreditsByEmail[$0.email] }
        let knownCounts = snapshots.compactMap { $0.displayCount } + claudeResetAccounts.compactMap { $0.resets?.availableCount }
        let claudeError = claudeResetAccounts.contains { $0.resets == nil && $0.usageError != nil }
        return (knownCounts.reduce(0, +), knownCounts.count, claudeError || snapshots.contains { $0.lastError != nil })
    }

}
