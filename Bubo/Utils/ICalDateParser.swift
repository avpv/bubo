import Foundation

/// iCalendar date parsing utility.
/// Used by RecurrenceRule to parse UNTIL dates in RRULE strings.
enum ICalDateParser {

    /// Parse an iCalendar date string (e.g. "20260316T140000Z", "20260316T140000", "20260316").
    static func parse(_ dateStr: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")

        if dateStr.hasSuffix("Z") {
            formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
            formatter.timeZone = TimeZone(identifier: "UTC")
        } else if dateStr.count == 8 {
            formatter.dateFormat = "yyyyMMdd"
            formatter.timeZone = .current
        } else {
            formatter.dateFormat = "yyyyMMdd'T'HHmmss"
            formatter.timeZone = .current
        }

        return formatter.date(from: dateStr)
    }
}
