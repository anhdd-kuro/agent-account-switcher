import Foundation

struct AnalyticsClaudeCursor: Codable, AnalyticsLogCursor {
    var inode: UInt64
    var size: Int64
    var mtime: Double
    var offset: Int64
    /// `AnalyticsFingerprint` of the bytes before `offset` (plain .jsonl only).
    var fingerprint: UInt64?
    /// Read position inside an oversized record being discarded (see `AnalyticsLines.streamRecords`).
    var discardingFrom: Int64?

    var cwd: String?
    var cwdChecked = false
    var projectKey: String?
}

enum AnalyticsClaudeEvent {
    case fork(uuid: String, parent: String)
    case conversation(uuid: String?, halfHour: Int64)
    case usage(key: String?, model: String, halfHour: Int64, delta: AnalyticsCounts)
}

/// Dedup is applied later, serially, because the message-id set is global across files.
struct AnalyticsClaudeParser {
    var cursor: AnalyticsClaudeCursor
    private(set) var events: [AnalyticsClaudeEvent] = []
    let isMainSession: Bool

    init(path: String, cursor: AnalyticsClaudeCursor) {
        self.cursor = cursor
        isMainSession = !path.contains("/subagents/")
    }

    /// First top-level `cwd` within the first 64 KiB (`resolveClaudeFileCwd`, R:4977).
    static func fileCwd(path: String) -> String? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: 65_536) else { return nil }
        var found: String?
        _ = head.withUnsafeBytes { buffer in
            AnalyticsLines.forEach(in: buffer, includeTail: true) { line in
                guard found == nil, line.contains("\"cwd\""), let obj = line.jsonObject() else { return }
                found = obj.trimmedString("cwd")
            }
        }
        return found
    }

    mutating func consume(_ line: AnalyticsLine) {
        let maybeUser = line.contains("\"type\":\"user\"")
        let maybeUsage = line.contains("\"usage\"")
        guard maybeUser || maybeUsage else { return }
        guard let obj = line.jsonObject() else { return }
        let timestamp = obj.string("timestamp")
        let type = obj.string("type")
        if type == "user" {
            if isMainSession { noteConversation(obj, timestamp: timestamp) }
        }
        if maybeUsage { countUsage(obj, timestamp: timestamp) }
    }

    private mutating func noteConversation(_ obj: [String: Any], timestamp: String?) {
        let uuid = obj.string("uuid").flatMap { $0.isEmpty ? nil : $0 }
        if let uuid, let parent = obj.object("forkedFrom")?.string("messageUuid"), !parent.isEmpty, parent != uuid {
            events.append(.fork(uuid: uuid, parent: parent))
        }
        let content = obj.object("message")?["content"]
        let hasText = content is String || (content as? [Any])?.contains { ($0 as? [String: Any])?.string("type") == "text" } == true
        guard hasText, let timestamp, let seconds = AnalyticsTime.parse(timestamp) else { return }
        events.append(.conversation(uuid: uuid, halfHour: AnalyticsTime.halfHour(seconds)))
    }

    /// Unlike upstream, `entrypoint:"sdk-ts", userType:"external"` lines are kept: that skip avoids
    /// double counting against TokenTracker's OmO source, which this port does not read, and the
    /// same markers are written by every Agent SDK host (e.g. T3 Code).
    private mutating func countUsage(_ obj: [String: Any], timestamp: String?) {
        let message = obj.object("message")
        guard let usage = message?.object("usage") ?? obj.object("usage") else { return }
        let counts = Self.normalize(usage)
        guard let timestamp, !counts.isZero, let seconds = AnalyticsTime.parse(timestamp) else { return }
        let model = message?.trimmedString("model") ?? obj.trimmedString("model") ?? "unknown"
        events.append(.usage(key: Self.dedupKey(obj), model: model, halfHour: AnalyticsTime.halfHour(seconds), delta: counts))
    }

    /// `message.id:requestId`, else `message.id` (R:5282).
    static func dedupKey(_ obj: [String: Any]) -> String? {
        guard let id = obj.object("message")?.string("id"), !id.isEmpty else { return nil }
        guard let request = obj.string("requestId"), !request.isEmpty else { return id }
        return "\(id):\(request)"
    }

    /// `normalizeClaudeUsage` (R:5289): thinking tokens are split out of output; total is the raw sum.
    static func normalize(_ usage: [String: Any]) -> AnalyticsCounts {
        let output = usage.count("output_tokens")
        let details = usage.object("output_tokens_details")
        let thinkingKey = details?["thinking_tokens"] == nil || details?["thinking_tokens"] is NSNull ? "reasoning_tokens" : "thinking_tokens"
        let reasoning = min(output, details?.count(thinkingKey) ?? 0)
        var counts = AnalyticsCounts()
        counts.input = usage.count("input_tokens")
        counts.cached = usage.count("cache_read_input_tokens")
        counts.cacheCreation = usage.count("cache_creation_input_tokens")
        counts.output = output - reasoning
        counts.reasoning = reasoning
        counts.total = counts.input + output + counts.cacheCreation + counts.cached
        return counts
    }
}
