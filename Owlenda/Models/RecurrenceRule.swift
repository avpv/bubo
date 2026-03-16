import Foundation

// MARK: - Recurrence Rule (RFC 5545 compatible)

struct RecurrenceRule: Codable, Hashable {
    let frequency: RecurrenceFrequency
    let interval: Int
    let end: RecurrenceEnd
    let weekdays: Set<Weekday>
    let monthlyMode: MonthlyMode?

    init(
        frequency: RecurrenceFrequency,
        interval: Int = 1,
        end: RecurrenceEnd = .never,
        weekdays: Set<Weekday> = [],
        monthlyMode: MonthlyMode? = nil
    ) {
        self.frequency = frequency
        self.interval = interval
        self.end = end
        self.weekdays = weekdays
        self.monthlyMode = monthlyMode
    }

    // MARK: - Codable migration from old format (intervalMinutes + repeatCount)

    private enum CodingKeys: String, CodingKey {
        case frequency, interval, end, weekdays, monthlyMode
        // Legacy keys
        case intervalMinutes, repeatCount
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(frequency, forKey: .frequency)
        try container.encode(interval, forKey: .interval)
        try container.encode(end, forKey: .end)
        try container.encode(weekdays, forKey: .weekdays)
        try container.encodeIfPresent(monthlyMode, forKey: .monthlyMode)
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        // Try new format first
        if let freq = try? container.decode(RecurrenceFrequency.self, forKey: .frequency) {
            self.frequency = freq
            self.interval = try container.decodeIfPresent(Int.self, forKey: .interval) ?? 1
            self.end = try container.decodeIfPresent(RecurrenceEnd.self, forKey: .end) ?? .never
            self.weekdays = try container.decodeIfPresent(Set<Weekday>.self, forKey: .weekdays) ?? []
            self.monthlyMode = try container.decodeIfPresent(MonthlyMode.self, forKey: .monthlyMode)
            return
        }

        // Legacy format: { intervalMinutes: 30, repeatCount: 4 }
        let intervalMinutes = try container.decode(Int.self, forKey: .intervalMinutes)
        let repeatCount = try container.decode(Int.self, forKey: .repeatCount)
        self.frequency = .minutely
        self.interval = intervalMinutes
        self.end = .afterCount(repeatCount)
        self.weekdays = []
        self.monthlyMode = nil
    }

    /// Whether this rule represents a Pomodoro Technique session.
    var isPomodoro: Bool {
        if case .afterCount = end {
            return frequency == .minutely
        }
        return false
    }

    /// Human-readable summary
    var displayText: String {
        // Pomodoro-specific display (interval = cycle, count = rounds)
        if isPomodoro, case .afterCount(let rounds) = end {
            return "Pomodoro: \(rounds) rounds, every \(interval) min"
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
                parts.append("on the \(DS.formatOrdinal(day))")
            case .weekdayPosition(let ordinal, let weekday):
                if ordinal < 0 {
                    parts.append("on the last \(weekday.shortName)")
                } else {
                    parts.append("on the \(DS.formatOrdinal(ordinal)) \(weekday.shortName)")
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
    var expansionWindowDays: Int {
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
        f.dateFormat = "d MMM yyyy"
        return f
    }()

    // MARK: - RRULE String Parsing (RFC 5545)

    /// Parse an iCalendar RRULE string into a RecurrenceRule.
    /// Example: "FREQ=WEEKLY;INTERVAL=2;BYDAY=MO,WE,FR;COUNT=10"
    static func fromRRULE(_ rruleString: String) -> RecurrenceRule? {
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
            // Don't populate weekdays for monthly — monthlyMode handles it
        }

        return RecurrenceRule(
            frequency: frequency,
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

enum RecurrenceFrequency: String, Codable, Hashable, CaseIterable {
    case minutely
    case hourly
    case daily
    case weekly
    case monthly
    case yearly

    /// Frequencies appropriate for the calendar event UI picker.
    /// Minutely is used internally for Pomodoro but not shown as a raw frequency.
    static let userVisible: [RecurrenceFrequency] = [.daily, .weekly, .monthly, .yearly]

    var label: String {
        switch self {
        case .minutely: return "Minute"
        case .hourly:   return "Hour"
        case .daily:    return "Day"
        case .weekly:   return "Week"
        case .monthly:  return "Month"
        case .yearly:   return "Year"
        }
    }

    var singularUnit: String {
        switch self {
        case .minutely: return "minute"
        case .hourly:   return "hour"
        case .daily:    return "day"
        case .weekly:   return "week"
        case .monthly:  return "month"
        case .yearly:   return "year"
        }
    }

    var pluralUnit: String {
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

enum RecurrenceEnd: Codable, Hashable {
    case never
    case afterCount(Int)
    case untilDate(Date)
}

// MARK: - Monthly Mode

enum MonthlyMode: Codable, Hashable {
    /// Repeat on a specific day of the month (e.g. the 15th).
    case dayOfMonth(Int)
    /// Repeat on the Nth weekday of the month (e.g. the 2nd Tuesday).
    case weekdayPosition(ordinal: Int, weekday: Weekday)
}

// MARK: - Weekday

enum Weekday: String, Codable, Hashable, CaseIterable {
    case monday, tuesday, wednesday, thursday, friday, saturday, sunday

    var shortName: String {
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

    var fullName: String {
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

    var initial: String {
        String(shortName.prefix(2))
    }

    var sortOrder: Int {
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

    var calendarWeekday: Int {
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

    static func from(calendarWeekday: Int) -> Weekday? {
        allCases.first { $0.calendarWeekday == calendarWeekday }
    }
}
