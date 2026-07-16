import Foundation

// MARK: - Recurrence Rule (RFC 5545 compatible)

public struct RecurrenceRule: Codable, Hashable, Sendable {
    public let frequency: RecurrenceFrequency
    public let interval: Int
    public let end: RecurrenceEnd
    public let weekdays: Set<Weekday>
    public let monthlyMode: MonthlyMode?
    /// Explicit flag: this rule was created via the Pomodoro picker.
    public let pomodoroMode: Bool
    /// Minutes of long break after all Pomodoro rounds (0 = no long break).
    public let pomodoroLongBreak: Int

    public init(
        frequency: RecurrenceFrequency,
        interval: Int = 1,
        end: RecurrenceEnd = .never,
        weekdays: Set<Weekday> = [],
        monthlyMode: MonthlyMode? = nil,
        pomodoroMode: Bool = false,
        pomodoroLongBreak: Int = 0
    ) {
        self.frequency = frequency
        self.interval = interval
        self.end = end
        self.weekdays = weekdays
        self.monthlyMode = monthlyMode
        self.pomodoroMode = pomodoroMode
        self.pomodoroLongBreak = pomodoroLongBreak
    }

    private enum CodingKeys: String, CodingKey {
        case frequency, interval, end, weekdays, monthlyMode
        case pomodoroMode, pomodoroLongBreak
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(frequency, forKey: .frequency)
        try container.encode(interval, forKey: .interval)
        try container.encode(end, forKey: .end)
        try container.encode(weekdays, forKey: .weekdays)
        try container.encodeIfPresent(monthlyMode, forKey: .monthlyMode)
        if pomodoroMode {
            try container.encode(pomodoroMode, forKey: .pomodoroMode)
        }
        if pomodoroLongBreak > 0 {
            try container.encode(pomodoroLongBreak, forKey: .pomodoroLongBreak)
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.frequency = try container.decode(RecurrenceFrequency.self, forKey: .frequency)
        self.interval = try container.decodeIfPresent(Int.self, forKey: .interval) ?? 1
        self.end = try container.decodeIfPresent(RecurrenceEnd.self, forKey: .end) ?? .never
        self.weekdays = try container.decodeIfPresent(Set<Weekday>.self, forKey: .weekdays) ?? []
        self.monthlyMode = try container.decodeIfPresent(MonthlyMode.self, forKey: .monthlyMode)
        self.pomodoroMode = try container.decodeIfPresent(Bool.self, forKey: .pomodoroMode) ?? false
        self.pomodoroLongBreak = try container.decodeIfPresent(Int.self, forKey: .pomodoroLongBreak) ?? 0
    }

    /// Whether this rule represents a Pomodoro Technique session.
    public var isPomodoro: Bool { pomodoroMode }

    /// Human-readable summary
    public var displayText: String {
        // Pomodoro-specific display
        if isPomodoro, case .afterCount(let rounds) = end {
            var text = "Pomodoro: \(rounds)\u{00A0}rounds, every \(interval)\u{00A0}min"
            if pomodoroLongBreak > 0 {
                text += ", then \(pomodoroLongBreak)\u{00A0}min break"
            }
            return text
        }

        var parts: [String] = []

        // Frequency + interval
        if interval == 1 {
            parts.append("Every \(frequency.singularUnit)")
        } else {
            parts.append("Every \(interval) \(frequency.pluralUnit)")
        }

        // Weekdays (for weekly)
        if frequency == .weekly && !weekdays.isEmpty {
            let weekdaySet = Set(weekdays.map(\.calendarWeekday))
            let weekdayNumbers = Set([2, 3, 4, 5, 6]) // Mon-Fri
            if weekdaySet == weekdayNumbers {
                parts = ["Every weekday"]
            } else {
                let sorted = weekdays.sorted { $0.sortOrder < $1.sortOrder }
                parts.append("on \(sorted.map(\.shortName).joined(separator: ", "))")
            }
        }

        // Monthly mode
        if frequency == .monthly, let mode = monthlyMode {
            switch mode {
            case .dayOfMonth(let day):
                parts.append("on the \(Self.formatOrdinal(day))")
            case .weekdayPosition(let ordinal, let weekday):
                if ordinal < 0 {
                    parts.append("on the last \(weekday.shortName)")
                } else {
                    parts.append("on the \(Self.formatOrdinal(ordinal)) \(weekday.shortName)")
                }
            }
        }

        // End condition
        switch end {
        case .never:
            break
        case .afterCount(let count):
            parts.append("\(count) times")
        case .untilDate(let date):
            parts.append("until \(Self.endDateFormatter.string(from: date))")
        }

        return parts.joined(separator: ", ")
    }

    /// Maximum expansion window per frequency type.
    public var expansionWindowDays: Int {
        switch frequency {
        case .minutely: return 7
        case .hourly:   return 7
        case .daily:    return 7
        case .weekly:   return 60
        case .monthly:  return 365
        case .yearly:   return 730
        }
    }

    private static let endDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        return f
    }()

    /// Locale-aware ordinal formatter (1 → "1st", 2 → "2nd"). Mirrors
    /// `DS.formatOrdinal` in the Presentation layer; inlined here so the
    /// pure-domain `displayText` doesn't have to depend on SwiftUI.
    private static let ordinalFormatter: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .ordinal
        return f
    }()

    private static func formatOrdinal(_ n: Int) -> String {
        ordinalFormatter.string(from: NSNumber(value: n)) ?? "\(n)"
    }

    // MARK: - RRULE String Parsing (RFC 5545)

    /// Parse an iCalendar RRULE string into a RecurrenceRule.
    /// Example: "FREQ=WEEKLY;INTERVAL=2;BYDAY=MO,WE,FR;COUNT=10"
    public static func fromRRULE(_ rruleString: String) -> RecurrenceRule? {
        var freq: RecurrenceFrequency?
        var interval = 1
        var end: RecurrenceEnd = .never
        var rawByDay: [String] = []
        var monthlyMode: MonthlyMode? = nil

        let parts = rruleString.components(separatedBy: ";")
        for part in parts {
            let kv = part.components(separatedBy: "=")
            guard kv.count == 2 else { continue }
            let key = kv[0]
            let value = kv[1]

            switch key {
            case "FREQ":
                freq = rruleFrequency(from: value)
            case "INTERVAL":
                interval = Int(value) ?? 1
            case "COUNT":
                if let count = Int(value) { end = .afterCount(count) }
            case "UNTIL":
                if let date = ICalDateParser.parse(value) { end = .untilDate(date) }
            case "BYDAY":
                rawByDay = value.components(separatedBy: ",")
            case "BYMONTHDAY":
                if let day = value.components(separatedBy: ",").first.flatMap({ Int($0) }) {
                    monthlyMode = .dayOfMonth(day)
                }
            default:
                break
            }
        }

        guard let frequency = freq else { return nil }

        // Interpret BYDAY based on frequency context
        var weekdays: Set<Weekday> = []
        var effectiveFrequency = frequency
        if frequency == .weekly {
            // Weekly: BYDAY=MO,WE,FR → plain weekday set
            weekdays = Set(rawByDay.compactMap { rruleWeekday(from: $0) })
        } else if frequency == .monthly && monthlyMode == nil && !rawByDay.isEmpty {
            // Monthly: BYDAY=2TU → weekday position (ordinal + weekday)
            for dayStr in rawByDay {
                let letters = dayStr.filter { $0.isLetter }
                let digits = dayStr.filter { $0.isNumber || $0 == "-" }
                if let ordinal = Int(digits), let wd = rruleWeekday(from: letters) {
                    monthlyMode = .weekdayPosition(ordinal: ordinal, weekday: wd)
                    break
                }
            }
            if monthlyMode == nil, interval == 1 {
                // RFC 5545: FREQ=MONTHLY;BYDAY=TU with no ordinal means
                // EVERY Tuesday of the month — with interval 1 that is
                // exactly the weekly rule on those weekdays, which our
                // model can represent. Silently dropping BYDAY (the old
                // behaviour) degraded the rule to "monthly on the start
                // date's day" — wrong weekday, wrong occurrence count.
                // interval > 1 has no exact mapping (every 2nd month's
                // Tuesdays ≠ biweekly Tuesdays) and keeps the old
                // fallback.
                let mapped = Set(rawByDay.compactMap { rruleWeekday(from: $0) })
                if !mapped.isEmpty {
                    effectiveFrequency = .weekly
                    weekdays = mapped
                }
            }
            // Don't populate weekdays for monthly — monthlyMode handles it
        }

        return RecurrenceRule(
            frequency: effectiveFrequency,
            interval: interval,
            end: end,
            weekdays: weekdays,
            monthlyMode: monthlyMode
        )
    }

    private static func rruleFrequency(from value: String) -> RecurrenceFrequency? {
        switch value {
        case "MINUTELY": return .minutely
        case "HOURLY":   return .hourly
        case "DAILY":    return .daily
        case "WEEKLY":   return .weekly
        case "MONTHLY":  return .monthly
        case "YEARLY":   return .yearly
        default:         return nil
        }
    }

    private static func rruleWeekday(from str: String) -> Weekday? {
        let clean = str.filter { $0.isLetter }
        switch clean {
        case "MO": return .monday
        case "TU": return .tuesday
        case "WE": return .wednesday
        case "TH": return .thursday
        case "FR": return .friday
        case "SA": return .saturday
        case "SU": return .sunday
        default:   return nil
        }
    }
}

// MARK: - Frequency

public enum RecurrenceFrequency: String, Codable, Hashable, CaseIterable, Sendable {
    case minutely
    case hourly
    case daily
    case weekly
    case monthly
    case yearly

    /// Frequencies appropriate for the calendar event UI picker.
    public static let userVisible: [RecurrenceFrequency] = [.minutely, .daily, .weekly, .monthly, .yearly]

    public var label: String {
        switch self {
        case .minutely: return "Minute"
        case .hourly:   return "Hour"
        case .daily:    return "Day"
        case .weekly:   return "Week"
        case .monthly:  return "Month"
        case .yearly:   return "Year"
        }
    }

    public var singularUnit: String {
        switch self {
        case .minutely: return "minute"
        case .hourly:   return "hour"
        case .daily:    return "day"
        case .weekly:   return "week"
        case .monthly:  return "month"
        case .yearly:   return "year"
        }
    }

    public var pluralUnit: String {
        switch self {
        case .minutely: return "minutes"
        case .hourly:   return "hours"
        case .daily:    return "days"
        case .weekly:   return "weeks"
        case .monthly:  return "months"
        case .yearly:   return "years"
        }
    }
}

// MARK: - End Condition

public enum RecurrenceEnd: Codable, Hashable, Sendable {
    case never
    case afterCount(Int)
    case untilDate(Date)
}

// MARK: - Monthly Mode

public enum MonthlyMode: Codable, Hashable, Sendable {
    /// Repeat on a specific day of the month (e.g. the 15th).
    case dayOfMonth(Int)
    /// Repeat on the Nth weekday of the month (e.g. the 2nd Tuesday).
    case weekdayPosition(ordinal: Int, weekday: Weekday)
}

// MARK: - Weekday

public enum Weekday: String, Codable, Hashable, CaseIterable, Sendable {
    case monday, tuesday, wednesday, thursday, friday, saturday, sunday

    public var shortName: String {
        switch self {
        case .monday:    return "Mon"
        case .tuesday:   return "Tue"
        case .wednesday: return "Wed"
        case .thursday:  return "Thu"
        case .friday:    return "Fri"
        case .saturday:  return "Sat"
        case .sunday:    return "Sun"
        }
    }

    public var fullName: String {
        switch self {
        case .monday:    return "Monday"
        case .tuesday:   return "Tuesday"
        case .wednesday: return "Wednesday"
        case .thursday:  return "Thursday"
        case .friday:    return "Friday"
        case .saturday:  return "Saturday"
        case .sunday:    return "Sunday"
        }
    }

    public var initial: String {
        String(shortName.prefix(2))
    }

    public var sortOrder: Int {
        switch self {
        case .monday: return 0
        case .tuesday: return 1
        case .wednesday: return 2
        case .thursday: return 3
        case .friday: return 4
        case .saturday: return 5
        case .sunday: return 6
        }
    }

    public var calendarWeekday: Int {
        switch self {
        case .sunday: return 1
        case .monday: return 2
        case .tuesday: return 3
        case .wednesday: return 4
        case .thursday: return 5
        case .friday: return 6
        case .saturday: return 7
        }
    }

    public static func from(calendarWeekday: Int) -> Weekday? {
        allCases.first { $0.calendarWeekday == calendarWeekday }
    }
}
