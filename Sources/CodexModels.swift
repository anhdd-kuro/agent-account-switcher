import Foundation

struct CodexAccount: Equatable {
    let selector: String
    let email: String
    let plan: String
    let fiveHourUsage: String
    let weeklyUsage: String
    let fiveHourRemaining: Int?
    let weeklyRemaining: Int?
    let lastActivity: String
    let isActive: Bool
    /// Raw `plan_type` from the usage endpoint, e.g. `self_serve_business_prolite`.
    var planType: String? = nil

    /// Pro plans and Business premium (prolite) seats only have a weekly limit; their 5-hour figure is a placeholder.
    var hasFiveHourLimit: Bool { Self.hasFiveHourLimit(plan: plan, planType: planType) }

    static func hasFiveHourLimit(plan: String, planType: String?) -> Bool {
        !(planType ?? plan).lowercased().contains("pro")
    }

    var needsLogin: Bool { fiveHourUsage == "Login expired" || weeklyUsage == "Login expired" }

    var planLabel: String { Self.planLabel(plan: plan, planType: planType) }

    /// Display name for the plan, e.g. "Pro", "Business · Premium" (`self_serve_business_prolite`).
    static func planLabel(plan: String, planType: String?) -> String {
        let known = [planType, plan].compactMap { $0?.lowercased() }.first { !$0.isEmpty && $0 != "unknown" }
        guard let raw = known else { return "Unknown" }
        if raw.contains("business") || raw.contains("team") || raw.contains("enterprise") {
            let tier = raw.contains("enterprise") ? "Enterprise" : "Business"
            return "\(tier) · \(raw.contains("pro") ? "Premium" : "Standard")"
        }
        switch raw {
        case "prolite": return "Pro Lite"
        default: return raw.prefix(1).uppercased() + raw.dropFirst()
        }
    }
}

struct ResetCredit: Equatable {
    let id: String
    let title: String
    let resetType: String
    let status: String
    let grantedAt: Date?
    let expiresAt: Date?
}

struct ResetCreditsSnapshot: Equatable {
    let availableCount: Int?
    let credits: [ResetCredit]
    let lastUpdatedText: String
    let lastError: String?

    var availableCredits: [ResetCredit] {
        credits.filter { $0.status.lowercased() == "available" }
    }

    var displayCount: Int? {
        availableCount ?? (credits.isEmpty ? nil : availableCredits.count)
    }
}

struct UsageLimitWindowSnapshot: Equatable {
    let remainingPercent: Int
    let resetAt: Date?
}

struct DirectUsageSnapshot: Equatable {
    let fiveHour: UsageLimitWindowSnapshot
    let weekly: UsageLimitWindowSnapshot
    var planType: String? = nil
}

struct ResetConsumeReceipt {
    let code: String
    let windowsReset: Int
    let message: String
}

struct ResetVerificationOutcome {
    let resetSnapshot: ResetCreditsSnapshot?
    let usageSnapshot: DirectUsageSnapshot?
    let creditConfirmed: Bool
    let usageConfirmed: Bool
    let attempts: Int
    let detail: String
}

enum ResetCreditsFetchResult {
    case success(ResetCreditsSnapshot)
    case failure(String)
}

enum ResetCreditRedemptionResult {
    case success(ResetConsumeReceipt)
    case failure(String)
}

enum DirectUsageFetchResult {
    case success(DirectUsageSnapshot)
    case failure(String)
}

struct SavedAccountAuth {
    let email: String
    let accessToken: String
    let accountID: String
}

enum SavedAccountAuthResult {
    case success(SavedAccountAuth)
    case failure(String)
}

extension CodexAccount {
    func applying(_ usage: DirectUsageSnapshot) -> CodexAccount {
        let hasFiveHourLimit = CodexAccount.hasFiveHourLimit(plan: self.plan, planType: usage.planType ?? self.planType)
        return CodexAccount(
            selector: self.selector,
            email: self.email,
            plan: self.plan,
            fiveHourUsage: CodexUsageText.direct(usage.fiveHour, weekly: false),
            weeklyUsage: CodexUsageText.direct(usage.weekly, weekly: true),
            fiveHourRemaining: hasFiveHourLimit ? usage.fiveHour.remainingPercent : usage.weekly.remainingPercent,
            weeklyRemaining: usage.weekly.remainingPercent,
            lastActivity: self.lastActivity,
            isActive: self.isActive,
            planType: usage.planType ?? self.planType
        )
    }
}

enum CodexAccountOrdering {
    static func priority(label: String) -> Int {
        switch label {
        case "L": return 0
        case "A": return 1
        default: return 10
        }
    }
}

struct ResetConfirmation {
    let creditConfirmed: Bool
    let usageConfirmed: Bool

    init(previousCreditCount: Int?, currentCreditCount: Int?, receipt: ResetConsumeReceipt, usage: DirectUsageSnapshot?) {
        if let before = previousCreditCount, let after = currentCreditCount {
            creditConfirmed = after < before
        } else {
            creditConfirmed = previousCreditCount == nil && receipt.windowsReset > 0
        }
        usageConfirmed = usage.map {
            $0.fiveHour.remainingPercent >= 95 && (receipt.windowsReset <= 1 || $0.weekly.remainingPercent >= 95)
        } ?? false
    }
}
