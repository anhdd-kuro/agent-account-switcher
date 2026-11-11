import Foundation

@main
struct CodexTests {
    static var assertions = 0

    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        assertions += 1
        if !condition() { fatalError(message) }
    }

    static func json(_ object: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: object, options: .sortedKeys)
    }

    static func auth(user: String, marker: String) throws -> [String: Any] {
        let body = try json(["https://api.openai.com/auth": ["chatgpt_user_id": user]])
            .base64EncodedString().replacingOccurrences(of: "=", with: "")
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
        return ["tokens": ["account_id": "workspace", "access_token": "header.\(body).\(marker)", "refresh_token": marker]]
    }

    static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let accounts = root.appendingPathComponent(".codex/accounts")
        try FileManager.default.createDirectory(at: accounts, withIntermediateDirectories: true)
        let store = CodexAuthStore(home: root.path)
        let client = CodexClient(authStore: store)
        try testParsing(client)
        try testAccountFiles(store, root: root, accounts: accounts)
        try testAccessOnlyLiveAuth(root.appendingPathComponent("access-only"))
        testConfirmation()
        testPresentation()
        testPreferences()
        print("Codex tests passed (\(assertions) assertions).")
    }

    static func testParsing(_ client: CodexClient) throws {
        func parse(_ primary: [String: Any], _ secondary: [String: Any]?) throws -> DirectUsageSnapshot {
            let data = try json(["plan_type": "self_serve_business_prolite", "rate_limit": ["primary_window": primary, "secondary_window": secondary as Any? ?? NSNull()]])
            guard case .success(let usage) = client.parseDirectUsageResponse(data) else { fatalError("valid windows rejected") }
            return usage
        }
        let five: [String: Any] = ["used_percent": 1, "limit_window_seconds": 18_000, "reset_at": 1_800_000_000]
        let week: [String: Any] = ["used_percent": "17", "limit_window_seconds": 604_800]
        let normal = try parse(five, week)
        expect(normal.fiveHour.remainingPercent == 99 && normal.weekly.remainingPercent == 83, "usage converts used into remaining")
        expect(normal.planType == "self_serve_business_prolite", "raw plan is retained")
        expect(normal.fiveHour.resetAt == Date(timeIntervalSince1970: 1_800_000_000), "reset epoch retained")
        let reversed = try parse(week, five)
        expect(reversed.fiveHour == normal.fiveHour && reversed.weekly == normal.weekly, "duration determines window identity")
        let onlyWeekly = try parse(week, nil)
        expect(onlyWeekly.fiveHour.remainingPercent == 100 && onlyWeekly.weekly.remainingPercent == 83, "omitted post-reset window is full")
        let onlyShort = try parse(five, nil)
        expect(onlyShort.weekly.remainingPercent == 100, "omitted weekly window is full")
        let noDuration = try parse(["used_percent": 22], ["used_percent": 44])
        expect(noDuration.fiveHour.remainingPercent == 78 && noDuration.weekly.remainingPercent == 56, "legacy ordering works without durations")
        let extreme = try parse(["used_percent": Int.min], ["used_percent": Int.max])
        expect(extreme.fiveHour.remainingPercent == 100 && extreme.weekly.remainingPercent == 0, "out-of-range usage clamps without overflow")
        if case .failure = client.parseDirectUsageResponse(try json(["rate_limit": [:]])) {} else { fatalError("incomplete usage accepted") }
        if case .failure = client.parseDirectUsageResponse(Data("bad".utf8)) {} else { fatalError("invalid JSON accepted") }
        for receipt in [["code": "reset", "windows_reset": 2], ["success": true], ["windows_reset": ["five", "weekly"]]] as [[String: Any]] {
            guard case .success(let result) = client.parseResetConsumeResponse(try json(receipt)) else { fatalError("confirmation rejected") }
            expect(result.windowsReset >= 1, "confirmed receipt has a window")
        }
        for receipt in [["code": "noop", "windows_reset": 0], [:]] as [[String: Any]] {
            if case .failure = client.parseResetConsumeResponse(try json(receipt)) {} else { fatalError("false reset success") }
        }
    }

    static func testAccountFiles(_ store: CodexAuthStore, root: URL, accounts: URL) throws {
        let one: [String: Any] = ["account_key": "one-key", "email": "one@example.com", "chatgpt_account_id": "workspace", "chatgpt_user_id": "one"]
        let two: [String: Any] = ["account_key": "two-key", "email": "two@example.com", "chatgpt_account_id": "workspace", "chatgpt_user_id": "two"]
        let registry = accounts.appendingPathComponent("registry.json")
        try json(["active_account_key": "one-key", "accounts": [one, two]]).write(to: registry)
        func snapshot(_ key: String) -> URL {
            accounts.appendingPathComponent(Data(key.utf8).base64EncodedString().replacingOccurrences(of: "=", with: "") + ".auth.json")
        }
        let oneAuth = try auth(user: "one", marker: "old")
        let twoAuth = try auth(user: "two", marker: "other")
        try json(oneAuth).write(to: snapshot("one-key"))
        try json(twoAuth).write(to: snapshot("two-key"))
        let liveURL = root.appendingPathComponent(".codex/auth.json")
        try json(twoAuth).write(to: liveURL)
        guard case .success(let saved) = store.savedAuth(forEmail: "one@example.com") else { fatalError("saved account missing") }
        expect(saved.accessToken.hasSuffix(".old"), "same-workspace member uses its own snapshot")
        expect(store.syncActiveAuthSnapshot() == nil, "another member's live login is left alone")
        let savedData = try Data(contentsOf: snapshot("one-key"))
        let originalData = try json(oneAuth)
        expect(savedData == originalData, "wrong live member cannot overwrite active snapshot")
        try json(try auth(user: "one", marker: "new")).write(to: liveURL)
        guard case .success(let fresh) = store.savedAuth(forEmail: "one@example.com") else { fatalError("live account missing") }
        expect(fresh.accessToken.hasSuffix(".new"), "current matching live token wins over saved token")
        expect(store.syncActiveAuthSnapshot() == nil, "rotation saves successfully")
        guard case .success(let synced) = store.savedAuth(forEmail: "one@example.com") else { fatalError("sync lost account") }
        expect(synced.accessToken == fresh.accessToken, "rotation retains newest token")
        let permissions = try FileManager.default.attributesOfItem(atPath: snapshot("one-key").path)[.posixPermissions] as? NSNumber
        expect(permissions?.intValue == 0o600, "saved credentials remain owner-only")
        try json(twoAuth).write(to: snapshot("one-key"))
        try FileManager.default.removeItem(at: liveURL)
        if case .failure = store.savedAuth(forEmail: "one@example.com") {} else { fatalError("mismatched snapshot was accepted") }
        var legacy = one
        legacy.removeValue(forKey: "account_key")
        try json(["accounts": [legacy]]).write(to: registry)
        try json(oneAuth).write(to: accounts.appendingPathComponent("legacy.auth.json"))
        guard case .success(let fallback) = store.savedAuth(forEmail: "one@example.com") else { fatalError("legacy lookup failed") }
        expect(fallback.accessToken.hasSuffix(".old"), "legacy lookup confirms member as well as workspace")
        var accessOnly = oneAuth
        var tokens = accessOnly["tokens"] as! [String: Any]
        tokens.removeValue(forKey: "refresh_token")
        accessOnly["tokens"] = tokens
        try json(accessOnly).write(to: accounts.appendingPathComponent("legacy.auth.json"))
        guard case .success = store.savedAuth(forEmail: "one@example.com") else { fatalError("access-only legacy snapshot rejected") }

        if case .failure = store.savedAuth(forEmail: "missing@example.com") {} else { fatalError("unknown account accepted") }
    }

    static func testAccessOnlyLiveAuth(_ root: URL) throws {
        let accounts = root.appendingPathComponent(".codex/accounts")
        try FileManager.default.createDirectory(at: accounts, withIntermediateDirectories: true)
        let account: [String: Any] = ["account_key": "one-key", "email": "one@example.com", "chatgpt_account_id": "workspace", "chatgpt_user_id": "one"]
        try json(["active_account_key": "one-key", "accounts": [account]]).write(to: accounts.appendingPathComponent("registry.json"))
        func token(_ expires: Int) throws -> String {
            let body = try json(["exp": expires, "https://api.openai.com/auth": ["chatgpt_user_id": "one"]])
                .base64EncodedString().replacingOccurrences(of: "=", with: "")
                .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            return "header.\(body).signature"
        }
        let expired = try token(1)
        let fresh = try token(4_000_000_000)
        let snapshotURL = accounts.appendingPathComponent(Data("one-key".utf8).base64EncodedString().replacingOccurrences(of: "=", with: "") + ".auth.json")
        let oldSnapshot = try json(["tokens": ["account_id": "workspace", "access_token": expired, "refresh_token": "saved-refresh"]])
        try oldSnapshot.write(to: snapshotURL)
        try json(["tokens": ["account_id": "workspace", "access_token": fresh]]).write(to: root.appendingPathComponent(".codex/auth.json"))
        let store = CodexAuthStore(home: root.path)
        guard case .success(let read) = store.savedAuth(forEmail: "one@example.com") else { fatalError("fresh access-only live login rejected") }
        expect(read.accessToken == fresh && !AccessTokenClaims.isExpired(read.accessToken), "fresh access-only live credentials win over the expired snapshot")
        expect(store.syncActiveAuthSnapshot() == nil, "read-only live credentials do not require snapshot copying")
        let unchangedSnapshot = try Data(contentsOf: snapshotURL)
        expect(unchangedSnapshot == oldSnapshot, "snapshot replacement still requires a refresh token")
        try FileManager.default.removeItem(at: snapshotURL)
        guard case .success(let withoutSnapshot) = store.savedAuth(forEmail: "one@example.com") else { fatalError("access-only live login requires an unnecessary snapshot") }
        expect(withoutSnapshot.accessToken == fresh, "a matching live access token works without any saved snapshot")
    }

    static func testConfirmation() {
        let receipt = ResetConsumeReceipt(code: "reset", windowsReset: 2, message: "")
        let full = DirectUsageSnapshot(fiveHour: .init(remainingPercent: 100, resetAt: nil), weekly: .init(remainingPercent: 100, resetAt: nil))
        let confirmed = ResetConfirmation(previousCreditCount: 3, currentCreditCount: 2, receipt: receipt, usage: full)
        expect(confirmed.creditConfirmed && confirmed.usageConfirmed, "both independent confirmations required")
        expect(!ResetConfirmation(previousCreditCount: 3, currentCreditCount: 3, receipt: receipt, usage: full).creditConfirmed, "unchanged credits stay pending")
        expect(!ResetConfirmation(previousCreditCount: 3, currentCreditCount: 2, receipt: receipt, usage: nil).usageConfirmed, "missing live reading stays pending")
        expect(ResetConfirmation(previousCreditCount: nil, currentCreditCount: nil, receipt: receipt, usage: full).creditConfirmed, "receipt can confirm when previous count was unavailable")
        let partial = DirectUsageSnapshot(fiveHour: .init(remainingPercent: 99, resetAt: nil), weekly: .init(remainingPercent: 20, resetAt: nil))
        expect(!ResetConfirmation(previousCreditCount: 3, currentCreditCount: 2, receipt: receipt, usage: partial).usageConfirmed, "two-window reset needs weekly refill")
    }

    static func testPresentation() {
        let account = CodexAccount(selector: "01", email: "one@example.com", plan: "Business", fiveHourUsage: "-", weeklyUsage: "-", fiveHourRemaining: nil, weeklyRemaining: nil, lastActivity: "-", isActive: true)
        let applied = account.applying(.init(fiveHour: .init(remainingPercent: 100, resetAt: nil), weekly: .init(remainingPercent: 42, resetAt: nil), planType: "self_serve_business_prolite"))
        expect(!applied.hasFiveHourLimit && applied.fiveHourRemaining == 42, "weekly-only accounts use weekly capacity for switching")
        expect(applied.email == account.email && applied.isActive, "usage update preserves identity")
        expect(applied.planLabel == "Business · Premium", "plan label follows endpoint tier")
        expect(CodexUsageText.fiveHourReset(from: "90% (9:05)") == "09:05", "fallback clock padding preserved")
        expect(CodexUsageText.weeklyReset(from: "90% (Friday 09:00)") == "Fri 09:00", "fallback weekday parsing preserved")
        let table = CodexAuthListTable.parse("ACCOUNT EMAIL PLAN\n* 01 one@example.com Plus\n02 two@example.com Pro ignored columns\n")
        expect(table.count == 2 && table.first?.isActive == true, "legacy table keeps identity and active mark")
        expect(table.allSatisfy { $0.fiveHourRemaining == nil }, "local table never supplies stale usage")
    }

    static func testPreferences() {
        let suite = "CodexTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = AppPreferences(defaults: defaults)
        expect(preferences.remindersEnabled && preferences.reminderThreshold == 10, "reminder defaults preserved")
        defaults.set(true, forKey: "autoSwitchEnabled")
        expect(preferences.autoSwitchMode == .ask, "legacy automation preference retained")
        preferences.autoSwitchMode = .threshold
        expect(defaults.string(forKey: "autoSwitchMode") == "threshold" && defaults.bool(forKey: "autoSwitchEnabled"), "automation uses compatible keys")
        preferences.autoResumePrompt = "  "
        expect(!preferences.autoResumePrompt.isEmpty, "blank resume text retains default")
        preferences.setCustomLabel("Demo", forEmail: "one@example.com")
        expect(preferences.accountLabels()["one@example.com"] == "Demo", "custom labels persist")
        preferences.clearCustomLabel(forEmail: "one@example.com")
        expect(preferences.accountLabels().isEmpty, "label removal invalidates cache")
        expect(preferences.defaultLabel(forEmail: "+one@example.com") == "O", "public label is first alphanumeric character")
    }
}
