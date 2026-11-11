import Foundation

enum CodexUsageText {
    static func direct(_ window: UsageLimitWindowSnapshot, weekly: Bool) -> String {
        guard let resetAt = window.resetAt else {
            return "\(window.remainingPercent)%"
        }
        let formatter = weekly ? DateFormatter.directWeeklyUsage : DateFormatter.directFiveHourUsage
        return "\(window.remainingPercent)% (\(formatter.string(from: resetAt)))"
    }


    static func fiveHourReset(from usage: String) -> String {
        guard let inner = parenthesizedValue(from: usage) else { return "--:--" }
        return Self.firstClockText(in: inner) ?? inner
    }

    static func weeklyReset(from usage: String) -> String {
        guard let inner = parenthesizedValue(from: usage) else { return "--" }
        let time = Self.firstClockText(in: inner)
        let day = Self.firstWeekdayText(in: inner) ?? Self.inferredWeekdayText(from: inner)
        switch (time, day) {
        case let (time?, day?): return "\(day) \(time)"
        case let (time?, nil): return time
        case let (nil, day?): return day
        default: return inner
        }
    }

    private static func parenthesizedValue(from usage: String) -> String? {
        guard let open = usage.firstIndex(of: "("), let close = usage.firstIndex(of: ")"), open < close else { return nil }
        return String(usage[usage.index(after: open)..<close])
    }

    private static let clockRegex = try? NSRegularExpression(pattern: #"(?<!\d)(\d{1,2}):(\d{2})(?!\d)"#)

    private static func firstClockText(in text: String) -> String? {
        guard let regex = clockRegex,
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let hourRange = Range(match.range(at: 1), in: text),
              let minuteRange = Range(match.range(at: 2), in: text),
              let hour = Int(text[hourRange]) else {
            return nil
        }
        return String(format: "%02d:%@", hour, String(text[minuteRange]))
    }

    private static let weekdayNames: [String: String] = [
        "monday": "Mon", "mon": "Mon",
        "tuesday": "Tue", "tue": "Tue", "tues": "Tue",
        "wednesday": "Wed", "wed": "Wed",
        "thursday": "Thu", "thu": "Thu", "thur": "Thu", "thurs": "Thu",
        "friday": "Fri", "fri": "Fri",
        "saturday": "Sat", "sat": "Sat",
        "sunday": "Sun", "sun": "Sun"
    ]

    private static func firstWeekdayText(in text: String) -> String? {
        for token in text.split(whereSeparator: { !$0.isLetter }) {
            if let day = weekdayNames[token.lowercased()] { return day }
        }
        return nil
    }

    private static let inferenceFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        return formatter
    }()

    private static let inferenceFormats = [
        "HH:mm MMM d yyyy", "HH:mm MMMM d yyyy", "HH:mm d MMM yyyy", "HH:mm d MMMM yyyy",
        "MMM d HH:mm yyyy", "MMMM d HH:mm yyyy", "d MMM HH:mm yyyy", "d MMMM HH:mm yyyy",
        "yyyy HH:mm MMM d", "yyyy HH:mm MMMM d", "yyyy HH:mm d MMM", "yyyy HH:mm d MMMM",
        "yyyy MMM d HH:mm", "yyyy MMMM d HH:mm", "yyyy d MMM HH:mm", "yyyy d MMMM HH:mm"
    ]

    private static func inferredWeekdayText(from text: String) -> String? {
        let cleaned = text
            .replacingOccurrences(of: ",", with: " ")
            .replacingOccurrences(of: " on ", with: " ")
            .replacingOccurrences(of: "  ", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let year = Calendar.current.component(.year, from: Date())
        let formatter = inferenceFormatter
        for candidate in [cleaned, "\(cleaned) \(year)", "\(year) \(cleaned)"] {
            for format in inferenceFormats {
                formatter.dateFormat = format
                if let date = formatter.date(from: candidate) {
                    let symbols = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
                    return symbols[Calendar.current.component(.weekday, from: date) - 1]
                }
            }
        }
        return nil
    }
}
