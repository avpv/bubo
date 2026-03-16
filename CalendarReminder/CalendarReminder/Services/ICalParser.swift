import Foundation

/// Robust iCalendar (RFC 5545) parser with RRULE and timezone support
struct ICalParser {

    /// Parse iCal data into calendar events, expanding recurring events
    static func parseEvents(
        _ icalData: String,
        calendarName: String,
        expandFrom: Date,
        expandTo: Date
    ) -> [CalendarEvent] {
        // Unfold long lines per RFC 5545 (lines starting with space/tab are continuations)
        let unfolded = icalData
            .replacingOccurrences(of: "\r\n ", with: "")
            .replacingOccurrences(of: "\r\n\t", with: "")
            .replacingOccurrences(of: "\n ", with: "")
            .replacingOccurrences(of: "\n\t", with: "")

        let lines = unfolded.components(separatedBy: .newlines)

        var events: [CalendarEvent] = []
        var inEvent = false
        var properties: [String: String] = [:]
        var vtimezones: [String: TimeZone] = [:]

        // First pass: collect VTIMEZONE definitions
        var inTimezone = false
        var tzId = ""
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed == "BEGIN:VTIMEZONE" {
                inTimezone = true
            } else if trimmed == "END:VTIMEZONE" {
                inTimezone = false
            } else if inTimezone && trimmed.hasPrefix("TZID:") {
                tzId = String(trimmed.dropFirst(5))
                if let tz = resolveTimeZone(tzId) {
                    vtimezones[tzId] = tz
                }
            }
        }

        // Second pass: parse VEVENT blocks
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed == "BEGIN:VEVENT" {
                inEvent = true
                properties = [:]
            } else if trimmed == "END:VEVENT" {
                inEvent = false
                if let parsed = buildEvent(from: properties, vtimezones: vtimezones, calendarName: calendarName) {
                    let rruleStr = properties["RRULE"]
                    if let rruleStr = rruleStr {
                        let expanded = expandRecurrence(
                            baseEvent: parsed,
                            rrule: rruleStr,
                            from: expandFrom,
                            to: expandTo,
                            exdates: parseExDates(properties, vtimezones: vtimezones)
                        )
                        events.append(contentsOf: expanded)
                    } else if parsed.startDate >= expandFrom && parsed.startDate <= expandTo {
                        events.append(parsed)
                    }
                }
            } else if inEvent {
                // Parse property: NAME;PARAMS:VALUE or NAME:VALUE
                if let colonRange = trimmed.range(of: ":", options: .literal) {
                    let key = String(trimmed[..<colonRange.lowerBound])
                    let value = String(trimmed[colonRange.upperBound...])
                    // Store with full key (including params) for date parsing
                    let baseName = key.components(separatedBy: ";").first ?? key
                    if baseName == "DTSTART" || baseName == "DTEND" {
                        properties[key] = value
                        properties[baseName] = trimmed // full line for timezone extraction
                    } else {
                        properties[baseName] = value
                    }
                }
            }
        }

        return events
    }

    // MARK: - Build Event

    private static func buildEvent(
        from props: [String: String],
        vtimezones: [String: TimeZone],
        calendarName: String
    ) -> CalendarEvent? {
        guard let uid = props["UID"],
              let summary = props["SUMMARY"] else { return nil }

        let dtstart = parseDateProperty(props, key: "DTSTART", vtimezones: vtimezones)
        guard let startDate = dtstart else { return nil }

        let dtend = parseDateProperty(props, key: "DTEND", vtimezones: vtimezones)
        let endDate = dtend ?? startDate.addingTimeInterval(3600)

        return CalendarEvent(
            id: uid,
            title: summary,
            startDate: startDate,
            endDate: endDate,
            location: props["LOCATION"],
            description: props["DESCRIPTION"],
            calendarName: calendarName
        )
    }

    // MARK: - Date Parsing

    private static func parseDateProperty(
        _ props: [String: String],
        key: String,
        vtimezones: [String: TimeZone]
    ) -> Date? {
        // Find the full property line to extract TZID
        guard let fullLine = props[key] else { return nil }

        var tzId: String?
        if fullLine.contains("TZID=") {
            if let range = fullLine.range(of: "TZID=") {
                let after = fullLine[range.upperBound...]
                if let end = after.firstIndex(of: ":") ?? after.firstIndex(of: ";") {
                    tzId = String(after[..<end])
                }
            }
        }

        // Extract the date value (after last colon)
        let parts = fullLine.components(separatedBy: ":")
        guard let dateStr = parts.last?.trimmingCharacters(in: .whitespaces), !dateStr.isEmpty else {
            return nil
        }

        return parseICalDate(dateStr, tzId: tzId, vtimezones: vtimezones)
    }

    static func parseICalDate(
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
            // All-day event: VALUE=DATE
            formatter.dateFormat = "yyyyMMdd"
            formatter.timeZone = resolveTimeZoneForParsing(tzId: tzId, vtimezones: vtimezones)
        } else {
            formatter.dateFormat = "yyyyMMdd'T'HHmmss"
            formatter.timeZone = resolveTimeZoneForParsing(tzId: tzId, vtimezones: vtimezones)
        }

        return formatter.date(from: dateStr)
    }

    private static func resolveTimeZoneForParsing(
        tzId: String?,
        vtimezones: [String: TimeZone]
    ) -> TimeZone {
        if let tzId = tzId {
            return vtimezones[tzId] ?? resolveTimeZone(tzId) ?? .current
        }
        return .current
    }

    /// Resolve timezone identifier, handling common Yandex/Outlook variations
    static func resolveTimeZone(_ identifier: String) -> TimeZone? {
        // Direct match
        if let tz = TimeZone(identifier: identifier) { return tz }

        // Common aliases
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

        // Try removing spaces and common suffixes
        let cleaned = identifier
            .replacingOccurrences(of: " Standard Time", with: "")
            .replacingOccurrences(of: " ", with: "_")

        return TimeZone(identifier: cleaned)
    }

    // MARK: - RRULE Expansion

    private static func expandRecurrence(
        baseEvent: CalendarEvent,
        rrule: String,
        from: Date,
        to: Date,
        exdates: Set<Date>
    ) -> [CalendarEvent] {
        let rule = parseRRule(rrule)
        let calendar = Calendar.current
        let duration = baseEvent.endDate.timeIntervalSince(baseEvent.startDate)

        var occurrences: [CalendarEvent] = []
        var currentDate = baseEvent.startDate
        var count = 0
        let maxCount = rule.count ?? 365 // safety limit

        while currentDate <= to && count < maxCount {
            if currentDate >= from && !isExcluded(currentDate, from: exdates) {
                let occurrence = CalendarEvent(
                    id: "\(baseEvent.id)_\(currentDate.timeIntervalSince1970)",
                    title: baseEvent.title,
                    startDate: currentDate,
                    endDate: currentDate.addingTimeInterval(duration),
                    location: baseEvent.location,
                    description: baseEvent.description,
                    calendarName: baseEvent.calendarName
                )
                occurrences.append(occurrence)
            }

            // Advance to next occurrence
            guard let nextDate = nextOccurrence(after: currentDate, rule: rule, calendar: calendar) else {
                break
            }

            if let until = rule.until, nextDate > until {
                break
            }

            currentDate = nextDate
            count += 1
        }

        return occurrences
    }

    private struct RRule {
        var freq: String = "DAILY"
        var interval: Int = 1
        var count: Int?
        var until: Date?
        var byDay: [String] = []   // MO, TU, WE, etc.
        var byMonth: [Int] = []
        var byMonthDay: [Int] = []
    }

    private static func parseRRule(_ rrule: String) -> RRule {
        var rule = RRule()
        let parts = rrule.components(separatedBy: ";")

        for part in parts {
            let kv = part.components(separatedBy: "=")
            guard kv.count == 2 else { continue }
            let key = kv[0]
            let value = kv[1]

            switch key {
            case "FREQ": rule.freq = value
            case "INTERVAL": rule.interval = Int(value) ?? 1
            case "COUNT": rule.count = Int(value)
            case "UNTIL": rule.until = parseICalDate(value)
            case "BYDAY": rule.byDay = value.components(separatedBy: ",")
            case "BYMONTH": rule.byMonth = value.components(separatedBy: ",").compactMap { Int($0) }
            case "BYMONTHDAY": rule.byMonthDay = value.components(separatedBy: ",").compactMap { Int($0) }
            default: break
            }
        }

        return rule
    }

    private static func nextOccurrence(
        after date: Date,
        rule: RRule,
        calendar: Calendar
    ) -> Date? {
        var component: Calendar.Component

        switch rule.freq {
        case "DAILY": component = .day
        case "WEEKLY": component = .weekOfYear
        case "MONTHLY": component = .month
        case "YEARLY": component = .year
        default: return nil
        }

        var nextDate = calendar.date(byAdding: component, value: rule.interval, to: date)

        // Handle BYDAY for weekly recurrence
        if rule.freq == "WEEKLY" && !rule.byDay.isEmpty {
            let targetDays = rule.byDay.compactMap { dayStringToWeekday($0) }
            if var candidate = nextDate {
                // Find next matching day
                for _ in 0..<7 {
                    let weekday = calendar.component(.weekday, from: candidate)
                    if targetDays.contains(weekday) {
                        return candidate
                    }
                    candidate = calendar.date(byAdding: .day, value: 1, to: candidate)!
                }
            }
        }

        return nextDate
    }

    private static func dayStringToWeekday(_ day: String) -> Int? {
        // Strip any leading number (e.g., "1MO" -> "MO")
        let clean = day.filter { $0.isLetter }
        switch clean {
        case "SU": return 1
        case "MO": return 2
        case "TU": return 3
        case "WE": return 4
        case "TH": return 5
        case "FR": return 6
        case "SA": return 7
        default: return nil
        }
    }

    private static func parseExDates(
        _ props: [String: String],
        vtimezones: [String: TimeZone]
    ) -> Set<Date> {
        // EXDATE can appear multiple times; we stored only the last one
        // In a full implementation, we'd collect all EXDATE properties
        guard let exdateStr = props["EXDATE"] else { return [] }

        var dates = Set<Date>()
        let values = exdateStr.components(separatedBy: ",")
        for value in values {
            if let date = parseICalDate(value.trimmingCharacters(in: .whitespaces)) {
                dates.insert(date)
            }
        }
        return dates
    }

    private static func isExcluded(_ date: Date, from exdates: Set<Date>) -> Bool {
        let calendar = Calendar.current
        for exdate in exdates {
            if calendar.isDate(date, inSameDayAs: exdate) {
                return true
            }
        }
        return false
    }
}
