import AppKit
import Foundation

extension AccountSwitcherPanelView {

    private struct SettingsRow {
        let height: CGFloat
        let build: (NSView, CGFloat) -> Void
    }

    func buildSettingsBody(into body: NSView, theme: PanelTheme) -> CGFloat {
        var y: CGFloat = 0

        let cursorRow: [SettingsRow] = state.cursor.isInstalled ? [segmentedRow("Cursor", options: [
            ("Off", state.cursorLane == .off, .cursorBarOff),
            ("Auto", state.cursorLane == .auto, .cursorBarAuto),
            ("API", state.cursorLane == .api, .cursorBarApi),
            ("Both", state.cursorLane == .both, .cursorBarBoth)
        ], theme: theme)] : []
        y = addSection("Menu bar", rows: [
            segmentedRow("Codex", options: [
                ("Off", state.usageMode == .off, .usageOff),
                ("5-hour", state.usageMode == .fiveHour, .usageFiveHour),
                ("Weekly", state.usageMode == .weekly, .usageWeekly),
                ("Both", state.usageMode == .both, .usageBoth)
            ], theme: theme),
            segmentedRow("Claude", options: [
                ("Off", state.claudeUsageMode == .off, .claudeUsageOff),
                ("5-hour", state.claudeUsageMode == .fiveHour, .claudeUsageFiveHour),
                ("Weekly", state.claudeUsageMode == .weekly, .claudeUsageWeekly),
                ("Both", state.claudeUsageMode == .both, .claudeUsageBoth)
            ], theme: theme),
        ] + cursorRow + [
            segmentedRow("Size", options: [
                ("Large", state.toolbarDisplayStyle == .detailed, .styleDetailed),
                ("Small", state.toolbarDisplayStyle == .compact, .styleCompact)
            ], theme: theme),
            menuBarPreviewRow(theme: theme)
        ], into: body, y: y, theme: theme)

        y = addSection("Automation", rows: [
            toggleRow("Follow ChatGPT", detail: "Show only while ChatGPT is open", isOn: state.launchAtLoginEnabled, action: .toggleLaunchAtLogin, theme: theme),
            toggleRow("Usage reminder", detail: "Alert when Codex or Claude runs low", isOn: state.remindersEnabled, action: .toggleUsageReminder, popup: ("at \(state.reminderThreshold)%", .editUsageReminder), theme: theme),
            toggleRow("Auto-switch", detail: "Switch Codex and Claude when low", isOn: state.autoSwitchMode != .off, action: .toggleAutoSwitch, popup: (autoSwitchPopupText(), .editAutoSwitch), theme: theme),
            popupRow("Auto-resume", detail: "Continue the Codex task after a switch", value: autoResumeText(), action: .editAutoResume, theme: theme),
            toggleRow("Reopen on same desktop", detail: "Relaunch Codex on the desktop it was on, not the current one", isOn: state.reopenOnSameDesktop, action: .toggleReopenOnSameDesktop, theme: theme),
            toggleRow("Toast on limit reset", detail: "Show a brief message when a limit resets", isOn: state.toastOnReset, action: .toggleToastOnReset, theme: theme),
            toggleRow("Fireworks on limit reset", detail: "Celebrate when a limit refills after you were near it", isOn: state.confettiOnReset, action: .toggleConfettiOnReset, theme: theme),
            popupRow("Test celebration", detail: "Play the toast and fireworks now", value: "Play", action: .testCelebration, theme: theme),
            toggleRow("Confirm before switching", detail: "Click once to arm, again to relaunch", isOn: state.confirmBeforeSwitching, action: .toggleConfirmSwitch, theme: theme)
        ], into: body, y: y, theme: theme)

        var accountRows = orderedAccounts().map { settingsAccountRow($0, theme: theme) }
        accountRows.append(navRow("Add Account…", value: "Browser sign-in", symbol: "plus", tint: .blue, action: .addAccount, theme: theme))
        accountRows.append(navRow("Device Login…", value: "Code on another device", symbol: "desktopcomputer", tint: .neutral, action: .addDeviceAccount, theme: theme))
        y = addSection("Codex accounts", rows: accountRows, into: body, y: y, theme: theme)

        var claudeRows = state.claude.accounts.map { settingsClaudeRow($0, theme: theme) }
        claudeRows.append(navRow("Add Claude Account…", value: "claude auth login", symbol: "plus", tint: .blue, action: .addClaudeAccount, theme: theme))
        y = addSection("Claude accounts", rows: claudeRows, into: body, y: y, theme: theme)

        y = addSection("Health", rows: [healthRow(theme: theme)], into: body, y: y, theme: theme)

        y = addSection("General", rows: [
            navRow("Refresh rate", value: "\(state.activeRefreshInterval)s active · \(state.idleRefreshInterval)s idle", action: .editRefresh, theme: theme),
            updatesRow(theme: theme),
            navRow("Diagnostics", value: "Privacy-safe report", action: .diagnostics, theme: theme),
            navRow("Route B profiles", value: nil, tag: "Preview", action: .routeBView, theme: theme)
        ], into: body, y: y, theme: theme)
        return y
    }

    private func addSection(_ title: String, rows: [SettingsRow], into body: NSView, y: CGFloat, theme: PanelTheme) -> CGFloat {
        let header = makeLabel(title, size: 11, weight: .semibold, color: theme.secondaryText)
        body.place(header, x: inset + 4, y: y, width: 200)
        let groupY = y + header.frame.height + 6
        let height = rows.reduce(0) { $0 + $1.height }
        let group = TileView(frame: NSRect(x: inset, y: groupY, width: contentWidth, height: height), fill: theme.tileFill, border: theme.tileBorder)
        var rowY: CGFloat = 0
        for (index, row) in rows.enumerated() {
            let container = FlippedContainerView(frame: NSRect(x: 0, y: rowY, width: contentWidth, height: row.height))
            row.build(container, contentWidth)
            if index > 0 {
                container.addSubview(HairlineView(frame: NSRect(x: 12, y: 0, width: contentWidth - 12, height: 0.5), color: theme.hairline))
            }
            group.addSubview(container)
            rowY += row.height
        }
        body.addSubview(group)
        return group.frame.maxY + 16
    }

    private func segmentedRow(_ title: String, options: [(String, Bool, SettingsPanelAction)], theme: PanelTheme) -> SettingsRow {
        SettingsRow(height: 40) { [weak self] row, width in
            let label = makeLabel(title, size: 12.5, weight: .medium, color: theme.primaryText)
            let controlWidth = max(150, CGFloat(options.count) * 62)
            row.place(label, x: 12, y: (40 - label.frame.height) / 2, width: width - controlWidth - 30)
            let segments = options.map { option in
                SegmentedTabsView.Segment(title: option.0, badge: nil, isSelected: option.1) { self?.actions.performSettingsAction(option.2) }
            }
            row.addSubview(SegmentedTabsView(frame: NSRect(x: width - 12 - controlWidth, y: 8, width: controlWidth, height: 24), theme: theme, segments: segments, fontSize: 11.5))
        }
    }

    private func menuBarPreviewRow(theme: PanelTheme) -> SettingsRow {
        let compact = state.toolbarDisplayStyle == .compact
        let title = MenuBarGlyph.usageTitle(state.menuBarPreview, fontSize: compact ? 11 : 12.5, compact: compact, textColor: theme.primaryText, lowColor: theme.text(.red), separatorColor: theme.secondaryText)
        let text = NSTextField(labelWithAttributedString: title.length == 0 ? NSAttributedString(string: "–") : title)
        text.sizeToFit()
        let chipWidth = text.frame.width + 20
        let chipHeight = max(24, text.frame.height + 8)
        let labelWidth: CGFloat = 70
        let stacked = chipWidth + labelWidth + 36 > contentWidth
        return SettingsRow(height: stacked ? 28 + chipHeight + 8 : max(40, chipHeight + 16)) { row, width in
            let label = makeLabel("Preview", size: 12.5, weight: .medium, color: theme.primaryText)
            let chipY: CGFloat
            if stacked {
                row.place(label, x: 12, y: 8, width: labelWidth)
                chipY = 28
            } else {
                row.place(label, x: 12, y: (row.frame.height - label.frame.height) / 2, width: labelWidth)
                chipY = (row.frame.height - chipHeight) / 2
            }
            let chip = TileView(frame: NSRect(x: max(12, width - 12 - chipWidth), y: chipY, width: chipWidth, height: chipHeight), fill: theme.isDark ? NSColor.black.withAlphaComponent(0.30) : NSColor.black.withAlphaComponent(0.07), cornerRadius: 6)
            chip.place(text, x: 10, y: (chipHeight - text.frame.height) / 2)
            row.addSubview(chip)
        }
    }

    private func toggleRow(_ title: String, detail: String, isOn: Bool, action: SettingsPanelAction, popup: (String, SettingsPanelAction)? = nil, theme: PanelTheme) -> SettingsRow {
        SettingsRow(height: 50) { [weak self] row, width in
            let toggle = ToggleSwitch(isOn: isOn, theme: theme, accessibilityLabel: title) { self?.actions.performSettingsAction(action) }
            var rightEdge = width - 12 - toggle.frame.width
            row.place(toggle, x: rightEdge, y: 15)
            if let popup {
                let button = GlassButton(title: popup.0, style: .popup, theme: theme, height: 22, fontSize: 11.5) { self?.actions.performSettingsAction(popup.1) }
                rightEdge -= button.frame.width + 10
                row.place(button, x: rightEdge, y: 14)
            }
            row.place(makeLabel(title, size: 12.5, weight: .medium, color: theme.primaryText), x: 12, y: 8, width: rightEdge - 22)
            row.place(makeLabel(detail, size: 11, color: theme.secondaryText), x: 12, y: 26, width: rightEdge - 22)
        }
    }

    private func popupRow(_ title: String, detail: String, value: String, action: SettingsPanelAction, theme: PanelTheme) -> SettingsRow {
        SettingsRow(height: 50) { [weak self] row, width in
            let button = GlassButton(title: value, style: .popup, theme: theme, height: 22, fontSize: 11.5) { self?.actions.performSettingsAction(action) }
            let rightEdge = width - 12 - button.frame.width
            row.place(button, x: rightEdge, y: 14)
            row.place(makeLabel(title, size: 12.5, weight: .medium, color: theme.primaryText), x: 12, y: 8, width: rightEdge - 22)
            row.place(makeLabel(detail, size: 11, color: theme.secondaryText), x: 12, y: 26, width: rightEdge - 22)
        }
    }

    private func settingsAccountRow(_ account: CodexAccount, theme: PanelTheme) -> SettingsRow {
        SettingsRow(height: 42) { [weak self] row, width in
            guard let self else { return }
            let tone: PanelTheme.Tone = account.isActive ? PanelTheme.usageTone(for: account.fiveHourRemaining) : .neutral
            row.addSubview(MonogramView(frame: NSRect(x: 12, y: 9, width: 24, height: 24), text: self.state.label(for: account), fill: account.isActive ? theme.tint(tone) : theme.controlFill, textColor: theme.text(tone)))

            let logout = GlassButton(title: "Log Out", style: .text(theme.text(.red)), theme: theme, height: 24) { [weak self] in self?.actions.logoutAccount(account.email) }
            logout.isEnabled = !self.state.isSwitching
            var rightEdge = width - 8 - logout.frame.width
            row.place(logout, x: rightEdge, y: 9)
            let rename = GlassButton(title: "Rename", style: .text(theme.text(.blue)), theme: theme, height: 24) { [weak self] in self?.actions.editAccountLabel(account.email) }
            rightEdge -= rename.frame.width + 2
            row.place(rename, x: rightEdge, y: 9)

            let dotSpace: CGFloat = account.isActive ? 14 : 0
            let email = makeLabel(account.email, size: 12.5, weight: .medium, color: theme.primaryText)
            let emailWidth = min(email.frame.width, rightEdge - 8 - 44 - dotSpace)
            email.toolTip = account.email
            row.place(email, x: 44, y: (42 - email.frame.height) / 2, width: emailWidth)
            if account.isActive {
                let dot = DotView(frame: NSRect(x: 44 + emailWidth + 7, y: 18, width: 7, height: 7), color: theme.color(.green))
                dot.toolTip = "Active account"
                row.addSubview(dot)
            }
        }
    }

    private func settingsClaudeRow(_ account: ClaudeAccountSummary, theme: PanelTheme) -> SettingsRow {
        SettingsRow(height: 42) { [weak self] row, width in
            guard let self else { return }
            let tone: PanelTheme.Tone = account.needsLogin ? .red : account.isActive ? .green : .neutral
            row.addSubview(MonogramView(frame: NSRect(x: 12, y: 9, width: 24, height: 24), text: String(account.title.prefix(1)).uppercased(), fill: tone == .neutral ? theme.controlFill : theme.tint(tone), textColor: theme.text(tone)))
            var rightEdge = width - 8
            if account.needsLogin {
                let signIn = GlassButton(title: "Sign In", style: .text(theme.text(.blue)), theme: theme, height: 24) { [weak self] in self?.actions.claude.signIn(account.email) }
                rightEdge -= signIn.frame.width
                row.place(signIn, x: rightEdge, y: 9)
            }
            if !account.isActive {
                let remove = GlassButton(title: "Remove", style: .text(theme.text(.red)), theme: theme, height: 24) { [weak self] in self?.actions.claude.remove(account.id) }
                rightEdge -= remove.frame.width + 2
                row.place(remove, x: rightEdge, y: 9)
            }
            let title = makeLabel(account.title, size: 12.5, weight: .medium, color: theme.primaryText)
            let titleWidth = min(title.frame.width, (rightEdge - 52) * 0.45)
            row.place(title, x: 44, y: (42 - title.frame.height) / 2, width: titleWidth)
            let email = makeLabel(account.email, size: 11, color: theme.secondaryText)
            email.toolTip = "\(account.email) · \(account.plan)"
            row.place(email, x: 44 + titleWidth + 6, y: (42 - email.frame.height) / 2 + 1, width: max(0, rightEdge - 8 - (44 + titleWidth + 6) - (account.isActive ? 14 : 0)))
            if account.isActive {
                let dot = DotView(frame: NSRect(x: min(email.frame.maxX + 7, rightEdge - 14), y: 18, width: 7, height: 7), color: theme.color(.green))
                dot.toolTip = "Active account"
                row.addSubview(dot)
            }
        }
    }

    private func navRow(_ title: String, value: String?, symbol: String? = nil, tint: PanelTheme.Tone = .neutral, tag: String? = nil, action: SettingsPanelAction, theme: PanelTheme) -> SettingsRow {
        SettingsRow(height: 40) { [weak self] row, width in
            let tile = TileView(frame: row.bounds, fill: .clear, cornerRadius: 0, hoverFill: theme.controlFill.withAlphaComponent(0.5), accessibilityLabel: title) {
                self?.actions.performSettingsAction(action)
            }
            row.addSubview(tile)
            var textX: CGFloat = 12
            if let symbol {
                tile.addSubview(MonogramView(frame: NSRect(x: 12, y: 8, width: 24, height: 24), text: "", fill: theme.tint(tint), textColor: theme.text(tint), symbol: symbol))
                textX = 44
            }
            let chevron = SymbolIconView(frame: .zero, symbol: "chevron.right", color: theme.tertiaryText, pointSize: 10, weight: .bold)
            tile.place(chevron, x: width - 12 - 8, y: 14, width: 8, height: 12)
            var rightEdge = width - 12 - 8 - 8
            if let tag {
                let tagView = CapsuleTagView(text: tag, theme: theme, foreground: theme.text(.indigo), background: theme.tint(.indigo))
                rightEdge -= tagView.frame.width
                tile.place(tagView, x: rightEdge, y: 11)
                rightEdge -= 8
            }
            let titleLabel = makeLabel(title, size: 12.5, weight: .medium, color: symbol != nil && tint == .blue ? theme.text(.blue) : theme.primaryText)
            tile.place(titleLabel, x: textX, y: (40 - titleLabel.frame.height) / 2, width: min(titleLabel.frame.width + 2, rightEdge - textX))
            if let value {
                let valueLabel = makeLabel(value, size: 11, color: theme.secondaryText, alignment: .right, monospacedDigits: true)
                let valueX = textX + titleLabel.frame.width + 12
                tile.place(valueLabel, x: valueX, y: (40 - valueLabel.frame.height) / 2, width: max(0, rightEdge - valueX))
            }
        }
    }

    private func updatesRow(theme: PanelTheme) -> SettingsRow {
        SettingsRow(height: 40) { [weak self] row, width in
            guard let self else { return }
            let check = GlassButton(title: "Check", style: .popup, theme: theme, height: 22, fontSize: 11.5) { [weak self] in self?.actions.checkUpdates() }
            check.image = nil
            check.setFrameSize(NSSize(width: check.frame.width - 12, height: 22))
            let rightEdge = width - 12 - check.frame.width
            row.place(check, x: rightEdge, y: 9)
            let title = makeLabel("Updates", size: 12.5, weight: .medium, color: theme.primaryText)
            row.place(title, x: 12, y: (40 - title.frame.height) / 2, width: 100)
            let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
            let update = self.state.healthStatuses.first { $0.title == "Update" }?.value ?? ""
            let status: String?
            switch update {
            case "Current": status = "up to date"
            case "Checking": status = "checking…"
            case "", "Check", "Error", "Unknown": status = nil
            default: status = "\(update) available"
            }
            let value = makeLabel(status.map { "\(version) · \($0)" } ?? version, size: 11, color: theme.secondaryText, alignment: .right, monospacedDigits: true)
            row.place(value, x: 12 + title.frame.width + 12, y: (40 - value.frame.height) / 2, width: rightEdge - 10 - (12 + title.frame.width + 12))
        }
    }

    private func healthRow(theme: PanelTheme) -> SettingsRow {
        let statuses = Array(state.healthStatuses.prefix(8))
        let columns = 2
        let rows = Int(ceil(Double(statuses.count) / Double(columns)))
        return SettingsRow(height: CGFloat(rows) * 22 + 18) { row, width in
            let columnWidth = (width - 24 - 24) / CGFloat(columns)
            for (index, status) in statuses.enumerated() {
                let x = 12 + CGFloat(index % columns) * (columnWidth + 24)
                let y = 10 + CGFloat(index / columns) * 22
                row.addSubview(DotView(frame: NSRect(x: x, y: y + 5, width: 7, height: 7), color: status.color))
                let title = makeLabel(status.title, size: 11, color: theme.secondaryText)
                row.place(title, x: x + 12, y: y, width: 52)
                let value = makeLabel(status.value, size: 11, weight: .semibold, color: theme.primaryText, alignment: .right)
                value.toolTip = status.value
                row.place(value, x: x + 12 + title.frame.width + 4, y: y, width: max(0, columnWidth - 12 - title.frame.width - 4))
            }
        }
    }

    private func autoSwitchPopupText() -> String {
        switch state.autoSwitchMode {
        case .off: return "Off"
        case .ask: return "Ask at \(state.autoSwitchThreshold)%"
        case .threshold: return "At \(state.autoSwitchThreshold)%"
        case .zero: return "Ask at 0%"
        }
    }

    private func autoResumeText() -> String {
        switch state.autoResumeMode {
        case .off: return "Off"
        case .ask: return "Ask first"
        case .idle5: return "Idle 5s"
        case .idle10: return "Idle 10s"
        case .always: return "Always"
        }
    }

}
