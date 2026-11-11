import AppKit
import Foundation

extension AppDelegate {
    func demoAccounts() -> [CodexAccount] {
        func account(_ selector: String, _ email: String, five: Int?, weekly: Int?, fiveReset: String, weeklyReset: String, active: Bool, expired: Bool = false) -> CodexAccount {
            CodexAccount(
                selector: selector,
                email: email,
                plan: "plus",
                fiveHourUsage: expired ? "Login expired" : "\(five ?? 0)% (\(fiveReset))",
                weeklyUsage: expired ? "Login expired" : "\(weekly ?? 0)% (\(weeklyReset))",
                fiveHourRemaining: expired ? nil : five,
                weeklyRemaining: expired ? nil : weekly,
                lastActivity: active ? "Just now" : "1h ago",
                isActive: active
            )
        }
        let alpha = account("01", "alpha@example.com", five: 31, weekly: 82, fiveReset: "16:40", weeklyReset: "Fri 09:00", active: true)
        let beta = account("02", "beta@example.com", five: 92, weekly: 64, fiveReset: "18:15", weeklyReset: "Fri 09:00", active: false)
        switch demoScenario {
        case "two":
            return [alpha, beta]
        case "four":
            return [
                alpha,
                account("02", "builds@example.com", five: 92, weekly: 64, fiveReset: "18:15", weeklyReset: "Fri 09:00", active: false),
                account("03", "creative@example.com", five: 68, weekly: 18, fiveReset: "20:25", weeklyReset: "Fri 09:00", active: false),
                account("04", "demo@example.com", five: nil, weekly: nil, fiveReset: "", weeklyReset: "", active: false, expired: true)
            ]
        default:
            return [
                alpha,
                beta,
                account("03", "gamma@example.com", five: 68, weekly: 41, fiveReset: "20:25", weeklyReset: "Fri 09:00", active: false)
            ]
        }
    }

    func demoResetCreditsByEmail(for accounts: [CodexAccount]) -> [String: ResetCreditsSnapshot] {
        let now = Date()
        var snapshots: [String: ResetCreditsSnapshot] = [:]
        for (index, account) in accounts.enumerated() {
            let expiryDaysByAccount: [[Int]] = [
                [24],
                [5, 10, 19, 24],
                [5, 10, 19, 24]
            ]
            let expiryDays = index < expiryDaysByAccount.count ? expiryDaysByAccount[index] : [14]

            var credits: [ResetCredit] = []
            for (creditIndex, daysUntilExpiry) in expiryDays.enumerated() {
                let grantOffset = TimeInterval(-(30 - daysUntilExpiry) * 86_400)
                let expiryOffset = TimeInterval(daysUntilExpiry * 86_400)
                credits.append(
                    ResetCredit(
                        id: "demo-\(account.selector)-\(creditIndex)",
                        title: "One free rate limit reset",
                        resetType: "codex_rate_limits",
                        status: "available",
                        grantedAt: now.addingTimeInterval(grantOffset),
                        expiresAt: now.addingTimeInterval(expiryOffset)
                    )
                )
            }

            snapshots[account.email] = ResetCreditsSnapshot(
                availableCount: credits.count,
                credits: credits,
                lastUpdatedText: "just now",
                lastError: nil
            )
        }
        return snapshots
    }
}
