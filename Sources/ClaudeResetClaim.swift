import Foundation

extension ClaudeAPI {
    /// Spends one Claude reset for a saved profile. The active profile's token belongs to
    /// Claude Code and is never refreshed here; an inactive profile's token is refreshed
    /// first when it has expired.
    static func claimReset(profileID: String, grant: ClaudeResetGrant, requestID: String) async -> Result<ClaudeResetClaimResult, ClaudeError> {
        let snapshot = ClaudeAccountStore.synchronize()
        guard let profile = snapshot.profiles.first(where: { $0.id == profileID }) else {
            return .failure(.message("Claude profile not found."))
        }
        guard let url = ClaudeResetAPI.claimURL(organizationID: profile.organizationID) else {
            return .failure(.message("This Claude login has no organization id. Sign in to it again."))
        }
        guard let body = ClaudeResetAPI.claimBody(program: grant.program, grantID: grant.id, requestID: requestID),
              let bodyData = try? JSONSerialization.data(withJSONObject: body) else {
            return .failure(.message("This reset has an unexpected id, so it was not used."))
        }

        let context = snapshot.credentials.context(for: profile.id)
        var credentials = context.credentials
        if let current = credentials, isExpired(current) {
            guard context.canRefresh else {
                return .failure(.message("The login for \(profile.title) has expired. Use Claude Code once to renew it, then try again."))
            }
            switch await refreshed(current, profile: profile) {
            case .success(let updated): credentials = updated
            case .failure(let failure): return .failure(.message("\(failure.message). Sign in to \(profile.title) again."))
            }
        }
        guard let token = credentials?["accessToken"] as? String, !token.isEmpty else {
            return .failure(.message("The saved login for \(profile.title) is missing. Sign in to it again."))
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 25
        request.httpBody = bodyData
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        applyClaudeCodeHeaders(to: &request)

        let payload: HTTPPayload
        do {
            // Never retried: a second POST could spend a second reset.
            payload = try await HTTPClient.send(request, retries: 0)
        } catch {
            return .failure(.message("The reset request did not complete (\(error.localizedDescription)). Refresh to check whether it was used."))
        }
        switch payload.statusCode {
        case 200..<300: break
        case 401: return .failure(.message("The login for \(profile.title) expired. Refresh the panel and try again."))
        case 403: return .failure(.message("Anthropic refused the reset for this login."))
        case 429: return .failure(.message("Too many requests. Try again in a minute."))
        default: return .failure(.message("The reset request returned \(payload.statusCode). Refresh to check whether it was used."))
        }
        guard let object = (try? JSONSerialization.jsonObject(with: payload.data)) as? [String: Any] else {
            return .failure(.message("The reset response was unreadable. Refresh to check whether it was used."))
        }
        return .success(ClaudeResetAPI.parseClaim(object))
    }
}

extension ClaudeController {
    func claimReset(profileID: String, grantID: String, completion: @escaping (Result<ClaudeResetClaimResult, ClaudeError>) -> Void) {
        guard isEnabled else { return completion(.failure(.message("Claude resets are disabled in demo mode."))) }
        guard !isClaimingReset, !isSwitching else {
            return completion(.failure(.message("Wait for the current Claude action to finish.")))
        }
        guard let account = accounts.first(where: { $0.id == profileID }),
              let grant = account.resets?.grants.first(where: { $0.id == grantID }) else {
            return completion(.failure(.message("This reset is no longer listed. Refresh and try again.")))
        }
        guard !isRefreshing else {
            return completion(.failure(.message("Claude accounts are refreshing. Try again in a moment.")))
        }
        let requestKey = "\(profileID)|\(grant.id)|\(grant.resetsLeft)"
        let requestID = resetRequestIDs[requestKey] ?? UUID().uuidString
        resetRequestIDs[requestKey] = requestID
        isClaimingReset = true
        onChange?()
        Task.detached(priority: .userInitiated) {
            let result = await self.submitResetClaim(profileID, grant, requestID)
            await MainActor.run {
                self.isClaimingReset = false
                switch result {
                case .success(.reset(confirmed: true, _)), .success(.refused): self.resetRequestIDs[requestKey] = nil
                default: break
                }
                completion(result)
                self.refresh()
            }
        }
    }
}
