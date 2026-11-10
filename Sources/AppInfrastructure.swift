import Darwin
import Foundation

struct CommandResult {
    let status: Int32
    let output: String
}

enum ProcessRunner {
    private final class DataBox: @unchecked Sendable {
        private let lock = NSLock()
        private var value = Data()

        func store(_ data: Data) {
            lock.lock()
            value = data
            lock.unlock()
        }

        func load() -> Data {
            lock.lock()
            defer { lock.unlock() }
            return value
        }
    }

    static func run(
        _ executable: String,
        _ arguments: [String],
        environment: [String: String],
        input: Data? = nil,
        timeout: TimeInterval = 15
    ) -> CommandResult {
        let process = Process()
        let outputPipe = Pipe()
        let inputPipe = input == nil ? nil : Pipe()
        let outputBox = DataBox()
        let outputGroup = DispatchGroup()
        let exited = DispatchSemaphore(value: 0)

        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = environment
        process.standardOutput = outputPipe
        process.standardError = outputPipe
        process.standardInput = inputPipe
        // Wake exactly when the process exits instead of polling every 20 ms.
        process.terminationHandler = { _ in exited.signal() }

        do {
            try process.run()
        } catch {
            return CommandResult(status: 127, output: error.localizedDescription)
        }

        outputGroup.enter()
        DispatchQueue.global(qos: .utility).async {
            outputBox.store(outputPipe.fileHandleForReading.readDataToEndOfFile())
            outputGroup.leave()
        }

        if let inputPipe, let input {
            inputPipe.fileHandleForWriting.write(input)
            inputPipe.fileHandleForWriting.closeFile()
        }

        let timedOut = exited.wait(timeout: .now() + max(0.1, timeout)) == .timedOut
        if timedOut {
            process.terminate()
            if exited.wait(timeout: .now() + 0.5) == .timedOut {
                Darwin.kill(process.processIdentifier, SIGKILL)
                _ = exited.wait(timeout: .now() + 1)
            }
        }

        process.waitUntilExit()
        _ = outputGroup.wait(timeout: .now() + 2)
        var output = String(data: outputBox.load(), encoding: .utf8) ?? ""
        if timedOut {
            if !output.isEmpty, !output.hasSuffix("\n") {
                output += "\n"
            }
            output += "Command timed out after \(Int(timeout.rounded())) seconds."
        }
        return CommandResult(status: timedOut ? 124 : process.terminationStatus, output: output)
    }
}

enum ResetRefreshPolicy {
    static func shouldRefresh(lastRefresh: Date?, now: Date = Date(), ttl: TimeInterval, force: Bool) -> Bool {
        guard !force else { return true }
        guard let lastRefresh else { return true }
        return now.timeIntervalSince(lastRefresh) >= ttl
    }
}

enum UsageRefreshPolicy {
    static func shouldRefresh(lastRefresh: Date?, now: Date = Date(), ttl: TimeInterval, force: Bool) -> Bool {
        guard !force else { return true }
        guard let lastRefresh else { return true }
        return now.timeIntervalSince(lastRefresh) >= ttl
    }
}

enum LastKnownGoodSnapshotPolicy {
    static func merged<Key: Hashable, Value>(
        current: [Key: Value],
        successful: [Key: Value],
        validKeys: Set<Key>
    ) -> [Key: Value] {
        var merged = current.filter { validKeys.contains($0.key) }
        for (key, value) in successful where validKeys.contains(key) {
            merged[key] = value
        }
        return merged
    }
}

enum ComputerUsePluginLocator {
    static func latestApp(in versionsRoot: URL, fileManager: FileManager = .default) -> URL? {
        guard let versionDirectories = try? fileManager.contentsOfDirectory(
            at: versionsRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }

        return versionDirectories
            .compactMap { directory -> (version: String, app: URL)? in
                let app = directory.appendingPathComponent("Codex Computer Use.app", isDirectory: true)
                guard fileManager.fileExists(atPath: app.path) else { return nil }
                return (directory.lastPathComponent, app)
            }
            .sorted { left, right in
                left.version.compare(right.version, options: .numeric) == .orderedDescending
            }
            .first?.app
    }

    static func latestApp(homeDirectory: String, fileManager: FileManager = .default) -> URL? {
        latestApp(
            in: URL(fileURLWithPath: homeDirectory)
                .appendingPathComponent(".codex/plugins/cache/openai-bundled/computer-use", isDirectory: true),
            fileManager: fileManager
        )
    }
}

enum AuthBackupPruner {
    @discardableResult
    static func prune(in directory: URL, keepingPerAccount keepCount: Int = 10, fileManager: FileManager = .default) -> Int {
        guard keepCount >= 0,
              let files = try? fileManager.contentsOfDirectory(
                  at: directory,
                  includingPropertiesForKeys: [.contentModificationDateKey],
                  options: [.skipsHiddenFiles]
              ) else {
            return 0
        }

        let backups = files.filter { $0.lastPathComponent.contains(".auth.json.bak.") }
        let grouped = Dictionary(grouping: backups) { url in
            url.lastPathComponent.components(separatedBy: ".bak.").first ?? url.lastPathComponent
        }

        var removed = 0
        for group in grouped.values {
            let ordered = group.sorted { left, right in
                let leftStamp = Int(left.lastPathComponent.components(separatedBy: ".bak.").last ?? "") ?? 0
                let rightStamp = Int(right.lastPathComponent.components(separatedBy: ".bak.").last ?? "") ?? 0
                if leftStamp != rightStamp { return leftStamp > rightStamp }
                let leftDate = (try? left.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let rightDate = (try? right.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return leftDate > rightDate
            }

            for staleURL in ordered.dropFirst(keepCount) {
                do {
                    try fileManager.removeItem(at: staleURL)
                    removed += 1
                } catch {
                    continue
                }
            }
        }
        return removed
    }
}

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

    /// The time the key may be fetched again, or nil when it is free now.
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

    /// Reads a Retry-After value given in seconds or as an HTTP date.
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

enum CodexHTTPClient {
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
