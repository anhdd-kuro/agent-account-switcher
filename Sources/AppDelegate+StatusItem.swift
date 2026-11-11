import AppKit
import Foundation

extension AppDelegate {
    func configureStatusButton() {
        guard let button = statusItem.button else { return }
        button.title = ""
        button.toolTip = "AI Account Switcher"
        button.image = MenuBarGlyph.symbol("arrow.left.arrow.right", color: nil)
        button.imagePosition = .imageOnly
        button.imageHugsTitle = true
        button.target = self
        button.action = #selector(toggleAccountPanel)
    }

    func updateStatusTitle() {
        let titleKey = statusTitleKey()
        guard titleKey != currentStatusTitleKey else { return }
        currentStatusTitleKey = titleKey
        guard let button = statusItem.button else { return }
        let content = statusItemContent()
        button.title = ""
        button.image = content.image
        button.imagePosition = content.image == nil ? .noImage : (content.title.length == 0 ? .imageOnly : .imageLeading)
        button.attributedTitle = content.title
        button.setAccessibilityLabel(content.accessibilityLabel)
        statusItem.length = NSStatusItem.variableLength
        button.needsDisplay = true
    }

    func clearStatusTitle() {
        currentStatusTitleKey = ""
        guard let button = statusItem.button else { return }
        button.title = ""
        button.attributedTitle = NSAttributedString(string: "")
        button.image = MenuBarGlyph.symbol("arrow.left.arrow.right", color: nil)
        button.imagePosition = .imageOnly
        button.setAccessibilityLabel("AI Account Switcher")
        statusItem.length = NSStatusItem.variableLength
        button.needsDisplay = true
    }

    func statusItemContent() -> (image: NSImage?, title: NSAttributedString, accessibilityLabel: String) {
        let compact = preferences.toolbarDisplayStyle == .compact
        let fontSize: CGFloat = compact ? 11 : 12.5
        let diameter: CGFloat = compact ? 11 : 13
        if let resetStatusText {
            let color: NSColor = resetStatusText.hasPrefix("Switching") ? .systemBlue : .systemOrange
            let image = statusSpinnerFrame.map { MenuBarGlyph.spinner(frame: $0, color: color, diameter: diameter) }
            return (image, statusTitle(resetStatusText, size: fontSize, color: nil), resetStatusText)
        }
        let parts = menuBarUsageParts()
        guard !parts.isEmpty else {
            return (MenuBarGlyph.symbol("arrow.left.arrow.right", color: nil), NSAttributedString(string: ""), "AI Account Switcher")
        }
        let title = MenuBarGlyph.usageTitle(parts.map(\.part), fontSize: fontSize, compact: compact, lowColor: PanelTheme.current(for: nil).color(.red))
        return (nil, title, parts.map(\.spoken).joined(separator: ". "))
    }

    func menuBarUsageParts() -> [(part: MenuBarGlyph.UsagePart, spoken: String)] {
        var parts: [(part: MenuBarGlyph.UsagePart, spoken: String)] = []
        if preferences.usageMode != .off, let account = toolbarStatusAccounts().first {
            if account.needsLogin {
                parts.append((.init(logo: "logo-openai", text: "Sign in", isLow: true), "Codex needs a fresh sign-in"))
            } else {
                let percent = toolbarUsagePercent(for: account)
                let snapshot = directUsageSnapshotsByEmail[account.email]
                let reset = MenuBarGlyph.relativeReset(preferences.usageMode == .fiveHour && account.hasFiveHourLimit ? snapshot?.fiveHour.resetAt : snapshot?.weekly.resetAt)
                if preferences.usageMode == .both, account.hasFiveHourLimit {
                    let five = account.fiveHourRemaining, week = account.weeklyRemaining
                    parts.append((.init(logo: "logo-openai", text: "\(remainingPercentText( five)) \(remainingPercentText( week))", isLow: min(five ?? 100, week ?? 100) < 10, lines: [["5h", remainingPercentText( five), MenuBarGlyph.relativeReset(snapshot?.fiveHour.resetAt) ?? ""], ["7d", remainingPercentText( week), MenuBarGlyph.relativeReset(snapshot?.weekly.resetAt) ?? ""]]), "Codex 5-hour \(remainingPercentText( five)), weekly \(remainingPercentText( week)) left"))
                } else {
                    parts.append((.init(logo: "logo-openai", text: remainingPercentText( percent), isLow: (percent ?? 100) < 10, reset: reset), "Codex \(remainingPercentText( percent)) left"))
                }
            }
        }
        if preferences.claudeUsageMode != .off, let account = claude.active {
            let percent = claudeToolbarPercent(account)
            let reset = account.needsLogin ? nil : MenuBarGlyph.relativeReset(preferences.claudeUsageMode == .fiveHour && account.hasFiveHourLimit ? account.fiveHourResetAt : account.weeklyResetAt)
            if preferences.claudeUsageMode == .both, account.hasFiveHourLimit, !account.needsLogin {
                let five = account.fiveHourRemaining, week = account.weeklyRemaining
                parts.append((.init(logo: "logo-claude", text: "\(remainingPercentText( five)) \(remainingPercentText( week))", isLow: min(five ?? 100, week ?? 100) < 10, lines: [["5h", remainingPercentText( five), MenuBarGlyph.relativeReset(account.fiveHourResetAt) ?? ""], ["7d", remainingPercentText( week), MenuBarGlyph.relativeReset(account.weeklyResetAt) ?? ""]]), "Claude \(account.title) 5-hour \(remainingPercentText( five)), weekly \(remainingPercentText( week)) left"))
            } else {
                parts.append((.init(logo: "logo-claude", text: account.needsLogin ? "Sign in" : remainingPercentText( percent), isLow: account.needsLogin || (percent ?? 100) < 10, reset: reset), "Claude \(account.title) \(remainingPercentText( percent)) left"))
            }
        }
        if preferences.cursorLane != .off, let snapshot = cursor.state.snapshot {
            let auto = snapshot.autoUsed.map { 100 - $0 }
            let api = snapshot.apiUsed.map { 100 - $0 }
            switch preferences.cursorLane {
            case .both:
                if let auto, let api {
                    parts.append((.init(logo: "logo-cursor", text: "\(auto)% \(api)%", isLow: min(auto, api) < 10, lines: [["Auto", "\(auto)%", MenuBarGlyph.relativeReset(snapshot.resetAt) ?? ""], ["API", "\(api)%", MenuBarGlyph.relativeReset(snapshot.resetAt) ?? ""]]), "Cursor Auto \(auto)%, API \(api)% left"))
                }
            case .auto, .api:
                let isAuto = preferences.cursorLane == .auto
                if let left = isAuto ? auto : api {
                    parts.append((.init(logo: "logo-cursor", text: "\(left)%", isLow: left < 10, reset: MenuBarGlyph.relativeReset(snapshot.resetAt)), "Cursor \(isAuto ? "Auto" : "API") \(left)% left"))
                }
            case .off:
                break
            }
        }
        return parts
    }

    func statusTitle(_ text: String, size: CGFloat, color: NSColor?) -> NSAttributedString {
        NSAttributedString(string: text, attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: size, weight: .semibold),
            .foregroundColor: color ?? NSColor.labelColor
        ])
    }

    func claudeToolbarPercent(_ account: ClaudeAccountSummary) -> Int? {
        if account.needsLogin { return 0 }
        return preferences.claudeUsageMode == .fiveHour && account.hasFiveHourLimit ? account.fiveHourRemaining : account.weeklyRemaining
    }

    func statusTitleKey() -> String {
        if let resetStatusText {
            return "reset|\(resetStatusText)|\(statusSpinnerFrame.map { String($0 % 12) } ?? "-")|\(preferences.toolbarDisplayStyle.rawValue)"
        }
        return menuBarUsageParts().map { "\($0.part.logo)|\($0.part.text)|\($0.part.isLow)|\($0.part.reset ?? "")|\($0.part.lines?.map { $0.joined(separator: ",") }.joined(separator: ";") ?? "")" }.joined(separator: "||") + "|\(preferences.toolbarDisplayStyle.rawValue)"
    }

    func setResetStatus(_ text: String?) {
        resetStatusText = text
        currentStatusTitleKey = ""
        updateStatusTitle()
    }

    func toolbarUsagePercent(for account: CodexAccount) -> Int? {
        switch account.hasFiveHourLimit ? preferences.usageMode : .weekly {
        case .fiveHour:
            return account.fiveHourRemaining
        case .weekly, .both, .off:
            return account.weeklyRemaining
        }
    }

    func toolbarAccounts() -> [CodexAccount] {
        accounts.sorted { left, right in
            let leftPriority = toolbarSortPriority(for: left)
            let rightPriority = toolbarSortPriority(for: right)
            if leftPriority != rightPriority {
                return leftPriority < rightPriority
            }
            return left.email.localizedCaseInsensitiveCompare(right.email) == .orderedAscending
        }
    }

    func toolbarStatusAccounts() -> [CodexAccount] {
        let sortedAccounts = toolbarAccounts()
        if let active = sortedAccounts.first(where: { $0.isActive }) {
            return [active]
        }
        return sortedAccounts.prefix(1).map { $0 }
    }

    func toolbarSortPriority(for account: CodexAccount) -> Int {
        CodexAccountOrdering.priority(label: toolbarLabel(for: account))
    }

    func toolbarLabel(for account: CodexAccount) -> String {
        if let custom = preferences.customLabel(forEmail: account.email), !custom.isEmpty {
            return preferences.limitedLabel(custom).uppercased()
        }
        return preferences.defaultLabel(forEmail: account.email)
    }

    func remainingPercentText(_ remaining: Int?) -> String {
        guard let remaining else { return "--%" }
        return "\(max(0, min(100, remaining)))%"
    }

    @discardableResult
    func beginStatusAnimation(title: String) -> Int {
        switchAnimationTimer?.invalidate()
        statusAnimationGeneration += 1
        switchAnimationFrame = 0
        statusAnimationTitle = title
        updateStatusAnimationTitle()
        let animationTimer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.switchAnimationFrame += 1
            self.updateStatusAnimationTitle()
        }
        animationTimer.tolerance = 0.02
        RunLoop.main.add(animationTimer, forMode: .common)
        switchAnimationTimer = animationTimer
        return statusAnimationGeneration
    }

    func updateStatusAnimationTitle() {
        statusSpinnerFrame = switchAnimationFrame
        setResetStatus("\(statusAnimationTitle)…")
    }

    func endStatusAnimation(expectedGeneration: Int? = nil) {
        if let expectedGeneration, expectedGeneration != statusAnimationGeneration {
            return
        }
        switchAnimationTimer?.invalidate()
        switchAnimationTimer = nil
        statusSpinnerFrame = nil
        setResetStatus(nil)
    }

    func watchedLimits() -> [WatchedLimit] {
        var limits: [WatchedLimit] = []
        for (email, snapshot) in directUsageSnapshotsByEmail {
            let name = accounts.first { $0.email == email }.map { preferences.displayLabel(for: $0) } ?? email
            limits.append(WatchedLimit(key: "codex|\(email)|5h", title: "Codex \(name) 5h", remaining: snapshot.fiveHour.remainingPercent))
            limits.append(WatchedLimit(key: "codex|\(email)|7d", title: "Codex \(name) 7d", remaining: snapshot.weekly.remainingPercent))
        }
        for account in claude.accounts where !account.needsLogin {
            if account.hasFiveHourLimit, let remaining = account.fiveHourRemaining {
                limits.append(WatchedLimit(key: "claude|\(account.id)|5h", title: "Claude \(account.title) 5h", remaining: remaining))
            }
            if let remaining = account.weeklyRemaining {
                limits.append(WatchedLimit(key: "claude|\(account.id)|7d", title: "Claude \(account.title) 7d", remaining: remaining))
            }
        }
        if let snapshot = cursor.state.snapshot {
            for (name, used) in [("Auto", snapshot.autoUsed), ("API", snapshot.apiUsed)] {
                if let used { limits.append(WatchedLimit(key: "cursor|\(name)", title: "Cursor \(name)", remaining: 100 - used)) }
            }
        }
        return limits
    }

    func celebrateLimitResets() {
        let resets = limitResetWatcher.observe(watchedLimits())
        guard !resets.isEmpty else { return }
        Celebration.celebrate(resets, anchor: statusItem.button?.window?.frame)
    }
}
