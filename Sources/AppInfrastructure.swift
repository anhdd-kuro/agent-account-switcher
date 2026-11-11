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
