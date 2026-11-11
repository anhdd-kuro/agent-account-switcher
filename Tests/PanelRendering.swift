import AppKit
import Foundation

@main
struct PanelRendering {
    static func main() throws {
        let output = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "/tmp/account-switcher-panels", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let now = Date()
        var switched: String?
        var settingsAction: SettingsPanelAction?
        let actions = AccountPanelActions(
            switchAccount: { switched = $0 }, logoutAccount: { _ in }, refresh: {}, checkUpdates: {},
            editAccountLabel: { _ in }, showResetCredits: {}, redeemResetCredit: { _, _ in },
            selectRouteBProfile: { _ in }, performSettingsAction: { settingsAction = $0 }, close: {},
            claude: ClaudePanelActions(switchAccount: { _ in }, signIn: { _ in }, remove: { _ in }, useReset: { _, _ in }),
            analytics: AnalyticsPanelActions(selectPeriod: { _ in }, refresh: {})
        )
        let cases: [(String, AccountPanelMode, String)] = [
            ("accounts", .usage, "standard"), ("resets", .resets, "standard"),
            ("settings", .settings, "standard"), ("route-b", .routeB, "standard"),
            ("analytics", .analytics, "standard"), ("empty", .usage, "empty"),
            ("signed-out", .usage, "signed-out"), ("confirm-switch", .usage, "armed"),
            ("overflow", .usage, "overflow"), ("analytics-loading", .analytics, "loading"),
            ("analytics-error", .analytics, "error")
        ]
        for (appearanceName, appearance) in [("dark", NSAppearance.Name.darkAqua), ("light", .aqua)] {
            app.appearance = NSAppearance(named: appearance)
            for (name, mode, scenario) in cases {
                let state = makeState(mode: mode, scenario: scenario, now: now)
                precondition(state == makeState(mode: mode, scenario: scenario, now: now), "equal render inputs must be reusable")
                let view = AccountSwitcherPanelView(state: state, actions: actions)
                let window = NSWindow(contentRect: view.frame, styleMask: .borderless, backing: .buffered, defer: false)
                window.appearance = app.appearance
                window.contentView = view
                view.layoutSubtreeIfNeeded()
                precondition(view.frame.width == 452 && view.frame.height <= AccountSwitcherPanelView.maximumPanelHeight())
                if name == "accounts" {
                    let account = descendants(view).compactMap { $0 as? TileView }.first { $0.accessibilityLabel() == "Switch to backup@example.com" }
                    precondition(account?.accessibilityPerformPress() == true)
                    precondition(switched == "backup@example.com", "account action must carry its email query")
                }
                if name == "confirm-switch" {
                    let confirm = descendants(view).compactMap { $0 as? NSButton }.first { $0.attributedTitle.string == "Confirm" }
                    precondition(confirm != nil)
                    confirm?.performClick(nil)
                    precondition(switched == "backup@example.com")
                }
                if name == "signed-out" {
                    let signIn = descendants(view).compactMap { $0 as? NSButton }.first { $0.attributedTitle.string == "Sign In…" }
                    precondition(signIn != nil)
                    signIn?.performClick(nil)
                    precondition(settingsAction == .addAccount)
                }
                guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { fatalError("Cannot allocate panel image") }
                view.cacheDisplay(in: view.bounds, to: bitmap)
                guard let png = bitmap.representation(using: .png, properties: [:]) else { fatalError("Cannot encode panel image") }
                try png.write(to: output.appendingPathComponent("\(name)-\(appearanceName).png"))
                let geometry = descendants(view).map { child -> [String: Any] in
                    var result: [String: Any] = ["type": String(describing: type(of: child)), "frame": NSStringFromRect(child.frame)]
                    if let label = child as? NSTextField { result["text"] = label.stringValue }
                    if let button = child as? NSButton { result["title"] = button.attributedTitle.string }
                    return result
                }
                try JSONSerialization.data(withJSONObject: geometry, options: [.prettyPrinted, .sortedKeys])
                    .write(to: output.appendingPathComponent("\(name)-\(appearanceName).json"))
                window.contentView = nil
            }
        }
        let standard = makeState(mode: .usage, scenario: "standard", now: now)
        precondition(standard != makeState(mode: .usage, scenario: "new-reset-date", now: now), "changed reset countdown inputs must rebuild the panel")
        print("Rendered \(cases.count * 2) synthetic panels and verified account, confirmation, sign-in, sizing and render-state behavior: \(output.path)")
    }

    private static func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(descendants)
    }

    static func makeState(mode: AccountPanelMode, scenario: String, now: Date) -> AccountPanelState {
        let signedOut = scenario == "signed-out"
        var codex = [
            CodexAccount(selector: "1", email: "active@example.com", plan: "business", fiveHourUsage: "81% (18:00)", weeklyUsage: "64% (Mon 18:00)", fiveHourRemaining: 81, weeklyRemaining: 64, lastActivity: "Now", isActive: true),
            CodexAccount(selector: "2", email: "backup@example.com", plan: "plus", fiveHourUsage: signedOut ? "Login expired" : "24% (19:00)", weeklyUsage: "41% (Tue 19:00)", fiveHourRemaining: signedOut ? nil : 24, weeklyRemaining: signedOut ? nil : 41, lastActivity: "Yesterday", isActive: false)
        ]
        if scenario == "empty" { codex = [] }
        if scenario == "overflow" {
            codex += (3...18).map { i in
                CodexAccount(selector: "\(i)", email: "account-\(i)@example.com", plan: "plus", fiveHourUsage: "52%", weeklyUsage: "32%", fiveHourRemaining: 52, weeklyRemaining: 32, lastActivity: "Yesterday", isActive: false)
            }
        }
        let grant = ClaudeResetGrant(program: ClaudeResetGrant.grantProgram, id: "demo-grant", label: "Full reset", kind: "full", resetsLeft: 1, endsAt: now.addingTimeInterval(5 * 86400), clears: ["five_hour", "seven_day"], usableNow: true, unavailableReason: nil)
        let claude = scenario == "empty" ? [] : [
            ClaudeAccountSummary(id: "demo-personal", title: "Personal", email: "personal@example.com", plan: "Claude Pro", fiveHourRemaining: 68, weeklyRemaining: 53, fiveHourResetAt: now.addingTimeInterval(1800), weeklyResetAt: now.addingTimeInterval(4 * 86400), isActive: true, needsLogin: false, usageError: nil, resets: ClaudeResetStatus(eligible: true, ineligibleReason: nil, grants: [grant]))
        ]
        let credit = ResetCredit(id: "demo-credit", title: "Reset", resetType: "full", status: "available", grantedAt: now.addingTimeInterval(-86400), expiresAt: now.addingTimeInterval(6 * 86400))
        let usage = DirectUsageSnapshot(fiveHour: UsageLimitWindowSnapshot(remainingPercent: 81, resetAt: now.addingTimeInterval(scenario == "new-reset-date" ? 14400 : 7200)), weekly: UsageLimitWindowSnapshot(remainingPercent: 64, resetAt: now.addingTimeInterval(3 * 86400)))
        return AccountPanelState(
            accounts: codex, activeAccount: codex.first, mode: mode, lastUpdatedText: "just now", lastError: nil,
            isSwitching: false, launchAtLoginEnabled: false, remindersEnabled: true, reminderThreshold: 10,
            autoSwitchThreshold: 10, autoSwitchMode: .off, autoResumeMode: .off,
            confirmBeforeSwitching: scenario == "armed", armedSwitchEmail: scenario == "armed" ? "backup@example.com" : nil,
            resetCreditsByEmail: ["active@example.com": ResetCreditsSnapshot(availableCount: 1, credits: [credit], lastUpdatedText: "just now", lastError: nil)],
            healthStatuses: [HealthStatus(title: "Update", value: "Current", color: .systemGreen)],
            routeBProfiles: routeBProviderProfiles, selectedRouteBProfileID: nil,
            usageMode: .both, claudeUsageMode: .both, toolbarDisplayStyle: .detailed,
            activeRefreshInterval: 5, idleRefreshInterval: 30, accountLabels: ["active@example.com": "A", "backup@example.com": "B"],
            claude: ClaudePanelState(accounts: claude, lastError: nil, updatedText: "just now", isSwitching: false, isClaimingReset: false),
            codexUsageByEmail: ["active@example.com": usage],
            cursor: CursorUsageState(isInstalled: scenario != "empty", snapshot: CursorUsageSnapshot(membership: "pro", planUsed: 12, autoUsed: 3, apiUsed: 39, resetAt: now.addingTimeInterval(25 * 86400)), error: nil, updatedAt: now),
            cursorLane: .both,
            menuBarPreview: [.init(logo: "logo-openai", text: "81% 64%", isLow: false, lines: [["5h", "81%", "2h"], ["7d", "64%", "3d"]]), .init(logo: "logo-claude", text: "68% 53%", isLow: false, lines: [["5h", "68%", "30m"], ["7d", "53%", "4d"]])],
            analytics: AnalyticsPanelState(snapshot: scenario == "loading" ? nil : analytics(now: now), status: AnalyticsScanStatus(isScanning: scenario == "loading", processedBytes: 1024, totalBytes: 4096, lastError: scenario == "error" ? "Synthetic read error" : nil), period: .month),
            toastOnReset: true, confettiOnReset: true, reopenOnSameDesktop: true
        )
    }

    private static func analytics(now: Date) -> AnalyticsSnapshot {
        let cal = Calendar.current
        let today = cal.startOfDay(for: now)
        let totals = AnalyticsTotals(input: 1000, cached: 500, cacheCreation: 0, output: 300, reasoning: 0, total: 1800, conversations: 2, costUSD: 0.12)
        let model = AnalyticsModelShare(name: "example-model", tokens: 1800, share: 100)
        let heat = (0..<182).map { i in AnalyticsHeatCell(day: cal.date(byAdding: .day, value: i - 181, to: today)!, tokens: i % 5 == 0 ? 0 : 1800, level: i % 5) }
        return AnalyticsSnapshot(period: .month, from: today, to: today, totals: totals, costIsPartial: false,
            sources: [AnalyticsSourceShare(source: .codex, tokens: 1800, share: 100, modelCount: 1)], topModels: [model],
            last7dTokens: 1800, last30dTokens: 1800, averageDailyTokens: 1800, started: heat.first?.day, activeDays: 30,
            heatmap: heat, trend: [AnalyticsTrendBar(start: today, segments: [model], isFuture: false)],
            daily: [AnalyticsDay(day: today, totals: totals, modelTokens: ["example-model": 1800])],
            projects: [AnalyticsProject(name: "example/project", totals: totals)], scannedAt: now)
    }
}
