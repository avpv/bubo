import Foundation

/// Recurrence expansion engine for local events.
/// Handles all RFC 5545 frequency types.
enum RecurrenceExpander {

    /// Expand a recurring event into individual occurrences within a date window.
    /// - Parameters:
    ///   - event: The base recurring event (must have a `recurrenceRule`).
    ///   - windowEnd: Latest date to generate occurrences for.
    ///   - excludedIds: Occurrence IDs to skip (for local event exclusions).
    ///   - excludedDates: Dates to skip via same-day comparison (for iCal EXDATE support).
    /// - Returns: Array of expanded occurrences. Returns `[event]` if not recurring.
    static func expand(
        _ event: CalendarEvent,
        windowEnd: Date? = nil,
        excludedIds: Set<String> = [],
        excludedDates: Set<Date> = []
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

        // Safety limit scaled by frequency to prevent runaway expansion
        let hardLimit: Int = {
            switch rule.frequency {
            case .minutely: return 10_080  // 7 days × 24h × 60min
            case .hourly:   return 168     // 7 days × 24h
            case .daily:    return 365
            case .weekly:   return 520     // 10 years
            case .monthly:  return 120     // 10 years
            case .yearly:   return 50
            }
        }()
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

                let isDateExcluded = !excludedDates.isEmpty && excludedDates.contains { abs($0.timeIntervalSince(current)) < 1 }

                if !excludedIds.contains(occurrenceId) && !isDateExcluded {
                    let occurrence = CalendarEvent(
                        id: occurrenceId,
                        title: event.title,
                        startDate: current,
                        endDate: current.addingTimeInterval(duration),
                        location: event.location,
                        description: event.description,
                        calendarName: event.calendarName,
                        customReminderMinutes: event.customReminderMinutes,
                        recurrenceRule: event.recurrenceRule,
                        seriesId: event.id,
                        eventType: event.eventType
                    )
                    occurrences.append(occurrence)
                }
                emitted += 1
            }

            current = nextDate(after: current, rule: rule, calendar: calendar)
        }

        // Pomodoro long break: add a final "long break" event after the last work session
        if rule.isPomodoro && rule.pomodoroLongBreak > 0, let lastWork = occurrences.last {
            let longBreakStart = lastWork.endDate
            let longBreakEnd = longBreakStart.addingTimeInterval(TimeInterval(rule.pomodoroLongBreak * 60))
            let longBreakId = "\(event.id)_longbreak"

            if !excludedIds.contains(longBreakId) {
                let longBreakEvent = CalendarEvent(
                    id: longBreakId,
                    title: "\(event.title) — Long Break",
                    startDate: longBreakStart,
                    endDate: longBreakEnd,
                    location: nil,
                    description: nil,
                    calendarName: event.calendarName,
                    customReminderMinutes: [0],
                    recurrenceRule: event.recurrenceRule,
                    seriesId: event.id,
                    eventType: .pomodoro
                )
                occurrences.append(longBreakEvent)
            }
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
                guard currentWeekday == weekday.calendarWeekday else { return false }
                if ordinal > 0 {
                    return calendar.component(.weekdayOrdinal, from: date) == ordinal
                } else {
                    // Negative ordinal: -1 = last, -2 = second-to-last
                    // Count how many more of this weekday remain after this date in the month
                    let currentMonth = calendar.component(.month, from: date)
                    var remaining = 0
                    var check = date
                    while let next = calendar.date(byAdding: .day, value: 7, to: check),
                          calendar.component(.month, from: next) == currentMonth {
                        remaining += 1
                        check = next
                    }
                    // remaining == 0 means this is the last occurrence, == 1 means second-to-last, etc.
                    return remaining == abs(ordinal) - 1
                }
            }
        }

        return true
    }

    // MARK: - Date Advancement

    private static func nextDate(after date: Date, rule: RecurrenceRule, calendar: Calendar) -> Date {
        switch rule.frequency {
        case .minutely:
            return date.addingTimeInterval(TimeInterval(rule.interval * 60))

        case .hourly:
            return date.addingTimeInterval(TimeInterval(rule.interval * 3600))

        case .daily:
            return calendar.date(byAdding: .day, value: rule.interval, to: date) ?? date

        case .weekly:
            if rule.weekdays.isEmpty {
                return calendar.date(byAdding: .weekOfYear, value: rule.interval, to: date) ?? date
            }
            // Find next matching weekday in current week first
            var candidate = calendar.date(byAdding: .day, value: 1, to: date) ?? date
            let currentWeekOfYear = calendar.component(.weekOfYear, from: date)
            for _ in 0..<6 {
                let candidateWeek = calendar.component(.weekOfYear, from: candidate)
                if candidateWeek != currentWeekOfYear { break }
                let wd = calendar.component(.weekday, from: candidate)
                if rule.weekdays.contains(where: { $0.calendarWeekday == wd }) {
                    return candidate
                }
                candidate = calendar.date(byAdding: .day, value: 1, to: candidate) ?? candidate
            }
            // No more matching days this week — jump to next interval week, preserving time
            let advancedDate = calendar.date(byAdding: .weekOfYear, value: rule.interval, to: date) ?? date
            // Build week start explicitly: set weekday to calendar's firstWeekday and preserve time
            let timeComps = calendar.dateComponents([.hour, .minute, .second], from: date)
            var weekStartComps = calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: advancedDate)
            weekStartComps.weekday = calendar.firstWeekday
            weekStartComps.hour = timeComps.hour
            weekStartComps.minute = timeComps.minute
            weekStartComps.second = timeComps.second
            guard let weekStart = calendar.date(from: weekStartComps) else { return advancedDate }
            for dayOffset in 0..<7 {
                let day = calendar.date(byAdding: .day, value: dayOffset, to: weekStart) ?? weekStart
                let wd = calendar.component(.weekday, from: day)
                if rule.weekdays.contains(where: { $0.calendarWeekday == wd }) {
                    return day
                }
            }
            return advancedDate

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
            guard let next = calendar.date(byAdding: .month, value: interval, to: date) else { return date }
            var comps = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: next)
            let daysInMonth = calendar.range(of: .day, in: .month, for: next)?.count ?? 31
            comps.day = min(targetDay, daysInMonth)
            return calendar.date(from: comps) ?? next

        case .weekdayPosition(let ordinal, let weekday):
            guard let baseNext = calendar.date(byAdding: .month, value: interval, to: date) else { return date }
            let timeComps = calendar.dateComponents([.hour, .minute, .second], from: date)

            if ordinal > 0 {
                // Positive ordinal: Nth weekday of the month
                var comps = calendar.dateComponents([.year, .month], from: baseNext)
                comps.weekday = weekday.calendarWeekday
                comps.weekdayOrdinal = ordinal
                comps.hour = timeComps.hour
                comps.minute = timeComps.minute
                comps.second = timeComps.second
                return calendar.date(from: comps) ?? baseNext
            } else {
                // Negative ordinal: count from end of month (-1 = last, -2 = second-to-last)
                // Find last day of month via first-of-next-month minus 1 day
                var firstOfNextComps = calendar.dateComponents([.year, .month], from: baseNext)
                firstOfNextComps.month! += 1
                firstOfNextComps.day = 1
                guard let firstOfNext = calendar.date(from: firstOfNextComps),
                      let lastDay = calendar.date(byAdding: .day, value: -1, to: firstOfNext) else { return baseNext }

                var count = 0
                var candidate = lastDay
                for _ in 0..<35 {
                    if calendar.component(.weekday, from: candidate) == weekday.calendarWeekday {
                        count += 1
                        if count == abs(ordinal) {
                            var result = calendar.dateComponents([.year, .month, .day], from: candidate)
                            result.hour = timeComps.hour
                            result.minute = timeComps.minute
                            result.second = timeComps.second
                            return calendar.date(from: result) ?? baseNext
                        }
                    }
                    guard let prev = calendar.date(byAdding: .day, value: -1, to: candidate) else { break }
                    candidate = prev
                }
                return baseNext
            }
        }
    }
}
