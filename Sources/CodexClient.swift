import Foundation

final class CodexClient {
    private let authStore: CodexAuthStore

    init(authStore: CodexAuthStore) { self.authStore = authStore }

    func fetchDirectUsage(for accounts: [CodexAccount]) async -> [String: DirectUsageSnapshot] {
        let refreshed = await withTaskGroup(of: (String, DirectUsageSnapshot)?.self) { group in
            for account in accounts {
                group.addTask {
                    // An expired token is renewed by Codex when the account is next used; sending it only earns a 401.
                    guard case .success(let auth) = self.authStore.savedAuth(forEmail: account.email),
                          !AccessTokenClaims.isExpired(auth.accessToken) else { return nil }
                    guard case .success(let usage) = await self.fetchDirectUsage(using: auth) else { return nil }
                    return (account.email, usage)
                }
            }
            var resolved: [(String, DirectUsageSnapshot)] = []
            for await result in group {
                if let result { resolved.append(result) }
            }
            return resolved
        }
        return Dictionary(uniqueKeysWithValues: refreshed)
    }

    func fetchDirectUsage(using auth: SavedAccountAuth) async -> DirectUsageFetchResult {
        guard let url = URL(string: "https://chatgpt.com/backend-api/wham/usage") else {
            return .failure("usage endpoint URL is invalid")
        }

        let request = authenticatedRequest(url: url, auth: auth, method: "GET", timeout: 12)

        let payload: HTTPPayload
        do {
            payload = try await HTTPClient.send(request, retries: 1)
        } catch {
            return .failure(error.localizedDescription)
        }
        guard payload.statusCode == 200 else {
            return .failure("usage endpoint returned \(payload.statusCode)")
        }
        return parseDirectUsageResponse(payload.data)
    }

    func parseDirectUsageResponse(_ responseData: Data) -> DirectUsageFetchResult {
        guard
            let object = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any],
            let rateLimit = object["rate_limit"] as? [String: Any]
        else {
            return .failure("usage endpoint returned incomplete rate-limit data")
        }

        typealias ParsedWindow = (snapshot: UsageLimitWindowSnapshot, duration: Int?)
        func parsedWindow(_ raw: Any?) -> ParsedWindow? {
            guard
                let window = raw as? [String: Any],
                let usedPercent = integerValue(window["used_percent"])
            else {
                return nil
            }
            let resetAt = integerValue(window["reset_at"]).map {
                Date(timeIntervalSince1970: TimeInterval($0))
            }
            return (
                UsageLimitWindowSnapshot(
                    remainingPercent: 100 - max(0, min(100, usedPercent)),
                    resetAt: resetAt
                ),
                integerValue(window["limit_window_seconds"])
            )
        }

        let primary = parsedWindow(rateLimit["primary_window"])
        let secondary = parsedWindow(rateLimit["secondary_window"])
        guard primary != nil || secondary != nil else {
            return .failure("usage endpoint returned incomplete rate-limit data")
        }

        let fullUnusedWindow = UsageLimitWindowSnapshot(remainingPercent: 100, resetAt: nil)
        let fiveHour: UsageLimitWindowSnapshot
        let weekly: UsageLimitWindowSnapshot

        if let primary, let secondary {
            if let primaryDuration = primary.duration, let secondaryDuration = secondary.duration {
                if primaryDuration <= secondaryDuration {
                    fiveHour = primary.snapshot
                    weekly = secondary.snapshot
                } else {
                    fiveHour = secondary.snapshot
                    weekly = primary.snapshot
                }
            } else {
                // Preserve the established backend ordering when duration metadata
                // is unavailable: primary is the short window, secondary is weekly.
                fiveHour = primary.snapshot
                weekly = secondary.snapshot
            }
        } else if let only = primary ?? secondary {
            // Directly after a reset ChatGPT may omit a window until that window is
            // first used. An absent window is therefore full, not an error or stale 0%.
            if let duration = only.duration, duration >= 86_400 {
                fiveHour = fullUnusedWindow
                weekly = only.snapshot
            } else {
                fiveHour = only.snapshot
                weekly = fullUnusedWindow
            }
        } else {
            return .failure("usage endpoint returned incomplete rate-limit data")
        }

        return .success(DirectUsageSnapshot(
            fiveHour: fiveHour,
            weekly: weekly,
            planType: object["plan_type"] as? String
        ))
    }

    func integerValue(_ value: Any?) -> Int? {
        if let value = value as? Int { return value }
        if let value = value as? NSNumber { return value.intValue }
        if let value = value as? String { return Int(value) }
        return nil
    }

    func fetchResetCredits(for accounts: [CodexAccount]) async -> [String: ResetCreditsSnapshot] {
        var results: [String: ResetCreditsSnapshot] = [:]
        let batchSize = 3
        var startIndex = 0

        while startIndex < accounts.count {
            let endIndex = min(startIndex + batchSize, accounts.count)
            let batch = Array(accounts[startIndex..<endIndex])
            let batchResults = await withTaskGroup(of: (String, ResetCreditsSnapshot).self) { group in
                for account in batch {
                    group.addTask {
                        let snapshot: ResetCreditsSnapshot
                        switch self.authStore.savedAuth(forEmail: account.email) {
                        case .success(let auth) where AccessTokenClaims.isExpired(auth.accessToken):
                            snapshot = ResetCreditsSnapshot(availableCount: nil, credits: [], lastUpdatedText: "never", lastError: "session token expired; Codex renews it when this account is next used")
                        case .success(let auth):
                            switch await self.fetchResetCredits(using: auth) {
                            case .success(let fetched):
                                snapshot = fetched
                            case .failure(let message):
                                snapshot = ResetCreditsSnapshot(availableCount: nil, credits: [], lastUpdatedText: "just now", lastError: message)
                            }
                        case .failure(let message):
                            snapshot = ResetCreditsSnapshot(availableCount: nil, credits: [], lastUpdatedText: "never", lastError: message)
                        }
                        return (account.email, snapshot)
                    }
                }
                var resolved: [(String, ResetCreditsSnapshot)] = []
                for await result in group { resolved.append(result) }
                return resolved
            }
            for (email, snapshot) in batchResults { results[email] = snapshot }
            startIndex = endIndex
        }
        return results
    }

    func consumeResetCredit(using auth: SavedAccountAuth, creditID: String) async -> ResetCreditRedemptionResult {
        guard !creditID.isEmpty else {
            return .failure("The selected reset credit is missing its backend id.")
        }
        guard let url = URL(string: "https://chatgpt.com/backend-api/wham/rate-limit-reset-credits/consume") else {
            return .failure("Reset consume endpoint URL is invalid.")
        }

        var request = authenticatedRequest(url: url, auth: auth, method: "POST", timeout: 20)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "credit_id": creditID,
            "redeem_request_id": UUID().uuidString
        ]
        guard let bodyData = try? JSONSerialization.data(withJSONObject: body) else {
            return .failure("Could not prepare the reset request.")
        }
        request.httpBody = bodyData

        let payload: HTTPPayload
        do {
            // A reset POST is deliberately never retried: an ambiguous response must not spend two credits.
            payload = try await HTTPClient.send(request, retries: 0)
        } catch {
            return .failure(error.localizedDescription)
        }
        guard payload.statusCode == 200 else {
            return .failure("Reset endpoint returned \(payload.statusCode). No credit was treated as redeemed.")
        }
        return parseResetConsumeResponse(payload.data)
    }

    func parseResetConsumeResponse(_ responseData: Data) -> ResetCreditRedemptionResult {
        guard let object = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any] else {
            return .failure("Reset endpoint returned HTTP 200 but did not provide readable confirmation.")
        }
        let code = (object["code"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let windows: Int
        if let value = integerValue(object["windows_reset"]) {
            windows = value
        } else if let values = object["windows_reset"] as? [Any] {
            windows = values.count
        } else {
            windows = 0
        }
        let successFlag = object["success"] as? Bool ?? false
        let acceptedCodes = ["ok", "reset", "success", "rate_limits_reset", "reset_applied"]
        let codeAccepted = acceptedCodes.contains(code.lowercased())
        guard successFlag || windows > 0 || codeAccepted else {
            return .failure("Reset endpoint returned HTTP 200 without confirming that any rate-limit window was reset.")
        }

        let displayCode = code.isEmpty ? "confirmed" : code
        return .success(ResetConsumeReceipt(
            code: displayCode,
            windowsReset: max(1, windows),
            message: "ChatGPT accepted the reset request (\(displayCode); \(max(1, windows)) window\(max(1, windows) == 1 ? "" : "s"))."
        ))
    }

    func fetchResetCredits(using auth: SavedAccountAuth) async -> ResetCreditsFetchResult {
        guard let url = URL(string: "https://chatgpt.com/backend-api/wham/rate-limit-reset-credits") else {
            return .failure("reset endpoint URL is invalid")
        }

        let request = authenticatedRequest(url: url, auth: auth, method: "GET", timeout: 12)

        let payload: HTTPPayload
        do {
            payload = try await HTTPClient.send(request, retries: 1)
        } catch {
            return .failure(error.localizedDescription)
        }
        guard payload.statusCode == 200 else {
            return .failure("reset endpoint returned \(payload.statusCode)")
        }
        guard let object = try? JSONSerialization.jsonObject(with: payload.data) as? [String: Any] else {
            return .failure("reset endpoint returned unreadable JSON")
        }

        let credits = (object["credits"] as? [[String: Any]] ?? []).map { raw in
            ResetCredit(
                id: raw["id"] as? String ?? "",
                title: raw["title"] as? String ?? "Reset credit",
                resetType: raw["reset_type"] as? String ?? "codex_rate_limits",
                status: raw["status"] as? String ?? "unknown",
                grantedAt: (raw["granted_at"] as? String).flatMap { DateFormatter.resetCreditISO.date(from: $0) },
                expiresAt: (raw["expires_at"] as? String).flatMap { DateFormatter.resetCreditISO.date(from: $0) }
            )
        }

        return .success(ResetCreditsSnapshot(
            availableCount: object["available_count"] as? Int,
            credits: credits,
            lastUpdatedText: "just now",
            lastError: nil
        ))
    }
    private func authenticatedRequest(url: URL, auth: SavedAccountAuth, method: String, timeout: TimeInterval) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = timeout
        request.setValue("Bearer \(auth.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(auth.accountID, forHTTPHeaderField: "ChatGPT-Account-ID")
        request.setValue("codex-1", forHTTPHeaderField: "OpenAI-Beta")
        request.setValue("Codex Desktop", forHTTPHeaderField: "originator")
        return request
    }

}
