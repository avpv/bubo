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
                    if parsed.recurrenceRule != nil {
                        let exdates = parseExDates(properties, vtimezones: vtimezones)
                        let expanded = RecurrenceExpander.expand(parsed, windowEnd: expandTo, excludedDates: exdates)
                            .filter { $0.startDate >= expandFrom }
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
                    } else if baseName == "EXDATE" {
                        // Accumulate multiple EXDATE lines (RFC 5545 allows repeated properties)
                        if let existing = properties["EXDATE"] {
                            properties["EXDATE"] = existing + "," + value
                        } else {
                            properties["EXDATE"] = value
                        }
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

        let recurrenceRule = props["RRULE"].flatMap { RecurrenceRule.fromRRULE($0) }

        return CalendarEvent(
            id: uid,
            title: summary,
            startDate: startDate,
            endDate: endDate,
            location: props["LOCATION"],
            description: props["DESCRIPTION"],
            calendarName: calendarName,
            recurrenceRule: recurrenceRule
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

    // MARK: - EXDATE Handling

    private static func parseExDates(
        _ props: [String: String],
        vtimezones: [String: TimeZone]
    ) -> Set<Date> {
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

}
