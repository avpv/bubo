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
                        // Store full line to preserve TZID params for timezone-aware parsing
                        let fullEntry = trimmed
                        if let existing = properties["EXDATE_FULL"] {
                            properties["EXDATE_FULL"] = existing + "\n" + fullEntry
                        } else {
                            properties["EXDATE_FULL"] = fullEntry
                        }
                        // Also store raw values for backward compatibility
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

    /// Parse an iCalendar date string. Delegates to shared ICalDateParser.
    static func parseICalDate(
        _ dateStr: String,
        tzId: String? = nil,
        vtimezones: [String: TimeZone] = [:]
    ) -> Date? {
        ICalDateParser.parse(dateStr, tzId: tzId, vtimezones: vtimezones)
    }

    /// Resolve timezone identifier. Delegates to shared ICalDateParser.
    static func resolveTimeZone(_ identifier: String) -> TimeZone? {
        ICalDateParser.resolveTimezone(identifier)
    }

    // MARK: - EXDATE Handling

    private static func parseExDates(
        _ props: [String: String],
        vtimezones: [String: TimeZone]
    ) -> Set<Date> {
        var dates = Set<Date>()

        // Prefer full lines with TZID parameters
        if let fullLines = props["EXDATE_FULL"] {
            for line in fullLines.components(separatedBy: "\n") {
                // Extract TZID from line like "EXDATE;TZID=Europe/Moscow:20260316T100000,20260317T100000"
                var tzId: String?
                if let tzRange = line.range(of: "TZID=") {
                    let after = line[tzRange.upperBound...]
                    if let end = after.firstIndex(of: ":") ?? after.firstIndex(of: ";") {
                        tzId = String(after[..<end])
                    }
                }
                // Extract values after the last colon
                let parts = line.components(separatedBy: ":")
                guard let valuesStr = parts.last else { continue }
                for value in valuesStr.components(separatedBy: ",") {
                    if let date = parseICalDate(value.trimmingCharacters(in: .whitespaces), tzId: tzId, vtimezones: vtimezones) {
                        dates.insert(date)
                    }
                }
            }
        } else if let exdateStr = props["EXDATE"] {
            // Fallback: raw values without timezone
            for value in exdateStr.components(separatedBy: ",") {
                if let date = parseICalDate(value.trimmingCharacters(in: .whitespaces)) {
                    dates.insert(date)
                }
            }
        }

        return dates
    }

}
