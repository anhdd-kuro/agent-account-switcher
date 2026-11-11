import Foundation

struct HTTPPayload {
    let data: Data
    let statusCode: Int
    var retryAfter: String? = nil
}

/// Per-key cooldown after HTTP 429: doubles from 2 minutes up to 30, and never
/// retries earlier than the server's Retry-After.
struct RateLimitBackoff {
    static let initialDelay: TimeInterval = 120
    static let maximumDelay: TimeInterval = 1_800

    private var until: [String: Date] = [:]
    private var strikes: [String: Int] = [:]

    func retryAt(_ key: String, now: Date = Date()) -> Date? {
        guard let date = until[key], date > now else { return nil }
        return date
    }

    @discardableResult
    mutating func recordLimited(_ key: String, retryAfter: TimeInterval?, now: Date = Date()) -> Date {
        let count = (strikes[key] ?? 0) + 1
        strikes[key] = count
        let doubled = Self.initialDelay * pow(2, Double(min(count - 1, 10)))
        let delay = max(min(doubled, Self.maximumDelay), retryAfter ?? 0)
        let date = now.addingTimeInterval(delay)
        until[key] = date
        return date
    }

    mutating func recordSuccess(_ key: String) {
        until[key] = nil
        strikes[key] = nil
    }

    static func parseRetryAfter(_ value: String?, now: Date = Date()) -> TimeInterval? {
        guard let value = value?.trimmingCharacters(in: .whitespaces), !value.isEmpty else { return nil }
        if let seconds = TimeInterval(value), seconds >= 0 { return seconds }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        guard let date = formatter.date(from: value) else { return nil }
        return max(0, date.timeIntervalSince(now))
    }
}

enum HTTPClient {
    /// A dedicated ephemeral session: always-fresh responses, no token-bearing
    /// data written to the shared on-disk URL cache, and warm connection reuse.
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 30
        configuration.httpMaximumConnectionsPerHost = 4
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration)
    }()

    static func send(_ request: URLRequest, retries: Int) async throws -> HTTPPayload {
        var lastError: Error?
        let attempts = max(1, retries + 1)

        for attempt in 0..<attempts {
            do {
                let (data, response) = try await session.data(for: request)
                guard let httpResponse = response as? HTTPURLResponse else {
                    throw URLError(.badServerResponse)
                }
                if httpResponse.statusCode >= 500, attempt + 1 < attempts {
                    try await Task.sleep(nanoseconds: UInt64(250_000_000 * (attempt + 1)))
                    continue
                }
                return HTTPPayload(
                    data: data,
                    statusCode: httpResponse.statusCode,
                    retryAfter: httpResponse.value(forHTTPHeaderField: "Retry-After")
                )
            } catch {
                lastError = error
                guard attempt + 1 < attempts else { break }
                try await Task.sleep(nanoseconds: UInt64(250_000_000 * (attempt + 1)))
            }
        }

        throw lastError ?? URLError(.unknown)
    }
}
