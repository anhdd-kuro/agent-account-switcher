import Foundation

enum ClaudeAPI {
    private static let clientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
    private static let tokenURL = URL(string: "https://platform.claude.com/v1/oauth/token")!
    private static let usageURL = URL(string: "https://api.anthropic.com/api/oauth/usage?\(ClaudeResetAPI.usageQuery)")!
    // Anthropic uses the CLI version and app headers to decide reset eligibility.
    private static let cliVersion = ClaudeResetAPI.cliVersion(fromPath: ClaudeCLI.executable().map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path } ?? "")

    static func summaries(_ profiles: [ClaudeProfile], credentials: ClaudeCredentialSnapshot) async -> [ClaudeAccountSummary] {
        // Claude Code owns the live token: never refresh it, and refresh nothing while
        // the live owner is unconfirmed.
        return await withTaskGroup(of: (Int, ClaudeAccountSummary).self) { group in
            for (index, profile) in profiles.enumerated() {
                group.addTask { (index, await summary(for: profile, context: credentials.context(for: profile.id))) }
            }
            var results: [(Int, ClaudeAccountSummary)] = []
            for await result in group { results.append(result) }
            return results.sorted { $0.0 < $1.0 }.map(\.1)
        }
    }

    private static func summary(for profile: ClaudeProfile, context: ClaudeCredentialContext) async -> ClaudeAccountSummary {
        var credentials = context.credentials
        let canRefresh = context.canRefresh
        var needsLogin = credentials == nil
        var usage: [String: Any]?
        var error: String? = credentials == nil ? "No saved login" : nil

        var waitsForOwner = false
        if let current = credentials {
            if canRefresh, isExpired(current) {
                switch await refreshed(current, profile: profile) {
                case .success(let updated): credentials = updated
                case .failure(let failure):
                    needsLogin = failure.isInvalidGrant
                    error = failure.message
                }
            } else if ClaudeLoginPolicy.waitsForOwner(tokenExpired: isExpired(current, margin: 0), canRefresh: canRefresh) {
                // Sending the expired token would only earn a 401 and drop the last reading.
                waitsForOwner = true
                error = ClaudeLoginPolicy.waitingMessage
            }
        }
        if let token = credentials?["accessToken"] as? String, !needsLogin, !waitsForOwner {
            var result = await fetchUsage(token: token, key: profile.id)
            if case .failure(let failure) = result, failure.status == 401 {
                var rejection = ClaudeLoginPolicy.Rejection.notAllowed
                if canRefresh, let current = credentials {
                    switch await refreshed(current, profile: profile) {
                    case .success(let updated):
                        if let newToken = updated["accessToken"] as? String { result = await fetchUsage(token: newToken, key: profile.id) }
                        if case .failure(let retried) = result, retried.status == 401 { rejection = .refreshedButStillRejected }
                    case .failure(let refreshFailure):
                        rejection = .failed(invalidGrant: refreshFailure.isInvalidGrant)
                    }
                }
                needsLogin = ClaudeLoginPolicy.needsLogin(afterRejection: rejection)
            }
            switch result {
            case .success(let object):
                usage = object
                error = nil
            case .failure(let failure):
                error = failure.status == 401 && !canRefresh ? ClaudeLoginPolicy.waitingMessage : failure.message
            }
        }

        func window(_ key: String) -> (Int?, Date?) {
            guard let window = usage?[key] as? [String: Any],
                  let utilization = (window["utilization"] as? NSNumber)?.doubleValue,
                  utilization.isFinite else {
                return (nil, nil)
            }
            let remaining = max(0, min(100, Int((100 - utilization).rounded())))
            return (remaining, (window["resets_at"] as? String).flatMap(ISO8601Timestamp.parse))
        }
        let five = window("five_hour")
        let weekly = window("seven_day")
        return ClaudeAccountSummary(
            id: profile.id,
            title: profile.title,
            email: profile.email,
            plan: planText(credentials ?? [:], profile: profile),
            fiveHourRemaining: five.0,
            weeklyRemaining: weekly.0,
            fiveHourResetAt: five.1,
            weeklyResetAt: weekly.1,
            isActive: context.isLive,
            needsLogin: needsLogin,
            usageError: error,
            resets: usage.flatMap(ClaudeResetStatus.parse(usage:))
        )
    }

    private static func planText(_ credentials: [String: Any], profile: ClaudeProfile) -> String {
        let subscription = (credentials["subscriptionType"] as? String) ?? (profile.oauthAccount["billingType"] as? String) ?? ""
        var plan = subscription.isEmpty ? "Claude" : "Claude \(subscription.prefix(1).uppercased())\(subscription.dropFirst())"
        let tier = credentials["rateLimitTier"] as? String ?? ""
        if let range = tier.range(of: #"\d+x$"#, options: .regularExpression) {
            plan += " \(tier[range])"
        }
        return plan
    }

    static func isExpired(_ credentials: [String: Any], margin: TimeInterval = 120) -> Bool {
        guard let expiresAt = (credentials["expiresAt"] as? NSNumber)?.doubleValue else { return false }
        return Date(timeIntervalSince1970: expiresAt / 1000) < Date().addingTimeInterval(margin)
    }

    struct Failure: Error {
        let status: Int?
        let message: String
        var retryAfter: TimeInterval? = nil
        var isInvalidGrant: Bool { status == 400 || status == 401 }
    }

    private static let backoffLock = NSLock()
    nonisolated(unsafe) private static var usageBackoff = RateLimitBackoff()

    private static func rateLimitedFailure(until date: Date) -> Failure {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return Failure(status: 429, message: "Usage is rate limited; retrying at \(formatter.string(from: date))")
    }

    private static func fetchUsage(token: String, key: String) async -> Result<[String: Any], Failure> {
        if let retryAt = backoffLock.withLock({ usageBackoff.retryAt(key) }) {
            return .failure(rateLimitedFailure(until: retryAt))
        }
        let result = await requestUsage(token: token)
        switch result {
        case .success:
            backoffLock.withLock { usageBackoff.recordSuccess(key) }
            return result
        case .failure(let failure) where failure.status == 429:
            let retryAt = backoffLock.withLock {
                usageBackoff.recordLimited(key, retryAfter: failure.retryAfter)
            }
            return .failure(rateLimitedFailure(until: retryAt))
        case .failure:
            return result
        }
    }

    private static func requestUsage(token: String) async -> Result<[String: Any], Failure> {
        var request = URLRequest(url: usageURL)
        request.timeoutInterval = 12
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        applyClaudeCodeHeaders(to: &request)
        do {
            let payload = try await HTTPClient.send(request, retries: 1)
            guard payload.statusCode == 200 else {
                return .failure(Failure(
                    status: payload.statusCode,
                    message: "Usage returned \(payload.statusCode)",
                    retryAfter: RateLimitBackoff.parseRetryAfter(payload.retryAfter)
                ))
            }
            guard let object = try JSONSerialization.jsonObject(with: payload.data) as? [String: Any] else {
                return .failure(Failure(status: nil, message: "Usage response was unreadable"))
            }
            return .success(object)
        } catch {
            return .failure(Failure(status: nil, message: error.localizedDescription))
        }
    }

    static func applyClaudeCodeHeaders(to request: inout URLRequest) {
        request.setValue(ClaudeResetAPI.userAgent(version: cliVersion), forHTTPHeaderField: "User-Agent")
        request.setValue("cli", forHTTPHeaderField: "x-app")
    }

    /// Refreshes an inactive profile's token. The refresh token rotates, so the new
    /// credentials are saved before anything else can use the old ones.
    static func refreshed(_ credentials: [String: Any], profile: ClaudeProfile) async -> Result<[String: Any], Failure> {
        guard let refreshToken = credentials["refreshToken"] as? String else {
            return .failure(Failure(status: 400, message: "Session expired"))
        }
        var request = URLRequest(url: tokenURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var body = ["grant_type": "refresh_token", "refresh_token": refreshToken, "client_id": clientID]
        if let scopes = credentials["scopes"] as? [String], !scopes.isEmpty {
            body["scope"] = scopes.joined(separator: " ")
        }
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        let payload: HTTPPayload
        do {
            payload = try await HTTPClient.send(request, retries: 0)
        } catch {
            return .failure(Failure(status: nil, message: error.localizedDescription))
        }
        guard payload.statusCode == 200,
              let object = (try? JSONSerialization.jsonObject(with: payload.data)) as? [String: Any],
              let accessToken = object["access_token"] as? String else {
            let expired = payload.statusCode == 400 || payload.statusCode == 401
            return .failure(Failure(status: payload.statusCode, message: expired ? "Session expired" : "Token refresh returned \(payload.statusCode)"))
        }
        var updated = credentials
        updated["accessToken"] = accessToken
        if let newRefresh = object["refresh_token"] as? String { updated["refreshToken"] = newRefresh }
        if let expiresIn = (object["expires_in"] as? NSNumber)?.doubleValue {
            updated["expiresAt"] = Int64((Date().timeIntervalSince1970 + expiresIn) * 1000)
        }
        if let scope = object["scope"] as? String { updated["scopes"] = scope.split(separator: " ").map(String.init) }

        guard ClaudeAccountStore.saveRefreshed(updated, profile: profile) else {
            return .failure(Failure(status: nil, message: "Refreshed login could not be saved"))
        }
        return .success(updated)
    }

}
