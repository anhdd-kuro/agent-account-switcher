import AppKit
import Foundation

final class AccountSwitcherPanelView: NSView {
    static let panelWidth: CGFloat = 452
    let inset: CGFloat = 12
    var contentWidth: CGFloat { Self.panelWidth - inset * 2 }
    private var builtForDark: Bool?
    private var theme: PanelTheme { PanelTheme.current(for: effectiveAppearance) }

    let state: AccountPanelState
    let actions: AccountPanelActions
    private var bodyScrollView: NSScrollView?
    private static var analyticsBreakdown: AnalyticsBreakdownMode = .daily

    init(state: AccountPanelState, actions: AccountPanelActions) {
        self.state = state
        self.actions = actions
        super.init(frame: NSRect(origin: .zero, size: Self.preferredSize(mode: state.mode, accountCount: state.accounts.count + state.claude.accounts.count)))
        wantsLayer = true
        build()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isFlipped: Bool { true }
    static func preferredSize(mode: AccountPanelMode, accountCount: Int) -> NSSize {
        switch mode {
        case .usage:
            return NSSize(width: panelWidth, height: CGFloat(330 + max(0, accountCount - 1) * 74))
        case .analytics:
            return NSSize(width: panelWidth, height: 900)
        case .settings:
            return NSSize(width: panelWidth, height: 680)
        case .resets:
            return NSSize(width: panelWidth, height: 560)
        case .routeB:
            return NSSize(width: panelWidth, height: 520)
        }
    }

    static func maximumPanelHeight() -> CGFloat {
        let visible = NSScreen.main?.visibleFrame.height ?? 900
        return max(420, visible - 24)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        if builtForDark != theme.isDark {
            build()
        }
    }

    private var showsTabs: Bool { state.mode != .routeB }

    private func build() {
        bodyScrollView = nil
        subviews.forEach { $0.removeFromSuperview() }
        let theme = self.theme
        builtForDark = theme.isDark

        let header = FlippedContainerView(frame: NSRect(x: 0, y: 0, width: Self.panelWidth, height: 0))
        var headerHeight = buildToolbar(into: header, theme: theme)
        if showsTabs {
            headerHeight = buildTabs(into: header, y: headerHeight, theme: theme)
        }
        header.frame.size.height = headerHeight

        let body = FlippedContainerView(frame: NSRect(x: 0, y: 0, width: Self.panelWidth, height: 0))
        let bodyHeight: CGFloat
        switch state.mode {
        case .usage:
            bodyHeight = buildAccountsBody(into: body, theme: theme)
        case .analytics:
            bodyHeight = buildAnalyticsBody(into: body, theme: theme)
        case .settings:
            bodyHeight = buildSettingsBody(into: body, theme: theme)
        case .resets:
            bodyHeight = buildResetsBody(into: body, theme: theme)
        case .routeB:
            bodyHeight = buildRouteBBody(into: body, theme: theme)
        }
        body.frame.size.height = bodyHeight

        let footer = FlippedContainerView(frame: NSRect(x: 0, y: 0, width: Self.panelWidth, height: 0))
        let footerHeight = buildFooter(into: footer, theme: theme)
        footer.frame.size.height = footerHeight

        let availableBody = Self.maximumPanelHeight() - headerHeight - footerHeight
        let visibleBody = min(bodyHeight, availableBody)
        setFrameSize(NSSize(width: Self.panelWidth, height: ceil(headerHeight + visibleBody + footerHeight)))

        let background = GlassPanelBackground(frame: bounds, theme: theme)
        addSubview(background)
        let content = background.contentView

        content.addSubview(header)
        if bodyHeight > availableBody {
            let scroll = NSScrollView(frame: NSRect(x: 0, y: headerHeight, width: Self.panelWidth, height: visibleBody))
            scroll.drawsBackground = false
            scroll.contentView.drawsBackground = false
            scroll.borderType = .noBorder
            scroll.hasVerticalScroller = true
            scroll.autohidesScrollers = true
            scroll.scrollerStyle = .overlay
            scroll.documentView = body
            bodyScrollView = scroll
            content.addSubview(scroll)
            if ProcessInfo.processInfo.environment["CODEX_ACCOUNT_SWITCHER_DEMO"] == "1",
               ProcessInfo.processInfo.environment["CODEX_ACCOUNT_SWITCHER_SCROLL_TO_END"] == "1" {
                body.scroll(NSPoint(x: 0, y: bodyHeight - visibleBody))
            }
        } else {
            body.frame.origin = NSPoint(x: 0, y: headerHeight)
            content.addSubview(body)
        }
        footer.frame.origin = NSPoint(x: 0, y: headerHeight + visibleBody)
        content.addSubview(footer)
    }

    private func buildToolbar(into view: NSView, theme: PanelTheme) -> CGFloat {
        let glyph = TileView(frame: NSRect(x: 16, y: 14, width: 28, height: 28), fill: theme.controlFill, border: theme.controlBorder, cornerRadius: 8)
        glyph.place(SymbolIconView(frame: .zero, symbol: state.mode == .routeB ? "point.3.connected.trianglepath.dotted" : "arrow.left.arrow.right", color: theme.primaryText, pointSize: 12), x: 6, y: 6, width: 16, height: 16)
        view.addSubview(glyph)

        var rightEdge = Self.panelWidth - 14
        if state.mode == .routeB {
            let back = GlassButton(title: "Settings", style: .secondary, theme: theme) { [weak self] in
                self?.actions.performSettingsAction(.settingsView)
            }
            rightEdge -= back.frame.width
            view.place(back, x: rightEdge, y: 14)
        } else {
            let more = GlassButton(symbol: "ellipsis", style: .icon, theme: theme, accessibilityLabel: "More options") {}
            more.target = self
            more.action = #selector(showMoreMenu(_:))
            rightEdge -= more.frame.width
            view.place(more, x: rightEdge, y: 14)

            let refreshButton = GlassButton(symbol: "arrow.clockwise", style: .icon, theme: theme, accessibilityLabel: state.mode == .resets ? "Refresh reset credits" : (state.mode == .analytics ? "Rescan usage logs" : "Refresh all accounts")) { [weak self] in
                guard let self else { return }
                if self.state.mode == .analytics {
                    self.actions.analytics.refresh()
                    return
                }
                if self.state.mode == .resets {
                    self.actions.performSettingsAction(.resetCreditsView)
                }
                self.actions.refresh()
            }
            rightEdge -= refreshButton.frame.width + 8
            view.place(refreshButton, x: rightEdge, y: 14)
        }

        let textWidthAvailable = rightEdge - 10 - 54
        let title = makeLabel(state.mode == .routeB ? "Route B" : "AI Accounts", size: 13, weight: .semibold, color: theme.primaryText)
        view.place(title, x: 54, y: 12, width: textWidthAvailable)

        let (subtitle, isWarning) = toolbarSubtitle()
        let subtitleLabel = makeLabel(subtitle, size: 11, color: isWarning ? theme.text(.orange) : theme.secondaryText, monospacedDigits: true)
        subtitleLabel.toolTip = subtitle
        view.place(subtitleLabel, x: 54, y: 29, width: textWidthAvailable)
        return 54
    }

    private func toolbarSubtitle() -> (String, Bool) {
        switch state.mode {
        case .usage:
            if let lastError = state.lastError, !lastError.isEmpty, state.activeAccount == nil {
                return (lastError, true)
            }
            if state.isSwitching || state.claude.isSwitching {
                return ("Switching accounts…", false)
            }
            return (state.lastUpdatedText == "refreshing..." ? "Refreshing…" : "Updated \(state.lastUpdatedText)", state.lastUpdatedText.hasPrefix("stale"))
        case .analytics:
            return state.analytics.model(actions: actions.analytics).subtitle
        case .settings:
            let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
            return ("Version \(version)", false)
        case .resets:
            return (resetCreditsSubtitle(), resetCreditsSummaryState().hasError)
        case .routeB:
            return ("Secondary profiles · preview", false)
        }
    }

    private func buildTabs(into view: NSView, y: CGFloat, theme: PanelTheme) -> CGFloat {
        let summary = resetCreditsSummaryState()
        let badge: String? = summary.knownTotal > 0 ? "\(summary.knownTotal)" : nil
        let tabs = SegmentedTabsView(
            frame: NSRect(x: inset, y: y, width: contentWidth, height: 28),
            theme: theme,
            segments: [
                .init(title: "Accounts", badge: nil, isSelected: state.mode == .usage) { [weak self] in
                    self?.actions.performSettingsAction(.usageView)
                },
                .init(title: "Analytics", badge: nil, isSelected: state.mode == .analytics) { [weak self] in
                    self?.actions.performSettingsAction(.analyticsView)
                },
                .init(title: "Resets", badge: badge, isSelected: state.mode == .resets) { [weak self] in
                    self?.actions.performSettingsAction(.resetCreditsView)
                },
                .init(title: "Settings", badge: nil, isSelected: state.mode == .settings) { [weak self] in
                    self?.actions.performSettingsAction(.settingsView)
                }
            ]
        )
        view.addSubview(tabs)
        return y + 28 + 12
    }

    @objc private func showMoreMenu(_ sender: NSButton) {
        let menu = NSMenu()
        func add(_ title: String, _ action: SettingsPanelAction) {
            let item = NSMenuItem(title: title, action: #selector(moreMenuItemChosen(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = action.rawValue
            menu.addItem(item)
        }
        add("Add Account…", .addAccount)
        add("Device Login…", .addDeviceAccount)
        add("Rename Accounts…", .editLabels)
        menu.addItem(.separator())
        add("Add Claude Account…", .addClaudeAccount)
        menu.addItem(.separator())
        add("Refresh Rate…", .editRefresh)
        add("Check for Updates…", .checkUpdates)
        add("Diagnostics…", .diagnostics)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit Account Switcher", action: #selector(quitPressed), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 4), in: sender)
    }

    @objc private func moreMenuItemChosen(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let action = SettingsPanelAction(rawValue: raw) else { return }
        actions.performSettingsAction(action)
    }

    @objc private func quitPressed() {
        actions.close()
    }

    private func buildFooter(into view: NSView, theme: PanelTheme) -> CGFloat {
        let height: CGFloat = 48
        view.addSubview(HairlineView(frame: NSRect(x: 0, y: 0, width: Self.panelWidth, height: 0.5), color: theme.hairline))

        let quit = GlassButton(symbol: "power", style: .icon, theme: theme, accessibilityLabel: "Quit Account Switcher") { [weak self] in
            self?.actions.close()
        }
        quit.toolTip = "Quit Account Switcher"
        var rightEdge = Self.panelWidth - 12 - quit.frame.width
        view.place(quit, x: rightEdge, y: 10)

        switch state.mode {
        case .usage:
            let autoTitle = state.autoSwitchMode == .off ? "Auto-switch off" : autoSwitchFooterText()
            let auto = GlassButton(title: autoTitle, style: .text(theme.secondaryText), theme: theme, height: 22, fontSize: 11) { [weak self] in
                self?.actions.performSettingsAction(.editAutoSwitch)
            }
            auto.toolTip = "Change automatic switching"
            rightEdge -= auto.frame.width + 6
            view.place(auto, x: rightEdge, y: 13)

            let summary = resetCreditsSummaryState()
            if summary.knownTotal > 0 {
                let text = summary.knownTotal == 1 ? "1 reset available" : "\(summary.knownTotal) resets available"
                let link = GlassButton(title: text, symbol: "chevron.right", style: .text(theme.text(.blue)), theme: theme, height: 24) { [weak self] in
                    self?.actions.showResetCredits()
                }
                view.place(link, x: 9, y: 12)
            } else {
                let text = summary.knownAccounts == 0 ? (summary.hasError ? "Resets unavailable" : "Checking resets…") : "No resets available"
                view.place(makeLabel(text, size: 12, color: theme.tertiaryText), x: 16, y: 16, width: rightEdge - 24)
            }
        case .analytics:
            view.place(makeLabel("Estimated from local Codex and Claude logs", size: 11, color: theme.tertiaryText), x: 16, y: 17, width: rightEdge - 24)
        case .settings:
            view.place(makeLabel("Changes apply instantly", size: 11, color: theme.tertiaryText), x: 16, y: 17, width: rightEdge - 24)
        case .resets:
            view.place(makeLabel("Using a reset asks for confirmation first", size: 11, color: theme.tertiaryText), x: 16, y: 17, width: rightEdge - 24)
        case .routeB:
            view.place(makeLabel("Profile selection only · execution disabled", size: 11, color: theme.tertiaryText), x: 16, y: 17, width: rightEdge - 24)
        }
        return height
    }

    private func autoSwitchFooterText() -> String {
        switch state.autoSwitchMode {
        case .off: return "Auto-switch off"
        case .ask: return "Auto-switch asks at \(state.autoSwitchThreshold)%"
        case .threshold: return "Auto-switch at \(state.autoSwitchThreshold)%"
        case .zero: return "Auto-switch asks at 0%"
        }
    }

    private func buildAnalyticsBody(into body: NSView, theme: PanelTheme) -> CGFloat {
        AnalyticsPanelBuilder(
            model: state.analytics.model(actions: actions.analytics),
            theme: theme,
            inset: inset,
            width: contentWidth,
            breakdown: Self.analyticsBreakdown,
            selectBreakdown: { [weak self] mode in
                Self.analyticsBreakdown = mode
                self?.rebuildKeepingScroll()
            }
        ).build(into: body)
    }
    private func rebuildKeepingScroll() {
        let offset = bodyScrollView?.contentView.bounds.origin ?? .zero
        let oldHeight = frame.height
        build()
        if let restored = bodyScrollView,
           let document = restored.documentView {
            let maxY = max(0, document.frame.height - restored.contentView.bounds.height)
            restored.contentView.scroll(to: NSPoint(x: 0, y: min(offset.y, maxY)))
            restored.reflectScrolledClipView(restored.contentView)
        }
        guard let window, frame.height != oldHeight else { return }
        var windowFrame = window.frame
        windowFrame.origin.y += windowFrame.height - frame.height
        windowFrame.size.height = frame.height
        window.setFrame(windowFrame, display: true)
    }

}
