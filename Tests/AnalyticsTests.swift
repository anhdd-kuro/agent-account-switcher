import Foundation

@main
struct AnalyticsTests {
    static func main() throws {
        try incrementalScanning()
        try rewrittenFilesAndLateForks()
        try versionTwoPersistence()
        try compactionAndModelAttribution()
        try oversizedRecords()
        try compressedRecords()
        snapshotAndPricing()
        print("Analytics tests passed")
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else { fatalError(message) }
    }

    private static func temporaryDirectory(_ body: (URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("switcher-analytics-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(directory)
    }

    private static func roots(_ directory: URL) -> AnalyticsLogRoots {
        AnalyticsLogRoots(codexSessions: directory.appendingPathComponent("codex/sessions"),
                          codexArchived: directory.appendingPathComponent("codex/archived_sessions"),
                          claudeProjects: [directory.appendingPathComponent("claude/projects")])
    }

    @discardableResult
    private static func scan(_ store: inout AnalyticsStore, in directory: URL) -> AnalyticsScanner.Outcome {
        AnalyticsScanner(roots: roots(directory), projects: AnalyticsProjectResolver(cache: [:])).scan(&store) { _, _ in }
    }

    private static func write(_ data: Data, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
    }

    private static func codexPath(in directory: URL) -> URL {
        roots(directory).codexSessions.appendingPathComponent("2026/10/20/rollout-2026-10-20T01-00-00-00000000-0000-0000-0000-000000000001.jsonl")
    }

    private static func codexLog() -> Data {
        Data(([
            #"{"type":"session_meta","payload":{"model":"gpt-fixture"}}"#,
            #"{"type":"event_msg","timestamp":"2026-10-20T01:00:00Z","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":10,"cached_input_tokens":2,"output_tokens":5,"total_tokens":15},"total_token_usage":{"input_tokens":10,"cached_input_tokens":2,"output_tokens":5,"total_tokens":15}}}}"#,
            #"{"type":"event_msg","timestamp":"2026-10-20T01:01:00Z","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":4,"cached_input_tokens":1,"output_tokens":3,"total_tokens":7},"total_token_usage":{"input_tokens":14,"cached_input_tokens":3,"output_tokens":8,"total_tokens":22}}}}"#
        ].joined(separator: "\n") + "\n").utf8)
    }

    private static func claudeUser(_ uuid: String, parent: String? = nil) -> String {
        let fork = parent.map { #","forkedFrom":{"messageUuid":"\#($0)"}"# } ?? ""
        return #"{"type":"user","cwd":"/fixture/project","uuid":"\#(uuid)","timestamp":"2026-10-20T01:00:00Z","message":{"content":"fixture prompt"}\#(fork)}"# + "\n"
    }

    private static func claudeUsage(id: String, input: Int, model: String = "claude-fixture") -> String {
        #"{"type":"assistant","cwd":"/fixture/project","requestId":"fixture-request","timestamp":"2026-10-20T01:00:00Z","message":{"id":"\#(id)","model":"\#(model)","usage":{"input_tokens":\#(input),"output_tokens":2,"output_tokens_details":{"thinking_tokens":1}}}}"# + "\n"
    }

    private static func incrementalScanning() throws {
        try temporaryDirectory { directory in
            let full = directory.appendingPathComponent("full"), steps = directory.appendingPathComponent("steps")
            let claude = Data((claudeUser("fixture-user") + claudeUsage(id: "fixture-message", input: 11)).utf8)
            let files = [(codexPath(in: full), codexPath(in: steps), codexLog()),
                         (roots(full).claudeProjects[0].appendingPathComponent("p/session.jsonl"),
                          roots(steps).claudeProjects[0].appendingPathComponent("p/session.jsonl"), claude)]
            for (path, _, data) in files { try write(data, to: path) }
            var expected = AnalyticsStore(), incremental = AnalyticsStore()
            scan(&expected, in: full)
            for fraction in [0.17, 0.51, 0.83, 1.0] {
                for (_, path, data) in files {
                    let cut = Int(Double(data.count) * fraction)
                    try write(Data(data.prefix(cut)), to: path)
                }
                scan(&incremental, in: steps)
            }
            expect(expected.buckets == incremental.buckets, "partial-record scans must match one full scan")
            expect(expected.buckets.values.saturatingSum { $0.counts.total } == 35, "provider token totals survive normalization")
            expect(expected.buckets.values.saturatingSum { $0.conversations } == 3, "provider conversation semantics remain unchanged")
            expect(scan(&incremental, in: steps).filesParsed == 0, "unchanged logs must not be parsed again")

            for (_, path, data) in files { try data.write(to: path, options: .atomic) }
            scan(&incremental, in: steps)
            expect(expected.buckets == incremental.buckets, "atomic rewrites must not count old events twice")
            let archived = roots(steps).codexArchived.appendingPathComponent(codexPath(in: steps).lastPathComponent)
            try FileManager.default.createDirectory(at: archived.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: codexPath(in: steps), to: archived)
            scan(&incremental, in: steps)
            expect(expected.buckets == incremental.buckets, "archiving a rollout must not count it twice")
        }
    }

    private static func rewrittenFilesAndLateForks() throws {
        try temporaryDirectory { directory in
            let projects = roots(directory).claudeProjects[0].appendingPathComponent("p")
            let path = projects.appendingPathComponent("usage.jsonl")
            let pad = String(repeating: "x", count: 5000)
            func log(_ id: String, _ model: String, _ count: Int) -> Data {
                Data((#"{"type":"system","note":"\#(pad)"}"# + "\n" + claudeUsage(id: id, input: count, model: model)
                      + #"{"type":"system","note":"\#(pad)"}"# + "\n").utf8)
            }
            try write(log("message-a", "model-aaa", 111), to: path)
            var store = AnalyticsStore()
            scan(&store, in: directory)
            let handle = try FileHandle(forWritingTo: path)
            try handle.write(contentsOf: log("message-b", "model-bbb", 222))
            try handle.close()
            try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(5)], ofItemAtPath: path.path)
            scan(&store, in: directory)
            expect(store.buckets.keys.contains { $0.model == "model-bbb" }, "same-size middle rewrites must be detected")

            try write(Data(claudeUser("child", parent: "parent").utf8), to: projects.appendingPathComponent("a-child.jsonl"))
            scan(&store, in: directory)
            try write(Data(claudeUser("parent", parent: "root").utf8), to: projects.appendingPathComponent("b-parent.jsonl"))
            try write(Data(claudeUser("root").utf8), to: projects.appendingPathComponent("c-root.jsonl"))
            scan(&store, in: directory)
            expect(store.buckets.values.saturatingSum { $0.conversations } == 1, "fork aliases arriving later must merge already counted conversations")
            expect(store.claudeConversations["u:root"] != nil, "conversation identity must follow the complete fork chain")
        }
    }

    private static func versionTwoPersistence() throws {
        try temporaryDirectory { directory in
            let file = codexPath(in: directory)
            try write(codexLog(), to: file)
            let claudeFile = roots(directory).claudeProjects[0].appendingPathComponent("p/session.jsonl")
            try write(Data(claudeUsage(id: "persisted", input: 9).utf8), to: claudeFile)
            var original = AnalyticsStore()
            scan(&original, in: directory)
            let encoder = PropertyListEncoder()
            let data = try encoder.encode(original)
            var plist = try PropertyListSerialization.propertyList(from: data, format: nil) as! [String: Any]
            expect(plist["version"] as? Int == 2, "state compatibility must not force a full rescan")
            for key in ["codexFiles", "claudeFiles"] {
                var cursors = plist[key] as! [String: [String: Any]]
                for path in cursors.keys { cursors[path]?["session"] = ["turns": 7, "models": ["retired": 42]] }
                plist[key] = cursors
            }
            let legacy = try PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0)
            let persistence = AnalyticsPersistence(directory: directory.appendingPathComponent("state"))
            try FileManager.default.createDirectory(at: persistence.directory, withIntermediateDirectories: true)
            try legacy.write(to: persistence.stateURL)
            guard var restored = persistence.load() else { fatalError("existing v2 state with retired session keys must decode") }
            expect(restored.buckets == original.buckets, "legacy buckets must survive decoding")
            expect(restored.codexFiles[file.path]?.offset == original.codexFiles[file.path]?.offset, "legacy Codex offset must survive decoding")
            expect(restored.codexFiles[file.path]?.stream == original.codexFiles[file.path]?.stream, "legacy Codex cumulative state must survive decoding")
            expect(restored.claudeFiles[claudeFile.path]?.offset == original.claudeFiles[claudeFile.path]?.offset, "legacy Claude offset must survive decoding")
            scan(&restored, in: directory)
            expect(restored.buckets == original.buckets, "loading legacy state must not recount logs")
            try persistence.save(restored)
            expect(persistence.load()?.buckets == original.buckets, "new state must round-trip without losing buckets")
        }
    }

    private static func compactionAndModelAttribution() throws {
        try temporaryDirectory { directory in
            let path = codexPath(in: directory)
            let before = String(decoding: codexLog(), as: UTF8.self)
                + #"{"type":"event_msg","payload":{"type":"thread_settings_applied","thread_settings":{"service_tier":"fast"}}}"# + "\n"
                + #"{"type":"token_usage_record","timestamp":"2026-10-20T01:02:00Z","payload":{"response_id":"fixture-compaction","usage":{"input_tokens":3,"output_tokens":2,"total_tokens":5}}}"# + "\n"
            try write(Data(before.utf8), to: path)
            var store = AnalyticsStore()
            scan(&store, in: directory)
            let persistence = AnalyticsPersistence(directory: directory.appendingPathComponent("state"))
            try persistence.save(store)
            store = persistence.load()!
            let after = #"{"type":"compacted"}"# + "\n"
                + #"{"type":"event_msg","timestamp":"2026-10-20T01:03:00Z","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":14,"cached_input_tokens":3,"output_tokens":8,"total_tokens":22}}}}"# + "\n"
                + #"{"method":"model/rerouted","params":{"fromModel":"gpt-fixture","toModel":"gpt-rerouted"}}"# + "\n"
                + #"{"type":"event_msg","timestamp":"2026-10-20T01:04:00Z","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":2,"output_tokens":1,"total_tokens":3},"total_token_usage":{"input_tokens":16,"cached_input_tokens":3,"output_tokens":9,"total_tokens":25}}}}"# + "\n"
            let append = try FileHandle(forWritingTo: path)
            try append.seekToEnd()
            try append.write(contentsOf: Data(after.utf8))
            try append.close()
            scan(&store, in: directory)
            expect(store.buckets.values.saturatingSum { $0.counts.total } == 30, "a confirmed compaction must count once after resuming a persisted cursor")
            let rerouted = store.buckets.first { $0.key.model == "gpt-rerouted" }?.value
            expect(rerouted?.counts.total == 3 && rerouted?.priority.total == 3, "reroutes and fast-tier settings must determine subsequent bucket attribution")
            try Data((before + after).utf8).write(to: path, options: .atomic)
            scan(&store, in: directory)
            expect(store.buckets.values.saturatingSum { $0.counts.total } == 30, "replaying a confirmed compaction must not count it again")
        }
    }

    private static func oversizedRecords() throws {
        try temporaryDirectory { directory in
            let file = roots(directory).claudeProjects[0].appendingPathComponent("p/session.jsonl")
            try write(Data(claudeUsage(id: "before-large-record", input: 3).utf8), to: file)
            let handle = try FileHandle(forWritingTo: file)
            try handle.seekToEnd()
            let block = Data(repeating: UInt8(ascii: "a"), count: 1 << 20)
            for _ in 0..<65 { try handle.write(contentsOf: block) }
            try handle.close()
            var store = AnalyticsStore()
            let first = scan(&store, in: directory)
            var truncatedStore = store
            expect(first.oversizedLines == 1, "an oversized unterminated record must be reported once")
            expect(scan(&store, in: directory).filesParsed == 0, "an unchanged discarded tail must not be reread")
            let append = try FileHandle(forWritingTo: file)
            try append.seekToEnd()
            try append.write(contentsOf: Data(("\n" + claudeUsage(id: "after-large-record", input: 7)).utf8))
            try append.close()
            scan(&store, in: directory)
            expect(store.buckets.values.saturatingSum { $0.counts.total } == 14, "scanning must resume after a discarded record")
            expect(store.claudeFiles[file.path]?.discardingFrom == nil, "the discarded-tail position must clear at the newline")

            let truncated = Data((claudeUsage(id: "before-large-record", input: 3) + claudeUsage(id: "after-truncation", input: 13)).utf8)
            let truncate = try FileHandle(forWritingTo: file)
            try truncate.truncate(atOffset: 0)
            try truncate.write(contentsOf: truncated)
            try truncate.close()
            scan(&truncatedStore, in: directory)
            expect(truncatedStore.buckets.values.saturatingSum { $0.counts.total } == 20, "truncation inside a discarded tail must restart the cursor and retain prior history")
        }
    }

    private static func compressedRecords() throws {
        let hello = Data([0x28, 0xb5, 0x2f, 0xfd, 0x20, 0x06, 0x31, 0x00, 0x00, 0x68, 0x65, 0x6c, 0x6c, 0x6f, 0x0a])
        let decompressed = try AnalyticsZstd.decompress(hello, limit: 1024)
        expect(decompressed == Data("hello\n".utf8), "a raw zstd frame must decode")
        let corrupt = [Data([0x28, 0xb5, 0x2f]),
                       Data([0x28, 0xb5, 0x2f, 0xfd, 0xe0, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0x7f, 0x01, 0x00, 0x00])]
        for data in corrupt {
            do { _ = try AnalyticsZstd.decompress(data, limit: 1024); fatalError("corrupt or oversized frame was accepted") }
            catch AnalyticsZstd.Failure.corrupt {} catch AnalyticsZstd.Failure.tooLarge {}
        }
    }

    private static func snapshotAndPricing() {
        let time = ISO8601DateFormatter()
        let now = time.date(from: "2026-11-02T07:45:00Z")!
        let halfHour = AnalyticsTime.halfHour(now.timeIntervalSince1970)
        var store = AnalyticsStore()
        var bucket = AnalyticsBucket()
        bucket.add(AnalyticsCounts(fields: [100, 20, 10, 30, 5, 160]), conversations: 2, tier: .priority)
        store.buckets[AnalyticsBucketKey(source: .codex, model: "fixture", halfHour: halfHour)] = bucket
        store.buckets[AnalyticsBucketKey(source: .codex, model: "unknown", halfHour: halfHour)] = bucket
        let pricing = try! AnalyticsPricing(data: Data(#"{"exact":{"fixture":{"input":2,"output":4,"cache_read":1,"cache_write":3,"priority_multiplier":2}},"fuzzy":[],"litellm":[]}"#.utf8))
        let snapshot = AnalyticsSnapshotBuilder(pricing: pricing, timeZone: TimeZone(identifier: "America/Los_Angeles")!, now: now).build(store: store, period: .day)
        expect(snapshot.trend.count == 25, "the fall-back day must include all 25 elapsed hours")
        expect(snapshot.trend.saturatingSum { $0.segments.saturatingSum { $0.tokens } } == 320, "DST trend bars must retain all daily tokens")
        expect(snapshot.totals.total == 320 && snapshot.topModels.count == 1 && snapshot.topModels[0].name == "fixture", "unknown usage must fold into the dominant model within the same provider half-hour")
        expect(abs(snapshot.totals.costUSD - 0.00148) < 1e-12, "bucket prices must preserve priority and Codex reasoning semantics")
        expect((AnalyticsHeatmap.weeks - 1) * 7 < snapshot.heatmap.count && snapshot.heatmap.count <= AnalyticsHeatmap.weeks * 7, "heatmap must cover the configured week columns")
        expect(abs(pricing.cost(source: .claude, model: "fixture", bucket: bucket) - 0.00078) < 1e-12, "Claude reasoning must be priced separately from output")

        var saturated = AnalyticsCounts(fields: [Int.max - 1, 0, 0, 0, 0, Int.max - 1])
        saturated.add(AnalyticsCounts(fields: [10, 0, 0, 0, 0, 10]))
        expect(saturated.input == .max && saturated.total == .max, "large token aggregates must saturate")
        expect(AnalyticsClaudeParser.normalize(["input_tokens": NSNumber(value: 1e100), "output_tokens": 2]).total == 2, "hostile token counts must be rejected before integer conversion")
    }
}
