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

    /// Human-readable summary
    var displayText: String {
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
                parts.append("on the \(DS.formatOrdinal(ordinal)) \(weekday.shortName)")
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
}

// MARK: - Frequency

enum RecurrenceFrequency: String, Codable, Hashable, CaseIterable {
    case minutely
    case daily
    case weekly
    case monthly
    case yearly

    var label: String {
        switch self {
        case .minutely: return "Minute"
        case .daily:    return "Day"
        case .weekly:   return "Week"
        case .monthly:  return "Month"
        case .yearly:   return "Year"
        }
    }

    var singularUnit: String {
        switch self {
        case .minutely: return "minute"
        case .daily:    return "day"
        case .weekly:   return "week"
        case .monthly:  return "month"
        case .yearly:   return "year"
        }
    }

    var pluralUnit: String {
        switch self {
        case .minutely: return "minutes"
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
