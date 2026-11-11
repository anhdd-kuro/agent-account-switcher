import Foundation

/// A Claude limit reset an account can use. Claude Code reads these from
/// `/api/oauth/usage` and names the programs `cedar_ember` (granted resets with ids)
/// and `juniper_tide` (the once-a-week 5-hour reset).
struct ClaudeResetGrant: Equatable {
    static let grantProgram = "cedar_ember"
    static let fiveHourProgram = "juniper_tide"

    static func isValidID(_ text: String) -> Bool {
        text.range(of: #"^[a-z0-9_-]{1,40}$"#, options: .regularExpression) != nil
    }

    let program: String
    let id: String
    let label: String
    /// `session`, `weekly`, `full`, or empty when the server does not say.
    let kind: String
    let resetsLeft: Int
    let endsAt: Date?
    let clears: [String]
    let usableNow: Bool
    let unavailableReason: String?

    var title: String {
        switch kind {
        case "session": return "5-hour reset"
        case "weekly": return "Weekly reset"
        case "full": return "Full reset"
        default: return "Limit reset"
        }
    }

    var clearedText: String { ClaudeResetGrant.describe(clears) }

    var unavailableText: String? {
        guard !usableNow else { return nil }
        switch unavailableReason {
        case "cooldown": return "A reset was used recently"
        case "needs_limit": return "Usable once you reach a limit it clears"
        case "blocked_five_hour", "blocked_seven_day", "blocked_opus", "blocked_sonnet", "blocked_other", "cannot_clear":
            return "Doesn't clear the limit you are at"
        default: return "Can't be used right now"
        }
    }

    static func describe(_ limits: [String]) -> String {
        var names: [String] = []
        for limit in limits {
            let name: String
            switch limit {
            case "five_hour": name = "5-hour"
            case "seven_day", "seven_day_overage_included": name = "weekly"
            case "seven_day_opus": name = "weekly Opus"
            case "seven_day_sonnet": name = "weekly Sonnet"
            default: name = "weekly \(limit.replacingOccurrences(of: "seven_day_", with: "").replacingOccurrences(of: "_", with: " "))"
            }
            if !names.contains(name) { names.append(name) }
        }
        return names.joined(separator: " + ")
    }
}

struct ClaudeResetStatus: Equatable {
    let eligible: Bool
    let ineligibleReason: String?
    /// Grants with resets left that are not paused, in server order; the 5-hour reset last.
    let grants: [ClaudeResetGrant]

    var availableCount: Int { grants.reduce(0) { $0 + $1.resetsLeft } }
    var usableCount: Int { grants.filter(\.usableNow).reduce(0) { $0 + $1.resetsLeft } }

    static func parse(usage: [String: Any]) -> ClaudeResetStatus? {
        let cedar = usage["cedar_ember"] as? [String: Any]
        let juniper = usage["juniper_tide"] as? [String: Any]
        guard cedar != nil || juniper != nil else { return nil }

        var grants: [ClaudeResetGrant] = []
        var eligible = false
        var reason: String?
        if let cedar, let isEligible = cedar["eligible"] as? Bool {
            eligible = isEligible
            reason = cedar["ineligible_reason"] as? String
            if isEligible {
                grants = (cedar["grants"] as? [Any] ?? []).compactMap { parseGrant($0) }
            }
        }
        if let juniper, juniper["eligible"] as? Bool == true {
            eligible = true
            if juniper["available"] as? Bool == true {
                grants.append(ClaudeResetGrant(
                    program: ClaudeResetGrant.fiveHourProgram,
                    id: ClaudeResetGrant.fiveHourProgram,
                    label: "Reset your 5-hour limit now; once a week, still counts toward your weekly limit",
                    kind: "session",
                    resetsLeft: 1,
                    endsAt: nil,
                    clears: ["five_hour"],
                    usableNow: true,
                    unavailableReason: nil
                ))
            }
        }
        return ClaudeResetStatus(eligible: eligible, ineligibleReason: eligible ? nil : reason, grants: grants)
    }

    static let maxResetsPerGrant = 1000

    private static func parseGrant(_ raw: Any) -> ClaudeResetGrant? {
        guard let grant = raw as? [String: Any],
              let id = grant["id"] as? String, ClaudeResetGrant.isValidID(id),
              let left = (grant["resets_left"] as? NSNumber)?.intValue, left > 0, left <= maxResetsPerGrant,
              grant["paused"] as? Bool != true else {
            return nil
        }
        return ClaudeResetGrant(
            program: ClaudeResetGrant.grantProgram,
            id: id,
            label: grant["label"] as? String ?? "",
            kind: grant["type"] as? String ?? "",
            resetsLeft: left,
            endsAt: (grant["ends_at"] as? String).flatMap(ISO8601Timestamp.parse),
            clears: (grant["clears"] as? [Any] ?? []).compactMap { $0 as? String },
            usableNow: grant["usable_now"] as? Bool ?? false,
            unavailableReason: grant["unavailable_reason"] as? String
        )
    }
}

enum ClaudeResetClaimResult: Equatable {
    /// `confirmed` is false when the server accepted the claim but could not confirm the refill yet.
    case reset(confirmed: Bool, cleared: String)
    case refused(String)
}

/// Request shapes for Anthropic's reset endpoint, matching what Claude Code sends.
enum ClaudeResetAPI {
    static let usageQuery = "cedar_ember=1&skip_spend=1"
    static let fallbackCLIVersion = "2.1.319"

    private static func isRequestID(_ text: String) -> Bool {
        text.range(of: #"^[A-Za-z0-9_-]{1,64}$"#, options: .regularExpression) != nil
    }

    static func claimURL(organizationID: String) -> URL? {
        guard organizationID.range(of: #"^[A-Za-z0-9-]{1,64}$"#, options: .regularExpression) != nil else { return nil }
        return URL(string: "https://api.anthropic.com/api/organizations/\(organizationID)/reset_rate_limits")
    }

    static func claimBody(program: String, grantID: String, requestID: String) -> [String: String]? {
        switch program {
        case ClaudeResetGrant.fiveHourProgram:
            return ["program": program]
        case ClaudeResetGrant.grantProgram:
            guard ClaudeResetGrant.isValidID(grantID), isRequestID(requestID) else { return nil }
            return ["program": program, "grant_id": grantID, "request_id": requestID]
        default:
            return nil
        }
    }

    static func parseClaim(_ object: [String: Any]) -> ClaudeResetClaimResult {
        let reason = object["reason"] as? String
        switch object["result"] as? String {
        case "reset":
            let unconfirmed = reason == "reset_unconfirmed" || reason == "stamp_indeterminate"
            let cleared = ClaudeResetGrant.describe((object["cleared"] as? [Any] ?? []).compactMap { $0 as? String })
            return .reset(confirmed: !unconfirmed, cleared: cleared)
        case "already_used":
            return .refused("This reset was already used.")
        case "not_limited":
            return .refused("This reset can only be used while you are at a limit it clears.")
        case "cooldown":
            let until = (object["cooldown_until"] as? String).flatMap(ISO8601Timestamp.parse)
            return .refused(until.map { "A reset was used recently. Try again after \(DateFormatter.localizedString(from: $0, dateStyle: .medium, timeStyle: .short))." }
                ?? "A reset was used recently. Try again later.")
        case "ineligible":
            return .refused("This account can't use resets right now.")
        case "unavailable":
            return .refused("Resets are unavailable right now. Try again in a moment.")
        default:
            return .refused("The reset response was unreadable. Refresh to check whether it was used.")
        }
    }

    /// Claude Code installs versions as `~/.local/share/claude/versions/<x.y.z>`.
    static func cliVersion(fromPath path: String) -> String {
        let name = URL(fileURLWithPath: path).lastPathComponent
        return name.range(of: #"^\d+\.\d+\.\d+$"#, options: .regularExpression) != nil ? name : fallbackCLIVersion
    }

    /// Anthropic only offers resets to Claude Code, which it recognises by these headers.
    static func userAgent(version: String) -> String {
        "claude-cli/\(version) (external, cli)"
    }

}
