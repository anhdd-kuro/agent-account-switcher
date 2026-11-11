import AppKit
import Foundation

extension AccountSwitcherPanelView {

    func buildAccountsBody(into body: NSView, theme: PanelTheme) -> CGFloat {
        var y = sectionHeader("Codex", logo: "logo-openai", addLabel: "Add Codex account", add: { [weak self] in self?.actions.performSettingsAction(.addAccount) }, into: body, y: 0, theme: theme)
        y = buildCodexCards(into: body, y: y, theme: theme)
        y = sectionHeader("Claude", logo: "logo-claude", addLabel: "Add Claude account", add: { [weak self] in self?.actions.claude.signIn(nil) }, into: body, y: y + 6, theme: theme)
        y = buildClaudeCards(into: body, y: y, theme: theme)
        guard state.cursor.isInstalled else { return y }
        y = sectionHeader("Cursor", logo: "logo-cursor", addLabel: nil, add: {}, into: body, y: y + 6, theme: theme)
        return buildCursorCard(into: body, y: y, theme: theme)
    }

    private func sectionHeader(_ title: String, logo: String, addLabel: String?, add: @escaping () -> Void, into body: NSView, y: CGFloat, theme: PanelTheme) -> CGFloat {
        let height: CGFloat = 24
        if let image = MenuBarGlyph.logo(logo, size: 13, color: logo == "logo-claude" ? MenuBarGlyph.claudeOrange : (theme.isDark ? .white : theme.primaryText)) {
            let view = NSImageView(frame: NSRect(x: inset + 4, y: y + (height - 13) / 2, width: 13, height: 13))
            view.image = image
            body.addSubview(view)
        }
        let label = makeLabel(title, size: 11.5, weight: .semibold, color: theme.secondaryText)
        body.place(label, x: inset + 23, y: y + (height - label.frame.height) / 2, width: 120)
        if let addLabel {
            let button = GlassButton(symbol: "plus", style: .icon, theme: theme, height: 24, fontSize: 10, accessibilityLabel: addLabel, onPress: add)
            button.toolTip = addLabel
            body.place(button, x: Self.panelWidth - inset - button.frame.width, y: y + (height - button.frame.height) / 2)
        }
        return y + height + 6
    }

    private func buildCodexCards(into body: NSView, y startY: CGFloat, theme: PanelTheme) -> CGFloat {
        var y = startY
        guard !state.accounts.isEmpty else {
            let tile = emptyAccountsTile(theme: theme, y: y)
            body.addSubview(tile)
            return tile.frame.maxY + 8
        }
        let active = state.activeAccount ?? state.accounts.first(where: { $0.isActive })
        let others = orderedAccounts().filter { $0.email != active?.email }
        for (index, account) in ((active.map { [$0] } ?? []) + others).enumerated() {
            let card = codexCard(account, divider: index > 0, theme: theme, y: y)
            body.addSubview(card)
            y = card.frame.maxY
        }
        return y + 8
    }

    private func codexCard(_ account: CodexAccount, divider: Bool, theme: PanelTheme, y: CGFloat) -> NSView {
        let needsLogin = account.needsLogin
        let snapshot = state.codexUsageByEmail[account.email]
        let isArmed = state.confirmBeforeSwitching && state.armedSwitchEmail == account.email && !state.isSwitching
        var trailing: [GlassButton] = []
        if needsLogin {
            trailing = [GlassButton(title: "Sign In…", style: .secondary, theme: theme, height: 24, fontSize: 12) { [weak self] in
                self?.actions.performSettingsAction(.addAccount)
            }]
        } else if isArmed {
            trailing = [
                GlassButton(title: "Cancel", style: .secondary, theme: theme, height: 24, fontSize: 12) { [weak self] in
                    self?.actions.performSettingsAction(.usageView)
                },
                GlassButton(title: "Confirm", style: .primary, theme: theme, height: 24, fontSize: 12) { [weak self] in
                    self?.actions.switchAccount(account.email)
                }
            ]
        }
        return usageCard(
            UsageCard(
                title: account.email,
                detail: account.planLabel,
                isActive: account.isActive,
                needsLogin: needsLogin,
                windows: (account.hasFiveHourLimit ? [
                    ("5h", account.fiveHourRemaining, snapshot.map { MenuBarGlyph.relativeReset($0.fiveHour.resetAt) ?? "" } ?? CodexUsageText.fiveHourReset(from: account.fiveHourUsage))
                ] : []) + [
                    ("7d", account.weeklyRemaining, snapshot.map { MenuBarGlyph.relativeReset($0.weekly.resetAt) ?? "" } ?? CodexUsageText.weeklyReset(from: account.weeklyUsage))
                ],
                tooltip: switchPreviewText(for: account),
                switchAction: account.isActive || needsLogin || isArmed || state.isSwitching ? nil : { [weak self] in self?.actions.switchAccount(account.email) }
            ),
            trailing: trailing,
            divider: divider,
            theme: theme,
            y: y
        )
    }

    private struct UsageCard {
        let title: String
        let detail: String
        let isActive: Bool
        let needsLogin: Bool
        let windows: [(String, Int?, String)]
        let tooltip: String?
        let switchAction: (() -> Void)?
    }
    private func usageCard(_ card: UsageCard, trailing: [GlassButton], divider: Bool, theme: PanelTheme, y: CGFloat) -> NSView {
        let headerHeight: CGFloat = 22
        let rowHeight: CGFloat = 18
        let padding: CGFloat = 9
        let bodyRows = card.needsLogin ? 1 : card.windows.count
        let height = padding + headerHeight + 4 + CGFloat(bodyRows) * rowHeight + padding
        let row = TileView(
            frame: NSRect(x: inset, y: y, width: contentWidth, height: height),
            fill: .clear,
            border: .clear,
            borderWidth: 0,
            cornerRadius: 8,
            hoverFill: card.switchAction == nil ? nil : theme.tileHoverFill,
            accessibilityLabel: card.switchAction == nil ? nil : "Switch to \(card.title)",
            action: card.switchAction
        )
        row.toolTip = card.tooltip
        row.alphaValue = card.isActive ? 1 : 0.5
        if divider {
            row.addSubview(HairlineView(frame: NSRect(x: 6, y: 0, width: contentWidth - 12, height: 0.5), color: theme.hairline))
        }

        var rightEdge = contentWidth - 6
        for button in trailing.reversed() {
            rightEdge -= button.frame.width
            row.place(button, x: rightEdge, y: padding + (headerHeight - button.frame.height) / 2)
            rightEdge -= 6
        }
        if card.needsLogin {
            let tag = CapsuleTagView(text: "Signed out", theme: theme, foreground: theme.text(.red), background: theme.tint(.red))
            rightEdge -= tag.frame.width
            row.place(tag, x: rightEdge, y: padding + (headerHeight - tag.frame.height) / 2)
            rightEdge -= 8
        }

        let textX: CGFloat = card.isActive ? 18 : 6
        if card.isActive {
            let dot = NSView(frame: NSRect(x: 6, y: padding + (headerHeight - 6) / 2, width: 6, height: 6))
            dot.wantsLayer = true
            dot.layer?.cornerRadius = 3
            dot.layer?.backgroundColor = theme.accent.cgColor
            row.addSubview(dot)
        }
        let available = rightEdge - textX
        let title = makeLabel(card.title, size: 13, weight: .semibold, color: theme.primaryText)
        let detail = makeLabel(card.detail, size: 11, color: theme.secondaryText)
        let titleWidth = min(title.frame.width, available - min(detail.frame.width, 56) - 8)
        title.toolTip = card.title
        row.place(title, x: textX, y: padding + (headerHeight - title.frame.height) / 2, width: titleWidth)
        detail.toolTip = card.detail
        let detailX = textX + titleWidth + 8
        if available - (detailX - textX) > 24 {
            row.place(detail, x: detailX, y: padding + (headerHeight - detail.frame.height) / 2 + 1, width: available - (detailX - textX))
        }

        var rowY = padding + headerHeight + 4
        if card.needsLogin {
            row.place(makeLabel("Session expired · usage unavailable", size: 11, color: theme.secondaryText), x: 6, y: rowY + 2, width: contentWidth - 12)
            return row
        }
        for (label, percent, reset) in card.windows {
            row.addSubview(UsageBarRowView(
                frame: NSRect(x: 6, y: rowY, width: contentWidth - 12, height: rowHeight),
                label: label,
                percent: percent,
                reset: reset,
                color: theme.color(PanelTheme.usageTone(for: percent)),
                theme: theme
            ))
            rowY += rowHeight
        }
        return row
    }

    private func emptyAccountsTile(theme: PanelTheme, y: CGFloat) -> NSView {
        let tile = TileView(frame: NSRect(x: inset, y: y, width: contentWidth, height: 150), fill: theme.tileFill, border: theme.tileBorder)
        tile.addSubview(MonogramView(frame: NSRect(x: 12, y: 14, width: 32, height: 32), text: "", fill: theme.tint(.blue), textColor: theme.text(.blue), symbol: "person.crop.circle.badge.plus"))
        tile.place(makeLabel("No saved accounts", size: 13, weight: .semibold, color: theme.primaryText), x: 52, y: 15, width: contentWidth - 64)
        tile.place(makeLabel("Sign in once for each ChatGPT account.", size: 11, color: theme.secondaryText), x: 52, y: 33, width: contentWidth - 64)
        if let lastError = state.lastError, !lastError.isEmpty {
            let error = makeLabel(lastError, size: 11, color: theme.text(.orange))
            error.toolTip = lastError
            tile.place(error, x: 12, y: 64, width: contentWidth - 24)
        }
        let add = GlassButton(title: "Add Account…", style: .primary, theme: theme) { [weak self] in
            self?.actions.performSettingsAction(.addAccount)
        }
        tile.place(add, x: 12, y: 108)
        let device = GlassButton(title: "Device Login…", style: .secondary, theme: theme) { [weak self] in
            self?.actions.performSettingsAction(.addDeviceAccount)
        }
        tile.place(device, x: 12 + add.frame.width + 8, y: 108)
        return tile
    }

    func orderedAccounts() -> [CodexAccount] {
        state.accounts.sorted { left, right in
            let leftPriority = CodexAccountOrdering.priority(label: state.label(for: left))
            let rightPriority = CodexAccountOrdering.priority(label: state.label(for: right))
            if leftPriority != rightPriority { return leftPriority < rightPriority }
            return state.label(for: left).localizedCaseInsensitiveCompare(state.label(for: right)) == .orderedAscending
        }
    }

    private func percentText(_ percent: Int?) -> String {
        guard let percent else { return "--" }
        return "\(max(0, min(100, percent)))%"
    }

    private func switchPreviewText(for account: CodexAccount) -> String {
        "Switch to \(state.label(for: account)) · 5-hour \(percentText(account.fiveHourRemaining)) · weekly \(percentText(account.weeklyRemaining))"
    }

}


extension AccountSwitcherPanelView {
    fileprivate func buildCursorCard(into body: NSView, y: CGFloat, theme: PanelTheme) -> CGFloat {
        let snapshot = state.cursor.snapshot
        let reset = MenuBarGlyph.relativeReset(snapshot?.resetAt) ?? ""
        let lanes: [(String, Int?)] = [("Plan", snapshot?.planUsed), ("Auto", snapshot?.autoUsed), ("API", snapshot?.apiUsed)]
        let windows = lanes.compactMap { lane -> (String, Int?, String)? in
            lane.1.map { (lane.0, 100 - $0, reset) }
        }
        let plan = snapshot?.membership.map { $0.prefix(1).uppercased() + $0.dropFirst() } ?? "Cursor"
        let card = usageCard(
            UsageCard(
                title: "Cursor \(plan)",
                detail: state.cursor.error ?? "",
                isActive: true,
                needsLogin: false,
                windows: windows,
                tooltip: state.cursor.error,
                switchAction: nil
            ),
            trailing: [],
            divider: false,
            theme: theme,
            y: y
        )
        body.addSubview(card)
        return card.frame.maxY + 12
    }
}

extension AccountSwitcherPanelView {
    private func buildClaudeCards(into body: NSView, y startY: CGFloat, theme: PanelTheme) -> CGFloat {
        var y = startY
        guard !state.claude.accounts.isEmpty else {
            let tile = TileView(frame: NSRect(x: inset, y: y, width: contentWidth, height: 112), fill: theme.tileFill, border: theme.tileBorder)
            tile.addSubview(MonogramView(frame: NSRect(x: 12, y: 14, width: 32, height: 32), text: "", fill: theme.tint(.orange), textColor: theme.text(.orange), symbol: "sparkle"))
            tile.place(makeLabel("No Claude accounts", size: 13, weight: .semibold, color: theme.primaryText), x: 52, y: 15, width: contentWidth - 64)
            tile.place(makeLabel("Sign in once for each Claude account.", size: 11, color: theme.secondaryText), x: 52, y: 33, width: contentWidth - 64)
            let add = GlassButton(title: "Sign In to Claude…", style: .primary, theme: theme) { [weak self] in
                self?.actions.claude.signIn(nil)
            }
            tile.place(add, x: 12, y: 68)
            body.addSubview(tile)
            return tile.frame.maxY + 12
        }

        let active = state.claude.active
        let others = state.claude.accounts.filter { !$0.isActive }
        for account in (active.map { [$0] } ?? []) + others {
            var trailing: [GlassButton] = []
            if account.needsLogin {
                trailing = [GlassButton(title: "Sign In…", style: .secondary, theme: theme, height: 24, fontSize: 12) { [weak self] in
                    self?.actions.claude.signIn(account.email)
                }]
            }
            let canSwitch = !account.isActive && !account.needsLogin && !state.claude.isSwitching
            let card = usageCard(
                UsageCard(
                    title: account.title,
                    detail: "\(account.planLabel) · \(account.email)",
                    isActive: account.isActive,
                    needsLogin: account.needsLogin,
                    windows: (account.hasFiveHourLimit ? [
                        ("5h", account.fiveHourRemaining, MenuBarGlyph.relativeReset(account.fiveHourResetAt) ?? "")
                    ] : []) + [
                        ("7d", account.weeklyRemaining, MenuBarGlyph.relativeReset(account.weeklyResetAt) ?? "")
                    ],
                    tooltip: ["\(account.title) · \(account.plan)", account.email, account.usageError].compactMap { $0 }.joined(separator: "\n"),
                    switchAction: canSwitch ? { [weak self] in self?.actions.claude.switchAccount(account.id) } : nil
                ),
                trailing: trailing,
                divider: y > startY,
                theme: theme,
                y: y
            )
            body.addSubview(card)
            y = card.frame.maxY
        }
        return y + 12
    }
}
