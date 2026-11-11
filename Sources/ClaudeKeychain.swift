import Foundation

/// Keychain access goes through /usr/bin/security so Claude Code, which reads its
/// credentials the same way, keeps access without prompts.
enum ClaudeKeychain {
    private static let security = "/usr/bin/security"

    static func read(_ service: String) -> String? {
        try? readStrict(service)
    }

    /// Like `read`, but only a missing item yields nil; any other failure throws.
    static func readStrict(_ service: String) throws -> String? {
        let result = ProcessRunner.run(security, ["find-generic-password", "-s", service, "-w"], environment: [:], timeout: 5)
        if result.status == 44 { return nil }
        guard result.status == 0 else { throw ClaudeError.message("Keychain read failed for \(service); nothing was changed.") }
        let value = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    static func accountAttribute(_ service: String) -> String? {
        let result = ProcessRunner.run(security, ["find-generic-password", "-s", service], environment: [:], timeout: 5)
        guard result.status == 0 else { return nil }
        for line in result.output.split(separator: "\n") where line.contains("\"acct\"<blob>=\"") {
            let parts = line.components(separatedBy: "\"acct\"<blob>=\"")
            if parts.count == 2, let end = parts[1].lastIndex(of: "\"") {
                return String(parts[1][..<end])
            }
        }
        return nil
    }

    @discardableResult
    static func delete(_ service: String) -> Bool {
        ProcessRunner.run(security, ["delete-generic-password", "-s", service], environment: [:], timeout: 5).status == 0
    }

    static func write(_ service: String, account: String, secret: String) throws {
        guard !service.contains("\""), !account.contains("\"") else {
            throw ClaudeError.message("Invalid Keychain item name")
        }
        if let existing = accountAttribute(service), existing != account {
            var deletions = 0
            while delete(service), deletions < 10 { deletions += 1 }
        }
        let hex = Data(secret.utf8).map { String(format: "%02x", $0) }.joined()
        let command = "add-generic-password -U -a \"\(account)\" -s \"\(service)\" -X \"\(hex)\"\n"
        // Same approach as Claude Code: stdin keeps the secret out of the process list,
        // but `security -i` truncates long lines, so large payloads go through argv.
        let result = command.utf8.count <= 4000
            ? ProcessRunner.run(security, ["-i"], environment: [:], input: Data(command.utf8), timeout: 5)
            : ProcessRunner.run(security, ["add-generic-password", "-U", "-a", account, "-s", service, "-X", hex], environment: [:], timeout: 5)
        guard result.status == 0, read(service) == secret else {
            throw ClaudeError.message("Keychain write failed. Check Keychain access for this app.")
        }
    }
}
