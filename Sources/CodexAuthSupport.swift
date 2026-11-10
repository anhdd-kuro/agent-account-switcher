import Foundation

/// One account row of `codex-auth list --json`. Usage is not read from it: the
/// app fetches usage itself, so codex-auth runs local-only.
struct CodexAuthListEntry: Equatable {
    let selector: String
    let email: String
    let plan: String
    let isActive: Bool
}

enum CodexAuthListJSON {
    /// The accounts of a `list` document, or nil when the output is anything else
    /// (codex-auth's JSON error object, or the table of a version without `--json`).
    static func parse(_ output: String) -> [CodexAuthListEntry]? {
        guard let data = output.data(using: .utf8),
              let document = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              document["command"] as? String == "list",
              let accounts = document["accounts"] as? [[String: Any]] else {
            return nil
        }
        return accounts.compactMap { account in
            guard let email = account["email"] as? String, !email.isEmpty else { return nil }
            let number = (account["number"] as? NSNumber)?.intValue ?? 0
            let plan = account["plan"] as? String ?? ""
            return CodexAuthListEntry(
                selector: String(format: "%02d", number),
                email: email,
                plan: plan.isEmpty ? "Unknown" : plan.prefix(1).uppercased() + plan.dropFirst(),
                isActive: account["active"] as? Bool ?? false
            )
        }
    }
}

/// Unverified claims of a ChatGPT access token. Used only to avoid sending a
/// token that has already expired and to tell whose login a file holds.
enum AccessTokenClaims {
    private static let authClaim = "https://api.openai.com/auth"

    static func claims(of token: String) -> [String: Any]? {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        var payload = parts[1].replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
        guard let data = Data(base64Encoded: payload) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    static func expiry(of token: String) -> Date? {
        guard let seconds = (claims(of: token)?["exp"] as? NSNumber)?.doubleValue, seconds.isFinite else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }

    /// False when the expiry cannot be read: the server decides then.
    static func isExpired(_ token: String, now: Date = Date()) -> Bool {
        guard let expiry = expiry(of: token) else { return false }
        return expiry <= now
    }

    static func userID(of token: String) -> String? {
        (claims(of: token)?[authClaim] as? [String: Any])?["chatgpt_user_id"] as? String
    }
}

/// Decides whether `~/.codex/auth.json` may be saved as an account's snapshot.
/// Another Codex client can sign in to a different account at any time, so the
/// live file is only saved over the account it actually belongs to.
enum AuthSnapshotSync {
    enum Decision: Equatable {
        case copy
        case unchanged
        case mismatch
    }

    static func decision(
        live: [String: Any]?,
        snapshot: [String: Any]?,
        expectedAccountID: String?,
        expectedUserID: String?
    ) -> Decision {
        // A login missing either token is unusable and must never replace a saved one.
        guard let liveTokens = live?["tokens"] as? [String: Any],
              let accountID = liveTokens["account_id"] as? String, !accountID.isEmpty,
              let expectedAccountID, accountID == expectedAccountID,
              let accessToken = liveTokens["access_token"] as? String, !accessToken.isEmpty,
              let refreshToken = liveTokens["refresh_token"] as? String, !refreshToken.isEmpty else {
            return .mismatch
        }
        // Workspace members share an account id, so a known user id must be confirmed too.
        if let expectedUserID, !expectedUserID.isEmpty, AccessTokenClaims.userID(of: accessToken) != expectedUserID {
            return .mismatch
        }
        if let saved = snapshot?["tokens"] as? [String: Any],
           saved["refresh_token"] as? String == refreshToken,
           saved["access_token"] as? String == accessToken {
            return .unchanged
        }
        return .copy
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

    /// True when the usage request should be skipped until the owner renews the token.
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
