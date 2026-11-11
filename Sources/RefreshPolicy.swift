import Foundation

enum RefreshPolicy {
    static func shouldRefresh(lastRefresh: Date?, now: Date = Date(), ttl: TimeInterval, force: Bool) -> Bool {
        guard !force else { return true }
        guard let lastRefresh else { return true }
        return now.timeIntervalSince(lastRefresh) >= ttl
    }
}
