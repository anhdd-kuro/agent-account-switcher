import Foundation

@main
enum ProviderTests {
    private static var failures: [String] = []
    private static var assertions = 0

    static func main() async {
        run { condition, message in
            assertions += 1
            if !condition { failures.append(message) }
        }
        await testResetClaimDuringExternalSwitch()
        guard failures.isEmpty else {
            for failure in failures { FileHandle.standardError.write(Data("FAIL: \(failure)\n".utf8)) }
            exit(1)
        }
        print("Provider tests passed (\(assertions) assertions).")
    }

    static func run(expect: (Bool, String) -> Void) {
        testProfiles(expect)
        testTokenOwnership(expect)
        testVerifiedCredentialSnapshot(expect)
        testSummaryUpdates(expect)
        testCursorAuthentication(expect)
        testCursorUsage(expect)
        testTimestamps(expect)
    }

    private static func testProfiles(_ expect: (Bool, String) -> Void) {
        let profile = ClaudeProfile(
            id: "one@example.com:org", email: "one@example.com", organizationID: "org",
            organizationName: "Team", keychainAccount: "local-user",
            keychainService: "claude-switcher:one@example.com:org", oauthAccount: ["billingType": "team"]
        )
        var saved = profile.dictionary()
        saved["id"] = "stale-id"
        let restored = ClaudeProfile(dictionary: saved)
        expect(restored?.id == profile.id && restored?.organizationName == "Team", "profile identity follows its account and organization after loading")
        expect(restored?.oauthAccount["billingType"] as? String == "team", "profile loading preserves account details needed for switching")
        saved["keychainService"] = "Claude Code-credentials"
        expect(ClaudeProfile(dictionary: saved) == nil, "a saved profile cannot name the live Keychain item")
        expect(ClaudeAccountSummary.planLabel(plan: "Claude Team 5x") == "Team · Premium", "premium organization seats retain their label")
        expect(ClaudeAccountSummary.planLabel(plan: "Claude Enterprise") == "Enterprise · Standard", "standard organization seats retain their label")
        expect(!ClaudeAccountSummary.hasFiveHourLimit(plan: "Claude Max 20x", fiveHourRemaining: 100), "verified Max 20x accounts show only the weekly window")
        expect(ClaudeAccountSummary.hasFiveHourLimit(plan: "Claude Ultra", fiveHourRemaining: 80), "an Ultra account with reported five-hour use keeps that window")
        expect(ClaudeAccountSummary.hasFiveHourLimit(plan: "Claude Team 20x", fiveHourRemaining: 100), "organization premium seats still show their five-hour window")
    }

    private static func testTokenOwnership(_ expect: (Bool, String) -> Void) {
        let live: [String: Any] = ["accessToken": "live-access", "refreshToken": "live-refresh"]
        let saved: [String: Any] = ["accessToken": "saved-access", "refreshToken": "saved-refresh"]
        let active = ClaudeCredentialContext(profileID: "live", liveOwnerID: "live", credentials: live, liveCredentials: live)
        expect(active.isLive && !active.canRefresh, "Claude Code owns the live token and the app cannot rotate it")
        let inactive = ClaudeCredentialContext(profileID: "saved", liveOwnerID: "live", credentials: saved, liveCredentials: live)
        expect(!inactive.isLive && inactive.canRefresh, "an independent inactive login may rotate its own token")
        let duplicate = ClaudeCredentialContext(profileID: "saved", liveOwnerID: "live", credentials: live, liveCredentials: live)
        expect(!duplicate.canRefresh, "a copied live refresh token remains owned by Claude Code")
        let unknown = ClaudeCredentialContext(profileID: "saved", liveOwnerID: nil, credentials: saved, liveCredentials: live)
        expect(!unknown.canRefresh, "an unconfirmed live owner blocks token rotation")
        expect(inactive.credentials?["accessToken"] as? String == "saved-access", "the ownership context preserves the selected login")
    }

    private static func testVerifiedCredentialSnapshot(_ expect: (Bool, String) -> Void) {
        let savedA: [String: Any] = ["accessToken": "a-saved", "refreshToken": "a-refresh"]
        let savedB: [String: Any] = ["accessToken": "b-old", "refreshToken": "b-old-refresh"]
        let liveB: [String: Any] = ["accessToken": "b-live", "refreshToken": "b-live-refresh"]
        var verifiedTokens: [String] = []
        let snapshot = ClaudeCredentialSnapshot.verified(metadataProfileID: "a", liveCredentials: liveB,
            savedCredentials: ["a": savedA, "b": savedB]) { token in
                verifiedTokens.append(token)
                return "b"
            }
        expect(verifiedTokens == ["b-live"] && snapshot.liveOwnerID == "b", "stale Claude metadata is checked against the captured token's owner")
        let claimA = snapshot.context(for: "a")
        let claimB = snapshot.context(for: "b")
        expect(claimA.credentials?["accessToken"] as? String == "a-saved" && claimA.canRefresh,
               "claiming the stale metadata account selects its own saved login")
        expect(claimB.credentials?["accessToken"] as? String == "b-live" && !claimB.canRefresh,
               "the verified live owner uses the captured token without rotating it")
        let unknown = ClaudeCredentialSnapshot.verified(metadataProfileID: "a", liveCredentials: liveB,
            savedCredentials: ["a": savedA]) { _ in nil }
        expect(unknown.context(for: "a").credentials?["accessToken"] as? String == "a-saved" && !unknown.context(for: "a").canRefresh,
               "unverified live ownership never selects the live token or permits rotation")
    }

    private actor RefreshSequence {
        let cached: [ClaudeAccountSummary]
        let afterSwitch: [ClaudeAccountSummary]
        private var loads = 0
        private var pendingLoad: CheckedContinuation<[ClaudeAccountSummary], Never>?
        private var loadStarted: CheckedContinuation<Void, Never>?
        private(set) var claims = 0

        init(cached: [ClaudeAccountSummary], afterSwitch: [ClaudeAccountSummary]) {
            self.cached = cached
            self.afterSwitch = afterSwitch
        }

        func load() async -> [ClaudeAccountSummary] {
            loads += 1
            guard loads == 2 else { return loads == 1 ? cached : afterSwitch }
            return await withCheckedContinuation { continuation in
                pendingLoad = continuation
                loadStarted?.resume()
                loadStarted = nil
            }
        }

        func waitUntilSuspended() async {
            guard pendingLoad == nil else { return }
            await withCheckedContinuation { loadStarted = $0 }
        }

        func finish() {
            pendingLoad?.resume(returning: afterSwitch)
            pendingLoad = nil
        }

        func submitClaim() -> Result<ClaudeResetClaimResult, ClaudeError> {
            claims += 1
            return .success(.refused("Synthetic claim should not run during refresh"))
        }
    }

    @MainActor
    private static func testResetClaimDuringExternalSwitch() async {
        let grant = ClaudeResetGrant(program: ClaudeResetGrant.grantProgram, id: "fixture", label: "",
            kind: "full", resetsLeft: 1, endsAt: nil, clears: [], usableNow: true, unavailableReason: nil)
        let resets = ClaudeResetStatus(eligible: true, ineligibleReason: nil, grants: [grant])
        let activeA = summary(id: "a", active: true, weekly: 10, resets: resets)
        let activeB = summary(id: "b", active: true, weekly: 80)
        let sequence = RefreshSequence(cached: [activeA], afterSwitch: [activeA.settingActive(false), activeB])
        let controller = ClaudeController(loadAccounts: { await sequence.load() },
            submitResetClaim: { _, _, _ in await sequence.submitClaim() })
        await withCheckedContinuation { continuation in
            controller.onChange = {
                controller.onChange = nil
                continuation.resume()
            }
            controller.refresh()
        }
        controller.refresh()
        await sequence.waitUntilSuspended()
        let result = await withCheckedContinuation { continuation in
            controller.claimReset(profileID: "a", grantID: "fixture") { continuation.resume(returning: $0) }
        }
        assertions += 1
        if case .failure = result {} else { failures.append("a reset is refused while an external-switch refresh is rotating the cached active account") }
        let claims = await sequence.claims
        assertions += 1
        if claims != 0 { failures.append("a refused reset must not reach credential selection or POST during refresh") }
        await withCheckedContinuation { continuation in
            controller.onChange = {
                controller.onChange = nil
                continuation.resume()
            }
            Task { await sequence.finish() }
        }
        assertions += 1
        if controller.active?.id != "b" { failures.append("the blocked reset must not interfere with the external-switch refresh") }
    }

    private static func summary(id: String = "one", active: Bool = false, needsLogin: Bool = false,
                                error: String? = nil, five: Int? = nil, weekly: Int? = nil,
                                resets: ClaudeResetStatus? = nil) -> ClaudeAccountSummary {
        ClaudeAccountSummary(
            id: id, title: "Personal", email: "one@example.com", plan: "Claude Ultra",
            fiveHourRemaining: five, weeklyRemaining: weekly,
            fiveHourResetAt: nil, weeklyResetAt: Date(timeIntervalSince1970: 5_000),
            isActive: active, needsLogin: needsLogin, usageError: error, resets: resets
        )
    }

    private static func testSummaryUpdates(_ expect: (Bool, String) -> Void) {
        let resets = ClaudeResetStatus(eligible: true, ineligibleReason: nil, grants: [])
        let previous = summary(weekly: 12, resets: resets)
        let failed = summary(active: true, error: "waiting")
        let retained = failed.retainingUsage(from: previous)
        expect(retained.weeklyRemaining == 12 && retained.fiveHourRemaining == nil && retained.resets == resets,
               "a transient failure keeps a weekly-only account's last usage and resets")
        expect(retained.isActive && retained.usageError == "waiting", "retained usage keeps the latest identity and error state")
        expect(summary(needsLogin: true, error: "signed out").retainingUsage(from: previous).weeklyRemaining == nil,
               "a signed-out account does not display retained usage as usable")
        expect(failed.retainingUsage(from: summary(id: "other", weekly: 99)).weeklyRemaining == nil,
               "retained usage never comes from another account")
        expect(summary(weekly: 80).retainingUsage(from: previous).weeklyRemaining == 80,
               "a successful fetch replaces the previous reading")
        let activated = previous.settingActive(true)
        expect(activated.isActive && activated.weeklyRemaining == previous.weeklyRemaining && activated.resets == resets,
               "switching active identity preserves usage and reset availability")
        expect(activated.settingActive(false) == previous, "switching identity back preserves the full account summary")
    }

    private static func jwt(_ claims: [String: Any]) -> String {
        let data = try! JSONSerialization.data(withJSONObject: claims)
        let payload = data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        return "header.\(payload).signature"
    }

    private static func testCursorAuthentication(_ expect: (Bool, String) -> Void) {
        let now = Date(timeIntervalSince1970: 1_000)
        expect(CursorUsageClient.isUsableJWT(jwt(["sub": "auth0|user_test", "exp": 1_061]), now: now),
               "Cursor accepts a JWT beyond its expiry margin")
        expect(!CursorUsageClient.isUsableJWT(jwt(["exp": 1_060]), now: now), "Cursor excludes a JWT at its expiry margin")
        expect(!CursorUsageClient.isUsableJWT("cursor-opaque-token", now: now), "Cursor rejects opaque IDE tokens for the website endpoint")
        expect(CursorUsageClient.normalizedSubject("auth0|user_test") == "user_test", "native Cursor subjects use their user id")
        expect(CursorUsageClient.normalizedSubject("google-oauth2|test") == "google-oauth2|test", "Cursor OAuth subjects keep their provider prefix")
        expect(CursorUsageClient.normalizedSubject("unknown-subject") == nil, "Cursor refuses an unrecognized cookie subject")
    }

    private static func testCursorUsage(_ expect: (Bool, String) -> Void) {
        let team = CursorUsageClient.parse([
            "membershipType": "team", "limitType": "team",
            "individualUsage": ["plan": ["totalPercentUsed": 0]],
            "teamUsage": ["onDemand": ["used": 25, "limit": 100]]
        ])
        expect(team.planUsed == 25, "Cursor organization usage falls back to its shared allowance")
        expect(CursorUsageClient.clampPercent(1e100) == 100 && CursorUsageClient.clampPercent(-20) == 0,
               "Cursor percentages remain bounded before integer conversion")
        expect(CursorUsageClient.clampPercent(Double.nan) == nil, "unreadable Cursor usage stays unknown")
    }

    private static func testTimestamps(_ expect: (Bool, String) -> Void) {
        let plain = ISO8601Timestamp.parse("2026-10-23T05:46:06Z")
        let fractional = ISO8601Timestamp.parse("2026-10-23T05:46:06.500Z")
        expect(plain != nil && fractional?.timeIntervalSince(plain!) == 0.5, "provider timestamps accept both whole and fractional seconds")
        expect(ISO8601Timestamp.parse("not a date") == nil, "invalid provider timestamps stay unknown")
    }
}
