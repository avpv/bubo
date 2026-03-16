import Foundation

/// Shared iCalendar date parsing and timezone resolution utility.
/// Extracted to avoid circular dependency between RecurrenceRule (Model) and ICalParser (Service).
enum ICalDateParser {

    /// Parse an iCalendar date string (e.g. "20260316T140000Z", "20260316T140000", "20260316").
    static func parse(
        _ dateStr: String,
        tzId: String? = nil,
        vtimezones: [String: TimeZone] = [:]
    ) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")

        if dateStr.hasSuffix("Z") {
            formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
            formatter.timeZone = TimeZone(identifier: "UTC")
        } else if dateStr.count == 8 {
            formatter.dateFormat = "yyyyMMdd"
            formatter.timeZone = resolveTimeZone(tzId: tzId, vtimezones: vtimezones)
        } else {
            formatter.dateFormat = "yyyyMMdd'T'HHmmss"
            formatter.timeZone = resolveTimeZone(tzId: tzId, vtimezones: vtimezones)
        }

        return formatter.date(from: dateStr)
    }

    /// Resolve timezone identifier, handling common Yandex/Outlook variations.
    static func resolveTimezone(_ identifier: String) -> TimeZone? {
        if let tz = TimeZone(identifier: identifier) { return tz }

        let aliases: [String: String] = [
            "Moscow Standard Time": "Europe/Moscow",
            "Russian Standard Time": "Europe/Moscow",
            "E. Europe Standard Time": "Europe/Minsk",
            "FLE Standard Time": "Europe/Kiev",
            "GTB Standard Time": "Europe/Bucharest",
            "Ekaterinburg Standard Time": "Asia/Yekaterinburg",
            "N. Central Asia Standard Time": "Asia/Novosibirsk",
            "North Asia Standard Time": "Asia/Krasnoyarsk",
            "North Asia East Standard Time": "Asia/Irkutsk",
            "Yakutsk Standard Time": "Asia/Yakutsk",
            "Vladivostok Standard Time": "Asia/Vladivostok",
            "W. Europe Standard Time": "Europe/Berlin",
            "Central European Standard Time": "Europe/Warsaw",
            "Romance Standard Time": "Europe/Paris",
            "US Eastern Standard Time": "America/New_York",
            "Pacific Standard Time": "America/Los_Angeles",
        ]

        if let mapped = aliases[identifier] {
            return TimeZone(identifier: mapped)
        }

        let cleaned = identifier
            .replacingOccurrences(of: " Standard Time", with: "")
            .replacingOccurrences(of: " ", with: "_")

        return TimeZone(identifier: cleaned)
    }

    private static func resolveTimeZone(
        tzId: String?,
        vtimezones: [String: TimeZone]
    ) -> TimeZone {
        guard let tzId = tzId else { return .current }
        return vtimezones[tzId] ?? resolveTimezone(tzId) ?? .current
    }
}
