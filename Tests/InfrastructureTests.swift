import Foundation

@main
struct InfrastructureTests {
    private static var failures: [String] = []
    private static var assertionCount = 0

    static func main() throws {
        testResetRefreshPolicy()
        testUsageRefreshPolicy()
        testRateLimitBackoff()
        testLastKnownGoodSnapshotPolicy()
        try testComputerUsePluginDiscovery()
        try testBackupPruning()
        testProcessRunner()
        testLimitResetWatcher()
        testCursorUsageExport()
        testClaudeResets()

        if failures.isEmpty {
            print("Infrastructure tests passed (\(assertionCount) assertions).")
            return
        }

        for failure in failures {
            FileHandle.standardError.write(Data("FAIL: \(failure)\n".utf8))
        }
        exit(1)
    }

    private static func testCursorUsageExport() {
        let csv = """
        Date,Cloud Agent ID,Automation ID,Kind,Model,Max Mode,Input (w/ Cache Write),Input (w/o Cache Write),Cache Read,Output Tokens,Total Tokens,Cost
        "2026-10-23T05:46:06.987Z","","","Included","claude-sonnet-5-5-medium","No","24029","4","0","2080","26113","Included"
        "2026-10-23T05:50:00.000Z","","","Included","claude-sonnet-5-5-medium","No","100","100","50","10","160","Included"
        "not a date","","","Included","x","No","1","1","1","1","4","Included"
        "2026-10-23T06:10:00.000Z","","","Included","","No","0","0","0","0","0","Included"
        """
        let records = AnalyticsCursorCSV.parse(csv)
        expect(records.count == 2, "rows with a bad date or no tokens are skipped")
        expect(records.first?.cacheWrite == 24025 && records.first?.input == 4, "cache write is input with write minus input without")
        expect(records.first?.counts.total == 26109, "total is input, cache write, cache read and output")
        expect(AnalyticsCursorCSV.parse("Date,Model\n1,2").isEmpty, "a missing column yields no records")

        let awkward = "\u{FEFF}Date,Model,Input (w/ Cache Write),Input (w/o Cache Write),Cache Read,Output Tokens\r\n\"2026-10-23T05:46:06Z\",\"a,\"\"b\"\"\nc\",\"1e100\",\"NaN\",\"inf\",\"7\"\r\n"
        let parsed = AnalyticsCursorCSV.parse(awkward)
        expect(parsed.count == 1 && parsed[0].model == "a,\"b\"\nc" && parsed[0].output == 7, "BOM, CRLF and quoted commas, quotes and newlines parse")
        expect(parsed.first.map { $0.cacheRead == 0 && $0.input == 0 } == true, "NaN and inf cells count as zero without trapping")

        var store = AnalyticsStore()
        expect(store.replaceCursorUsage(records), "first import changes the store")
        expect(store.buckets.values.reduce(0) { $0 + $1.counts.total } == 26109 + 160, "buckets hold every record")
        expect(!store.replaceCursorUsage(records), "re-importing the same export changes nothing")
        let later = AnalyticsCursorRecord(seconds: records[0].seconds + 3600, model: "m2", input: 50, cacheWrite: 0, cacheRead: 0, output: 50)
        store.replaceCursorUsage(records + [later])
        let corrected = AnalyticsCursorRecord(seconds: later.seconds, model: "m2", input: 1, cacheWrite: 0, cacheRead: 0, output: 1)
        expect(store.replaceCursorUsage(records + [corrected]), "a corrected export replaces the old rows")
        expect(store.buckets.values.reduce(0) { $0 + $1.counts.total } == 26109 + 160 + 2, "corrected rows after the earliest event are rebuilt")
        store = AnalyticsStore()
        store.replaceCursorUsage(records)
        let older = AnalyticsCursorRecord(seconds: records[0].seconds - 86_400 * 3, model: "m", input: 5, cacheWrite: 0, cacheRead: 0, output: 5)
        store.replaceCursorUsage([older])
        expect(store.buckets.keys.contains { $0.model == "m" } && store.buckets.values.reduce(0) { $0 + $1.counts.total } == 10, "a windowed export wipes only from its earliest event")
        var partial = AnalyticsStore()
        partial.buckets[AnalyticsBucketKey(source: .cursor, model: "m", halfHour: AnalyticsTime.halfHour(Double(records[0].seconds)))] = {
            var bucket = AnalyticsBucket(); bucket.add(AnalyticsCursorRecord(seconds: 0, model: "m", input: 900, cacheWrite: 0, cacheRead: 0, output: 0).counts, conversations: 1, tier: nil); return bucket
        }()
        partial.replaceCursorUsage([AnalyticsCursorRecord(seconds: records[0].seconds, model: "m", input: 10, cacheWrite: 0, cacheRead: 0, output: 0)])
        expect(partial.buckets.values.reduce(0) { $0 + $1.counts.total } == 900, "the earliest half hour of a windowed export never shrinks")
        var other = AnalyticsStore()
        other.buckets[AnalyticsBucketKey(source: .codex, model: "gpt", halfHour: 1)] = AnalyticsBucket()
        other.replaceCursorUsage(records)
        expect(other.buckets.keys.contains { $0.source == .codex }, "other sources are never touched")
    }

    private static func testClaudeResets() {
        let usage: [String: Any] = [
            "five_hour": ["utilization": 9],
            "cedar_ember": [
                "eligible": true,
                "grants": [
                    ["id": "launch-2610-fable", "label": "One Fable reset", "resets_total": 1, "resets_left": 1,
                     "ends_at": "2027-03-09T07:59:00+00:00", "clears": ["five_hour", "seven_day_overage_included"],
                     "paused": false, "usable_now": true, "type": "full"],
                    ["id": "used-up", "resets_left": 0, "usable_now": false],
                    ["id": "paused-one", "resets_left": 2, "paused": true],
                    ["id": "BAD ID", "resets_left": 1],
                    ["id": "blocked", "resets_left": 2, "usable_now": false, "type": "session", "unavailable_reason": "cooldown"]
                ]
            ],
            "juniper_tide": ["eligible": true, "available": true]
        ]
        let status = ClaudeResetStatus.parse(usage: usage)
        expect(status?.eligible == true, "an eligible cedar block is eligible")
        expect(status?.grants.map(\.id) == ["launch-2610-fable", "blocked", ClaudeResetGrant.fiveHourProgram], "used, paused and malformed grants are dropped; the 5-hour reset is added")
        expect(status?.availableCount == 4, "available count sums resets left")
        expect(status?.usableCount == 2, "usable count skips grants that cannot be used now")
        let full = status?.grants.first
        expect(full?.endsAt != nil && full?.kind == "full" && full?.usableNow == true, "grant fields parse")
        expect(full?.clearedText == "5-hour + weekly", "clears are described without duplicates")
        expect(status?.grants[1].unavailableText == "A reset was used recently", "unavailable reasons are described")

        let ineligible = ClaudeResetStatus.parse(usage: ["cedar_ember": ["eligible": false, "ineligible_reason": "tier", "grants": []], "juniper_tide": NSNull()])
        expect(ineligible?.eligible == false && ineligible?.grants.isEmpty == true && ineligible?.ineligibleReason == "tier", "ineligible accounts have no grants")
        expect(ClaudeResetStatus.parse(usage: ["five_hour": [:]]) == nil, "no reset blocks yields nil")
        let huge = ClaudeResetStatus.parse(usage: ["cedar_ember": ["eligible": true, "grants": [["id": "a", "resets_left": Int.max], ["id": "b", "resets_left": 1]]]])
        expect(huge?.grants.map(\.id) == ["b"] && huge?.availableCount == 1, "absurd reset counts are dropped instead of overflowing")
        expect(ClaudeResetStatus.parse(usage: ["cedar_ember": "garbage"]) == nil, "a malformed block yields nil")

        let body = ClaudeResetAPI.claimBody(program: ClaudeResetGrant.grantProgram, grantID: "launch-2610-fable", requestID: "8D1C-aa_9")
        expect(body?["grant_id"] == "launch-2610-fable" && body?["program"] == "cedar_ember" && body?["request_id"] == "8D1C-aa_9", "grant claims carry program, grant and request ids")
        expect(ClaudeResetAPI.claimBody(program: ClaudeResetGrant.fiveHourProgram, grantID: ClaudeResetGrant.fiveHourProgram, requestID: "x") == ["program": "juniper_tide"], "the 5-hour reset claim sends the program only")
        expect(ClaudeResetAPI.claimBody(program: "cedar_ember", grantID: "../x", requestID: "a") == nil, "malformed grant ids are refused")
        expect(ClaudeResetAPI.claimBody(program: "other", grantID: "a", requestID: "a") == nil, "unknown programs are refused")
        expect(ClaudeResetAPI.claimURL(organizationID: "1b2c-3d")?.absoluteString == "https://api.anthropic.com/api/organizations/1b2c-3d/reset_rate_limits", "claim URL uses the organization id")
        expect(ClaudeResetAPI.claimURL(organizationID: "a/../b") == nil && ClaudeResetAPI.claimURL(organizationID: "") == nil, "unsafe organization ids are refused")

        expect(ClaudeResetAPI.parseClaim(["result": "reset", "cleared": ["five_hour"]]) == .reset(confirmed: true, cleared: "5-hour"), "a reset result is confirmed")
        expect(ClaudeResetAPI.parseClaim(["result": "reset", "reason": "reset_unconfirmed"]) == .reset(confirmed: false, cleared: ""), "an unconfirmed reset is pending")
        if case .refused = ClaudeResetAPI.parseClaim(["result": "already_used"]) {} else { expect(false, "already used is refused") }
        if case .refused = ClaudeResetAPI.parseClaim(["result": 3]) {} else { expect(false, "an unreadable result is refused") }

        expect(ClaudeResetAPI.cliVersion(fromPath: "/x/versions/2.1.319") == "2.1.319", "CLI version comes from the versions path")
        expect(ClaudeResetAPI.cliVersion(fromPath: "/usr/local/bin/claude") == ClaudeResetAPI.fallbackCLIVersion, "unknown paths fall back")
        expect(ClaudeResetAPI.userAgent(version: "2.1.319") == "claude-cli/2.1.319 (external, cli)", "user agent matches Claude Code")
    }

    private static func testLimitResetWatcher() {
        func limit(_ remaining: Int, key: String = "a") -> WatchedLimit { WatchedLimit(key: key, title: key, remaining: remaining) }
        var watcher = LimitResetWatcher()
        expect(watcher.observe([limit(10)]).isEmpty, "first observation never celebrates")
        expect(watcher.observe([limit(100)]).count == 1, "refill after being near the limit celebrates")
        expect(watcher.observe([limit(100)]).isEmpty, "a steady full window does not celebrate again")
        var relaxed = LimitResetWatcher()
        _ = relaxed.observe([limit(80)])
        expect(relaxed.observe([limit(100)]).isEmpty, "refill from a comfortable level does not celebrate")
        var drifting = LimitResetWatcher()
        _ = drifting.observe([limit(60)])
        _ = drifting.observe([limit(15)])
        expect(drifting.observe([limit(95)]).count == 1, "the lowest value since the last reset counts")
        var independent = LimitResetWatcher()
        _ = independent.observe([limit(10, key: "a"), limit(10, key: "b")])
        expect(independent.observe([limit(100, key: "a"), limit(10, key: "b")]).map(\.key) == ["a"], "windows are tracked independently")
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        assertionCount += 1
        if !condition() { failures.append(message) }
    }

    private static func testResetRefreshPolicy() {
        let now = Date(timeIntervalSince1970: 1_000)
        expect(ResetRefreshPolicy.shouldRefresh(lastRefresh: nil, now: now, ttl: 300, force: false), "missing reset snapshot should refresh")
        expect(!ResetRefreshPolicy.shouldRefresh(lastRefresh: now.addingTimeInterval(-299), now: now, ttl: 300, force: false), "fresh reset snapshot should stay cached")
        expect(ResetRefreshPolicy.shouldRefresh(lastRefresh: now.addingTimeInterval(-300), now: now, ttl: 300, force: false), "expired reset snapshot should refresh")
        expect(ResetRefreshPolicy.shouldRefresh(lastRefresh: now, now: now, ttl: 300, force: true), "forced reset refresh should bypass cache")
    }

    private static func testUsageRefreshPolicy() {
        let now = Date(timeIntervalSince1970: 2_000)
        expect(UsageRefreshPolicy.shouldRefresh(lastRefresh: nil, now: now, ttl: 30, force: false), "missing usage snapshot should refresh")
        expect(!UsageRefreshPolicy.shouldRefresh(lastRefresh: now.addingTimeInterval(-29), now: now, ttl: 30, force: false), "fresh usage snapshot should stay cached")
        expect(UsageRefreshPolicy.shouldRefresh(lastRefresh: now.addingTimeInterval(-30), now: now, ttl: 30, force: false), "expired usage snapshot should refresh")
        expect(UsageRefreshPolicy.shouldRefresh(lastRefresh: now, now: now, ttl: 30, force: true), "forced usage refresh should bypass cache")
    }

    private static func testRateLimitBackoff() {
        let now = Date(timeIntervalSince1970: 10_000)
        var backoff = RateLimitBackoff()
        expect(backoff.retryAt("a", now: now) == nil, "an unseen key is not cooling down")

        let first = backoff.recordLimited("a", retryAfter: nil, now: now)
        expect(first == now.addingTimeInterval(120), "the first 429 without Retry-After waits 2 minutes")
        expect(backoff.retryAt("a", now: now.addingTimeInterval(60)) == first, "the key stays blocked until the retry time")
        expect(backoff.retryAt("a", now: now.addingTimeInterval(120)) == nil, "the key is free at the retry time")
        expect(backoff.retryAt("b", now: now) == nil, "other keys are unaffected")

        let second = backoff.recordLimited("a", retryAfter: nil, now: now)
        expect(second == now.addingTimeInterval(240), "repeated 429s double the wait")
        for _ in 0..<10 { _ = backoff.recordLimited("a", retryAfter: nil, now: now) }
        expect(backoff.retryAt("a", now: now) == now.addingTimeInterval(1_800), "the wait is capped at 30 minutes")

        let honored = backoff.recordLimited("c", retryAfter: 600, now: now)
        expect(honored == now.addingTimeInterval(600), "Retry-After longer than the backoff is honored")

        backoff.recordSuccess("a")
        expect(backoff.retryAt("a", now: now) == nil, "success clears the cooldown")
        expect(backoff.recordLimited("a", retryAfter: nil, now: now) == now.addingTimeInterval(120), "success resets the doubling")

        expect(RateLimitBackoff.parseRetryAfter("90", now: now) == 90, "Retry-After seconds parse")
        let httpDate = RateLimitBackoff.parseRetryAfter("Thu, 01 Jan 1970 03:00:00 GMT", now: now)
        expect(httpDate == 800, "Retry-After HTTP dates parse relative to now")
        expect(RateLimitBackoff.parseRetryAfter("soon", now: now) == nil, "an unreadable Retry-After is ignored")
        expect(RateLimitBackoff.parseRetryAfter(nil, now: now) == nil, "a missing Retry-After is ignored")
    }

    private static func testLastKnownGoodSnapshotPolicy() {
        let current = ["one": 100, "two": 100, "removed": 42]
        let merged = LastKnownGoodSnapshotPolicy.merged(
            current: current,
            successful: ["one": 99],
            validKeys: Set(["one", "two", "three"])
        )
        expect(merged["one"] == 99, "new successful usage should replace the previous reading")
        expect(merged["two"] == 100, "a failed or missing refresh should retain the last known good reading")
        expect(merged["three"] == nil, "an account without a successful reading should not invent usage")
        expect(merged["removed"] == nil, "removed accounts should be pruned from retained usage")

        let unchanged = LastKnownGoodSnapshotPolicy.merged(
            current: ["one": 100, "two": 100],
            successful: [:],
            validKeys: Set(["one", "two"])
        )
        expect(unchanged == ["one": 100, "two": 100], "a wholly failed refresh should not roll usage back")
    }

    private static func testComputerUsePluginDiscovery() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for version in ["1.0.799", "1.0.1000366", "1.2.1"] {
            try FileManager.default.createDirectory(
                at: root.appendingPathComponent(version).appendingPathComponent("Codex Computer Use.app"),
                withIntermediateDirectories: true
            )
        }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("9.9.9"), withIntermediateDirectories: true)
        let found = ComputerUsePluginLocator.latestApp(in: root)
        expect(found?.deletingLastPathComponent().lastPathComponent == "1.2.1", "plugin discovery should use the newest valid numeric version")
        expect(found?.lastPathComponent == "Codex Computer Use.app", "plugin discovery should return the app bundle")
    }

    private static func testBackupPruning() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for stamp in 1...5 {
            let url = root.appendingPathComponent("account.auth.json.bak.\(stamp)")
            FileManager.default.createFile(atPath: url.path, contents: Data())
        }
        FileManager.default.createFile(atPath: root.appendingPathComponent("account.auth.json").path, contents: Data())
        let removed = AuthBackupPruner.prune(in: root, keepingPerAccount: 2)
        let remaining = try FileManager.default.contentsOfDirectory(atPath: root.path)
        expect(removed == 3, "backup pruning should report removed files")
        expect(remaining.contains("account.auth.json.bak.5"), "backup pruning should keep newest backup")
        expect(remaining.contains("account.auth.json.bak.4"), "backup pruning should keep requested backup count")
        expect(remaining.contains("account.auth.json"), "backup pruning should preserve active auth snapshot")
    }

    private static func testProcessRunner() {
        let environment = ProcessInfo.processInfo.environment
        let success = ProcessRunner.run("/bin/echo", ["healthy"], environment: environment, timeout: 2)
        expect(success.status == 0 && success.output.contains("healthy"), "process runner should capture successful output")
        let timeout = ProcessRunner.run("/bin/sleep", ["2"], environment: environment, timeout: 0.1)
        expect(timeout.status == 124 && timeout.output.contains("timed out"), "process runner should terminate stalled commands")
    }
}
