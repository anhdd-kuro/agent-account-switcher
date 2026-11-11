import Foundation

struct AnalyticsRates: Equatable {
    var input = 0.0
    var output = 0.0
    var cacheRead = 0.0
    var cacheWrite = 0.0
    var priorityMultiplier = 0.0
    var ultrafastMultiplier = 0.0

    init(_ json: [String: Any]) {
        input = (json["input"] as? NSNumber)?.doubleValue ?? 0
        output = (json["output"] as? NSNumber)?.doubleValue ?? 0
        cacheRead = (json["cache_read"] as? NSNumber)?.doubleValue ?? 0
        cacheWrite = (json["cache_write"] as? NSNumber)?.doubleValue ?? 0
        priorityMultiplier = (json["priority_multiplier"] as? NSNumber)?.doubleValue ?? 0
        ultrafastMultiplier = (json["ultrafast_multiplier"] as? NSNumber)?.doubleValue ?? 0
    }
}

/// Port of TokenTracker's pricing matcher and `computeRowCost` (spec §6), USD only.
final class AnalyticsPricing {
    private let exact: [String: AnalyticsRates]
    private let fuzzy: [(match: String, ref: String)]
    private let litellm: [String: AnalyticsRates]
    private let litellmByLength: [(key: String, lower: String)]
    private var cache: [String: AnalyticsRates?] = [:]
    private let lock = NSLock()

    static let shared = AnalyticsPricing.load()

    static func load() -> AnalyticsPricing {
        let repoCopy = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources/analytics-pricing.json")
        let candidates = [Bundle.main.url(forResource: "analytics-pricing", withExtension: "json"), repoCopy]
        for case let url? in candidates {
            if let data = try? Data(contentsOf: url), let pricing = try? AnalyticsPricing(data: data) { return pricing }
        }
        return AnalyticsPricing(exact: [:], fuzzy: [], litellm: [])
    }

    convenience init(data: Data) throws {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw CocoaError(.coderReadCorrupt) }
        let exact = (json["exact"] as? [String: [String: Any]] ?? [:]).mapValues(AnalyticsRates.init)
        let fuzzy = (json["fuzzy"] as? [[String: String]] ?? []).compactMap { entry -> (String, String)? in
            guard let match = entry["match"], let ref = entry["ref"] else { return nil }
            return (match, ref)
        }
        let litellm = (json["litellm"] as? [[Any]] ?? []).compactMap { pair -> (String, AnalyticsRates)? in
            guard pair.count == 2, let key = pair[0] as? String, let rates = pair[1] as? [String: Any] else { return nil }
            return (key, AnalyticsRates(rates))
        }
        self.init(exact: exact, fuzzy: fuzzy, litellm: litellm)
    }

    private init(exact: [String: AnalyticsRates], fuzzy: [(String, String)], litellm: [(String, AnalyticsRates)]) {
        self.exact = exact
        self.fuzzy = fuzzy.map { (match: $0.0, ref: $0.1) }
        self.litellm = Dictionary(litellm, uniquingKeysWith: { first, _ in first })
        let ordered = litellm.enumerated().map { (index: $0.offset, key: $0.element.0) }
        litellmByLength = ordered
            .sorted { $0.key.count != $1.key.count ? $0.key.count > $1.key.count : $0.index < $1.index }
            .map { (key: $0.key, lower: $0.key.lowercased()) }
    }

    /// nil means unpriced (status "unpriced" upstream); the cost then counts as 0 and marks partial.
    func rates(model: String, source: AnalyticsSource) -> AnalyticsRates? {
        let cacheKey = "\(source.rawValue)\u{0}\(model)"
        lock.lock()
        defer { lock.unlock() }
        if let cached = cache[cacheKey] { return cached }
        let result = lookup(model, source: source)
        cache[cacheKey] = .some(result)
        return result
    }

    private func lookup(_ model: String, source: AnalyticsSource) -> AnalyticsRates? {
        guard !model.isEmpty else { return nil }
        let lookupModel = source == .claude ? Self.normalizeClaude(model) : model
        let lower = lookupModel.lowercased()
        let dotForm = Self.dotForm(lookupModel)
        if let hit = exact[lookupModel] ?? caseInsensitive(exact, dotForm) { return hit }
        if let hit = litellm[lookupModel] ?? caseInsensitive(litellm, dotForm) { return hit }
        if let hit = containedExact(dotForm) { return hit }
        for entry in fuzzy {
            let needle = entry.match.lowercased()
            guard let hit = exact[entry.ref] else { continue }
            if lower.contains(needle) || (!dotForm.isEmpty && dotForm.contains(needle)) { return hit }
        }
        let stripped = Self.stripReasoningSuffix(lookupModel)
        if stripped != lookupModel, let hit = litellm[stripped] { return hit }
        let suffix = "/" + lower
        let prefixed = litellm.keys.filter { $0.count > suffix.count && $0.lowercased().hasSuffix(suffix) }.min()
        if let key = prefixed { return litellm[key] }
        for entry in litellmByLength where lower.contains(entry.lower) || (!dotForm.isEmpty && dotForm.contains(entry.lower)) {
            return litellm[entry.key]
        }
        return nil
    }

    private func caseInsensitive(_ table: [String: AnalyticsRates], _ model: String) -> AnalyticsRates? {
        guard !model.isEmpty else { return nil }
        if let hit = table[model] { return hit }
        let lower = model.lowercased()
        return table.first { $0.key.lowercased() == lower }?.value
    }

    private func containedExact(_ model: String) -> AnalyticsRates? {
        guard !model.isEmpty else { return nil }
        let lower = model.lowercased()
        for key in exact.keys.sorted(by: { $0.count > $1.count }) {
            guard let range = lower.range(of: key.lowercased()) else { continue }
            if let next = lower[range.upperBound...].first, next == "." || next.isNumber { continue }
            return exact[key]
        }
        return nil
    }

    // MARK: Model normalization (matcher.js)

    static func normalizeClaude(_ model: String) -> String {
        let base = model.contains("/") ? String(model[model.index(after: model.lastIndex(of: "/")!)...]) : model
        var m = base.trimmingCharacters(in: .whitespacesAndNewlines)
        m = replace(m, #"\([^)]*\)"#, " ").lowercased()
        m = replace(m, "[^a-z0-9.]+", "-")
        m = replace(m, "^-+|-+$", "")
        m = replace(m, "-{2,}", "-")
        let dotted = #"^(claude-(?:sonnet|opus|haiku)-\d+)\.(\d+)"#
        if matches(m, #"^claude-(sonnet|opus|haiku)-\d+\.\d+"#) { return replace(m, dotted, "$1-$2") }
        if matches(m, #"^(sonnet|opus|haiku)-\d+[.-]\d+"#) {
            return replace(replace(m, "^(sonnet|opus|haiku)-", "claude-$1-"), dotted, "$1-$2")
        }
        if matches(m, #"^claude-(?:[4-9]|\d{2,})[.-]\d+-(?:sonnet|opus|haiku)"#) {
            return replace(m, #"^claude-(\d+)[.-](\d+)-(sonnet|opus|haiku)"#, "claude-$3-$1-$2")
        }
        return m
    }

    static func dotForm(_ model: String) -> String {
        let lower = model.lowercased()
        let restored = replace(lower, #"(\d+)-(\d+)"#, "$1.$2")
        return restored == lower ? "" : restored
    }

    static func stripReasoningSuffix(_ model: String) -> String {
        for suffix in ["-xhigh-fast", "-high-fast", "-medium-fast", "-low-fast", "-xhigh", "-high", "-medium", "-low", "-fast"] where model.hasSuffix(suffix) {
            return String(model.dropLast(suffix.count))
        }
        return model
    }

    private static func matches(_ text: String, _ pattern: String) -> Bool {
        text.range(of: pattern, options: .regularExpression) != nil
    }

    private static func replace(_ text: String, _ pattern: String, _ template: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        return regex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: template)
    }

    // MARK: Cost (pricing/index.js computeRowCost)

    func cost(source: AnalyticsSource, model: String, bucket: AnalyticsBucket) -> Double {
        guard let rates = rates(model: model, source: source) else { return 0 }
        let counts = bucket.counts
        func cost(_ subset: AnalyticsCounts) -> Double {
            let input = Double(min(max(0, subset.input), max(0, counts.input)))
            let output = Double(min(max(0, subset.output), max(0, counts.output)))
            let cached = Double(min(max(0, subset.cached), max(0, counts.cached)))
            let write = Double(min(max(0, subset.cacheCreation), max(0, counts.cacheCreation)))
            // Codex reasoning is already included in output; Claude reports it separately.
            let reasoning = source == .codex ? 0 : Double(min(max(0, subset.reasoning), max(0, counts.reasoning)))
            return (input * rates.input + output * rates.output + cached * rates.cacheRead
                    + write * rates.cacheWrite + reasoning * rates.output) / 1_000_000
        }
        return cost(counts) + max(0, rates.priorityMultiplier - 1) * cost(bucket.priority)
            + max(0, rates.ultrafastMultiplier - 1) * cost(bucket.ultrafast)
    }
}
