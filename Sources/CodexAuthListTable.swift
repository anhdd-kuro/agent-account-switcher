import Foundation

// Older codex-auth versions lack --json. Only local identity columns are used;
// usage always comes from the app's authenticated endpoint.
enum CodexAuthListTable {
    static func parse(_ output: String) -> [CodexAccount] {
        output.split(whereSeparator: \.isNewline).compactMap { line in
            let tokens = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            let active = tokens.first == "*"
            let offset = active ? 1 : 0
            guard tokens.count >= offset + 3, !tokens[offset].isEmpty,
                  tokens[offset].allSatisfy(\.isNumber) else { return nil }
            return CodexAccount(selector: tokens[offset], email: tokens[offset + 1], plan: tokens[offset + 2],
                fiveHourUsage: "-", weeklyUsage: "-", fiveHourRemaining: nil, weeklyRemaining: nil,
                lastActivity: "-", isActive: active)
        }
    }
}
