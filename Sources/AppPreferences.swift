import Foundation

enum UsageDisplayMode: String {
    case fiveHour
    case weekly
    case both
    case off
}

enum ToolbarDisplayStyle: String {
    case detailed
    case compact
}

enum AutoSwitchMode: String {
    case off
    case ask
    case threshold
    case zero
}

enum AutoResumeMode: String {
    case off
    case ask
    case idle5
    case idle10
    case always
}

final class AppPreferences {
    private let labelsDefaultsKey = "accountDisplayLabels"
    private let remindersEnabledDefaultsKey = "usageReminderEnabled"
    private let reminderThresholdDefaultsKey = "usageReminderThreshold"
    private let autoSwitchEnabledDefaultsKey = "autoSwitchEnabled"
    private let autoSwitchThresholdDefaultsKey = "autoSwitchThreshold"
    private let autoSwitchModeDefaultsKey = "autoSwitchMode"
    private let autoResumeModeDefaultsKey = "autoResumeMode"
    private let autoResumePromptDefaultsKey = "autoResumePrompt"
    private let confirmBeforeSwitchingDefaultsKey = "confirmBeforeSwitching"
    private let refreshIntervalDefaultsKey = "refreshIntervalSeconds"
    private let idleRefreshIntervalDefaultsKey = "idleRefreshIntervalSeconds"
    private let protectFrontmostCodexDefaultsKey = "protectFrontmostCodex"
    private let toolbarDisplayStyleDefaultsKey = "toolbarDisplayStyle"
    private var labelsCache: [String: String]?
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    var remindersEnabled: Bool {
        get {
            if defaults.object(forKey: remindersEnabledDefaultsKey) == nil {
                return true
            }
            return defaults.bool(forKey: remindersEnabledDefaultsKey)
        }
        set {
            defaults.set(newValue, forKey: remindersEnabledDefaultsKey)
        }
    }
    var reminderThreshold: Int {
        get {
            let stored = defaults.integer(forKey: reminderThresholdDefaultsKey)
            return stored == 0 ? 10 : max(1, min(99, stored))
        }
        set {
            defaults.set(max(1, min(99, newValue)), forKey: reminderThresholdDefaultsKey)
        }
    }
    var autoSwitchEnabled: Bool {
        get {
            if defaults.object(forKey: autoSwitchModeDefaultsKey) != nil {
                return autoSwitchMode != .off
            }
            return defaults.bool(forKey: autoSwitchEnabledDefaultsKey)
        }
        set {
            defaults.set(newValue, forKey: autoSwitchEnabledDefaultsKey)
            autoSwitchMode = newValue ? .ask : .off
        }
    }
    var autoSwitchMode: AutoSwitchMode {
        get {
            if let rawValue = defaults.string(forKey: autoSwitchModeDefaultsKey),
               let mode = AutoSwitchMode(rawValue: rawValue) {
                return mode
            }
            return defaults.bool(forKey: autoSwitchEnabledDefaultsKey) ? .ask : .off
        }
        set {
            defaults.set(newValue.rawValue, forKey: autoSwitchModeDefaultsKey)
            defaults.set(newValue != .off, forKey: autoSwitchEnabledDefaultsKey)
        }
    }
    var autoSwitchThreshold: Int {
        get {
            let stored = defaults.integer(forKey: autoSwitchThresholdDefaultsKey)
            return stored == 0 ? 10 : max(1, min(99, stored))
        }
        set {
            defaults.set(max(1, min(99, newValue)), forKey: autoSwitchThresholdDefaultsKey)
        }
    }
    var autoResumeMode: AutoResumeMode {
        get {
            AutoResumeMode(rawValue: defaults.string(forKey: autoResumeModeDefaultsKey) ?? "") ?? .off
        }
        set {
            defaults.set(newValue.rawValue, forKey: autoResumeModeDefaultsKey)
        }
    }
    var autoResumePrompt: String {
        get {
            let stored = defaults.string(forKey: autoResumePromptDefaultsKey) ?? ""
            return stored.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "Carry on working from where you left off."
                : stored
        }
        set {
            let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            defaults.set(trimmed.isEmpty ? "Carry on working from where you left off." : trimmed, forKey: autoResumePromptDefaultsKey)
        }
    }
    var confirmBeforeSwitching: Bool {
        get {
            defaults.bool(forKey: confirmBeforeSwitchingDefaultsKey)
        }
        set {
            defaults.set(newValue, forKey: confirmBeforeSwitchingDefaultsKey)
        }
    }
    var activeRefreshInterval: Int {
        get {
            let stored = defaults.integer(forKey: refreshIntervalDefaultsKey)
            return stored == 0 ? 5 : normalizedRefreshInterval(stored)
        }
        set {
            defaults.set(normalizedRefreshInterval(newValue), forKey: refreshIntervalDefaultsKey)
        }
    }
    var idleRefreshInterval: Int {
        get {
            let stored = defaults.integer(forKey: idleRefreshIntervalDefaultsKey)
            return stored == 0 ? 30 : normalizedRefreshInterval(stored)
        }
        set {
            defaults.set(normalizedRefreshInterval(newValue), forKey: idleRefreshIntervalDefaultsKey)
        }
    }
    var protectFrontmostCodex: Bool {
        get {
            if defaults.object(forKey: protectFrontmostCodexDefaultsKey) == nil {
                return false
            }
            return defaults.bool(forKey: protectFrontmostCodexDefaultsKey)
        }
        set {
            defaults.set(newValue, forKey: protectFrontmostCodexDefaultsKey)
        }
    }
    var usageMode: UsageDisplayMode {
        get {
            UsageDisplayMode(rawValue: defaults.string(forKey: "usageDisplayMode") ?? "") ?? .fiveHour
        }
        set {
            defaults.set(newValue.rawValue, forKey: "usageDisplayMode")
        }
    }
    var claudeUsageMode: UsageDisplayMode {
        get {
            UsageDisplayMode(rawValue: defaults.string(forKey: "claudeUsageDisplayMode") ?? "") ?? .fiveHour
        }
        set {
            defaults.set(newValue.rawValue, forKey: "claudeUsageDisplayMode")
        }
    }
    var cursorLane: CursorMenuBarLane {
        get { CursorMenuBarLane(rawValue: defaults.string(forKey: "cursorMenuBarLane") ?? "") ?? .off }
        set { defaults.set(newValue.rawValue, forKey: "cursorMenuBarLane") }
    }
    var toolbarDisplayStyle: ToolbarDisplayStyle {
        get {
            ToolbarDisplayStyle(rawValue: defaults.string(forKey: toolbarDisplayStyleDefaultsKey) ?? "") ?? .detailed
        }
        set {
            defaults.set(newValue.rawValue, forKey: toolbarDisplayStyleDefaultsKey)
        }
    }
    private func normalizedRefreshInterval(_ seconds: Int) -> Int {
        [5, 15, 30, 60].contains(seconds) ? seconds : 5
    }

    func displayLabel(for account: CodexAccount) -> String {
        limitedLabel(customLabel(forEmail: account.email) ?? defaultLabel(forEmail: account.email))
    }

    func defaultLabel(forEmail email: String) -> String {
        if let first = email.first(where: { $0.isLetter || $0.isNumber }) {
            return String(first).uppercased()
        }
        return "A"
    }

    func limitedLabel(_ label: String) -> String {
        String(label.prefix(4))
    }

    func compactEmail(_ email: String, maximumLength: Int = 18) -> String {
        guard email.count > maximumLength else { return email }
        return String(email.prefix(maximumLength - 3)) + "..."
    }

    func customLabel(forEmail email: String) -> String? {
        accountLabels()[email]
    }

    func setCustomLabel(_ label: String, forEmail email: String) {
        var labels = accountLabels()
        labels[email] = label
        defaults.set(labels, forKey: labelsDefaultsKey)
        labelsCache = labels
    }

    func clearCustomLabel(forEmail email: String) {
        var labels = accountLabels()
        labels.removeValue(forKey: email)
        defaults.set(labels, forKey: labelsDefaultsKey)
        labelsCache = labels
    }

    func accountLabels() -> [String: String] {
        if let labelsCache { return labelsCache }
        let labels = defaults.dictionary(forKey: labelsDefaultsKey) as? [String: String] ?? [:]
        labelsCache = labels
        return labels
    }

}
