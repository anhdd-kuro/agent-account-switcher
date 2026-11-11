import Foundation

struct ClaudeAccountSummary: Equatable {
    let id: String
    let title: String
    let email: String
    let plan: String
    var fiveHourRemaining: Int?
    var weeklyRemaining: Int?
    var fiveHourResetAt: Date?
    var weeklyResetAt: Date?
    var isActive: Bool
    let needsLogin: Bool
    let usageError: String?
    var resets: ClaudeResetStatus? = nil

    /// Verified Ultra (formerly Max 20x) accounts only have a weekly limit. Unverified ones get a temporary
    /// 5-hour limit, so keep showing it while the API still reports usage in that window.
    var hasFiveHourLimit: Bool {
        Self.hasFiveHourLimit(plan: plan, fiveHourRemaining: fiveHourRemaining)
    }

    func retainingUsage(from previous: ClaudeAccountSummary?) -> ClaudeAccountSummary {
        guard usageError != nil, !needsLogin, let previous, previous.id == id,
              previous.fiveHourRemaining != nil || previous.weeklyRemaining != nil else { return self }
        var result = self
        result.fiveHourRemaining = previous.fiveHourRemaining
        result.weeklyRemaining = previous.weeklyRemaining
        result.fiveHourResetAt = previous.fiveHourResetAt
        result.weeklyResetAt = previous.weeklyResetAt
        result.resets = resets ?? previous.resets
        return result
    }

    func settingActive(_ active: Bool) -> ClaudeAccountSummary {
        var result = self
        result.isActive = active
        return result
    }

    var planLabel: String { Self.planLabel(plan: plan) }

    static func planLabel(plan: String) -> String {
        var label = plan.hasPrefix("Claude ") ? String(plan.dropFirst(7)) : plan
        for org in ["Team", "Enterprise"] where label.hasPrefix(org) {
            let isPremium = label.range(of: #"\d+x$"#, options: .regularExpression) != nil
            label = "\(org) · \(isPremium ? "Premium" : "Standard")"
        }
        return label.isEmpty ? "Claude" : label
    }

    static func hasFiveHourLimit(plan: String, fiveHourRemaining: Int?) -> Bool {
        let plan = plan.lowercased()
        let isUltra = plan.contains("ultra") || (plan.contains("max") && plan.hasSuffix("20x"))
        guard isUltra else { return true }
        return (fiveHourRemaining ?? 100) < 100
    }
}

struct ClaudeProfile {
    static let backupServicePrefix = "claude-switcher:"

    let id: String
    let email: String
    let organizationID: String
    let organizationName: String
    let keychainAccount: String
    let keychainService: String
    let oauthAccount: [String: Any]

    static func identity(email: String, organizationID: String) -> String {
        organizationID.isEmpty ? email : "\(email):\(organizationID)"
    }

    var title: String {
        if organizationName.isEmpty || organizationName.hasSuffix("'s Organization") {
            return "Personal"
        }
        return organizationName
    }

    func dictionary() -> [String: Any] {
        [
            "id": id,
            "email": email,
            "organizationID": organizationID,
            "organizationName": organizationName,
            "keychainAccount": keychainAccount,
            "keychainService": keychainService,
            "oauthAccount": oauthAccount
        ]
    }

    init(id: String, email: String, organizationID: String, organizationName: String, keychainAccount: String, keychainService: String, oauthAccount: [String: Any]) {
        self.id = id
        self.email = email
        self.organizationID = organizationID
        self.organizationName = organizationName
        self.keychainAccount = keychainAccount
        self.keychainService = keychainService
        self.oauthAccount = oauthAccount
    }

    init?(dictionary: [String: Any]) {
        guard let email = dictionary["email"] as? String, !email.isEmpty,
              let service = dictionary["keychainService"] as? String, service.hasPrefix(ClaudeProfile.backupServicePrefix) else {
            return nil
        }
        let organizationID = dictionary["organizationID"] as? String ?? ""
        self.init(
            id: ClaudeProfile.identity(email: email, organizationID: organizationID),
            email: email,
            organizationID: organizationID,
            organizationName: dictionary["organizationName"] as? String ?? "",
            keychainAccount: dictionary["keychainAccount"] as? String ?? NSUserName(),
            keychainService: service,
            oauthAccount: dictionary["oauthAccount"] as? [String: Any] ?? [:]
        )
    }

    func with(oauthAccount: [String: Any]) -> ClaudeProfile {
        ClaudeProfile(
            id: id,
            email: email,
            organizationID: organizationID,
            organizationName: oauthAccount["organizationName"] as? String ?? organizationName,
            keychainAccount: keychainAccount,
            keychainService: keychainService,
            oauthAccount: oauthAccount
        )
    }
}

enum ClaudeError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        switch self {
        case .message(let text): return text
        }
    }
}

struct ClaudeCredentialContext {
    let credentials: [String: Any]?
    let isLive: Bool
    let canRefresh: Bool

    init(profileID: String, liveOwnerID: String?, credentials: [String: Any]?, liveCredentials: [String: Any]?) {
        self.credentials = credentials
        isLive = profileID == liveOwnerID
        // Claude Code owns its rotating token, including copies in another profile's backup.
        canRefresh = !isLive && liveOwnerID != nil
            && credentials?["refreshToken"] as? String != liveCredentials?["refreshToken"] as? String
    }
}

struct ClaudeCredentialSnapshot {
    let liveOwnerID: String?
    let liveCredentials: [String: Any]?
    let savedCredentials: [String: [String: Any]]

    static func verified(
        metadataProfileID: String?,
        liveCredentials: [String: Any]?,
        savedCredentials: [String: [String: Any]],
        tokenOwner: (String) -> String?
    ) -> ClaudeCredentialSnapshot {
        let unverified = ClaudeCredentialSnapshot(liveOwnerID: nil, liveCredentials: liveCredentials, savedCredentials: savedCredentials)
        guard let token = liveCredentials?["accessToken"] as? String, !token.isEmpty else { return unverified }
        let ownerID: String?
        if let metadataProfileID, unverified.matchesSavedLogin(metadataProfileID) {
            ownerID = metadataProfileID
        } else {
            // Claude Code can rotate the Keychain login without updating .claude.json.
            ownerID = tokenOwner(token)
        }
        return ClaudeCredentialSnapshot(liveOwnerID: ownerID, liveCredentials: liveCredentials, savedCredentials: savedCredentials)
    }

    func context(for profileID: String) -> ClaudeCredentialContext {
        ClaudeCredentialContext(profileID: profileID, liveOwnerID: liveOwnerID,
            credentials: profileID == liveOwnerID ? liveCredentials : savedCredentials[profileID],
            liveCredentials: liveCredentials)
    }

    func matchesSavedLogin(_ profileID: String) -> Bool {
        guard let liveCredentials, let saved = savedCredentials[profileID] else { return false }
        return saved["accessToken"] as? String == liveCredentials["accessToken"] as? String
            && saved["refreshToken"] as? String == liveCredentials["refreshToken"] as? String
    }
}

/// When a Claude login is reported as signed out. Claude Code owns the live
/// token and renews it on its next request, so an expired or rejected token this
/// app may not refresh is waited on rather than shown as "Sign in".
enum ClaudeLoginPolicy {
    enum Rejection: Equatable {
        /// The token is not this app's to refresh.
        case notAllowed
        case failed(invalidGrant: Bool)
        case refreshedButStillRejected
    }

    static let waitingMessage = "Login expired; Claude Code renews it on its next request"

    static func waitsForOwner(tokenExpired: Bool, canRefresh: Bool) -> Bool {
        tokenExpired && !canRefresh
    }

    static func needsLogin(afterRejection rejection: Rejection) -> Bool {
        switch rejection {
        case .notAllowed: return false
        case .failed(let invalidGrant): return invalidGrant
        case .refreshedButStillRejected: return true
        }
    }
}
