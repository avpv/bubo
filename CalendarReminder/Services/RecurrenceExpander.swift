import Foundation

/// Shared recurrence expansion engine used by both ReminderService (local events)
/// and ICalParser (synced events). Handles all RFC 5545 frequency types.
enum RecurrenceExpander {

    /// Expand a recurring event into individual occurrences within a date window.
    /// - Parameters:
    ///   - event: The base recurring event (must have a `recurrenceRule`).
    ///   - windowEnd: Latest date to generate occurrences for.
    ///   - excludedIds: Occurrence IDs to skip (EXDATE equivalent for local events).
    /// - Returns: Array of expanded occurrences. Returns `[event]` if not recurring.
    static func expand(
        _ event: CalendarEvent,
        windowEnd: Date? = nil,
        excludedIds: Set<String> = []
    ) -> [CalendarEvent] {
        guard let rule = event.recurrenceRule else { return [event] }

        let calendar = Calendar.current
        let duration = event.endDate.timeIntervalSince(event.startDate)
        let end = windowEnd ?? (calendar.date(byAdding: .day, value: rule.expansionWindowDays, to: Date()) ?? Date())

        var occurrences: [CalendarEvent] = []
        var current = event.startDate
        var emitted = 0
        let maxCount: Int? = { if case .afterCount(let n) = rule.end { return n } else { return nil } }()
        let untilDate: Date? = { if case .untilDate(let d) = rule.end { return d } else { return nil } }()

        // Safety limit to prevent runaway expansion
        let hardLimit = 500
        var iterations = 0

        while current <= end && iterations < hardLimit {
            iterations += 1

            if let until = untilDate, current > until { break }
            if let max = maxCount, emitted >= max { break }

            let shouldInclude = matchesRule(date: current, rule: rule, calendar: calendar)

            if shouldInclude && current >= event.startDate {
                let occurrenceId = emitted == 0
                    ? event.id
                    : "\(event.id)_r\(Int(current.timeIntervalSince1970))"

                if !excludedIds.contains(occurrenceId) {
                    let occurrence = CalendarEvent(
                        id: occurrenceId,
                        title: event.title,
                        startDate: current,
                        endDate: current.addingTimeInterval(duration),
                        location: event.location,
                        description: event.description,
                        calendarName: event.calendarName,
                        customReminderMinutes: event.customReminderMinutes,
                        recurrenceRule: emitted == 0 ? event.recurrenceRule : nil,
                        seriesId: event.id
                    )
                    occurrences.append(occurrence)
                }
                emitted += 1
            }

            current = nextDate(after: current, rule: rule, calendar: calendar)
        }

        return occurrences.isEmpty ? [event] : occurrences
    }

    // MARK: - Rule Matching

    private static func matchesRule(date: Date, rule: RecurrenceRule, calendar: Calendar) -> Bool {
        // Weekly with specific weekdays
        if rule.frequency == .weekly && !rule.weekdays.isEmpty {
            let weekday = calendar.component(.weekday, from: date)
            return rule.weekdays.contains { $0.calendarWeekday == weekday }
        }

        // Monthly with specific mode
        if rule.frequency == .monthly, let mode = rule.monthlyMode {
            switch mode {
            case .dayOfMonth(let targetDay):
                let day = calendar.component(.day, from: date)
                let daysInMonth = calendar.range(of: .day, in: .month, for: date)?.count ?? 31
                return day == min(targetDay, daysInMonth)
            case .weekdayPosition(let ordinal, let weekday):
                let currentWeekday = calendar.component(.weekday, from: date)
                let currentOrdinal = calendar.component(.weekdayOrdinal, from: date)
                return currentWeekday == weekday.calendarWeekday && currentOrdinal == ordinal
            }
        }

        return true
    }

    // MARK: - Date Advancement

    private static func nextDate(after date: Date, rule: RecurrenceRule, calendar: Calendar) -> Date {
        switch rule.frequency {
        case .minutely:
            return date.addingTimeInterval(TimeInterval(rule.interval * 60))

        case .daily:
            return calendar.date(byAdding: .day, value: rule.interval, to: date) ?? date

        case .weekly:
            if rule.weekdays.isEmpty {
                return calendar.date(byAdding: .weekOfYear, value: rule.interval, to: date) ?? date
            }
            // Advance day-by-day; skip weeks when crossing a week boundary for interval > 1
            var next = calendar.date(byAdding: .day, value: 1, to: date) ?? date
            if rule.interval > 1 {
                let startWeek = calendar.component(.weekOfYear, from: date)
                let nextWeek = calendar.component(.weekOfYear, from: next)
                if nextWeek != startWeek {
                    next = calendar.date(byAdding: .weekOfYear, value: rule.interval - 1, to: next) ?? next
                }
            }
            return next

        case .monthly:
            if let mode = rule.monthlyMode {
                return nextMonthlyDate(after: date, mode: mode, interval: rule.interval, calendar: calendar)
            }
            return calendar.date(byAdding: .month, value: rule.interval, to: date) ?? date

        case .yearly:
            return calendar.date(byAdding: .year, value: rule.interval, to: date) ?? date
        }
    }

    private static func nextMonthlyDate(
        after date: Date,
        mode: MonthlyMode,
        interval: Int,
        calendar: Calendar
    ) -> Date {
        switch mode {
        case .dayOfMonth(let targetDay):
            // Advance by interval months, then set day (clamping to month length)
            guard var next = calendar.date(byAdding: .month, value: interval, to: date) else { return date }
            var comps = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: next)
            let daysInMonth = calendar.range(of: .day, in: .month, for: next)?.count ?? 31
            comps.day = min(targetDay, daysInMonth)
            return calendar.date(from: comps) ?? next

        case .weekdayPosition(let ordinal, let weekday):
            // Find the Nth weekday in the target month
            guard let baseNext = calendar.date(byAdding: .month, value: interval, to: date) else { return date }
            var comps = calendar.dateComponents([.year, .month, .hour, .minute, .second], from: baseNext)
            comps.weekday = weekday.calendarWeekday
            comps.weekdayOrdinal = ordinal
            return calendar.date(from: comps) ?? baseNext
        }
    }
}
