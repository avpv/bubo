import Foundation

// MARK: - Recurrence Rule (RFC 5545 compatible)

struct RecurrenceRule: Codable, Hashable {
    let frequency: RecurrenceFrequency
    let interval: Int
    let end: RecurrenceEnd
    let weekdays: Set<Weekday>

    init(
        frequency: RecurrenceFrequency,
        interval: Int = 1,
        end: RecurrenceEnd = .never,
        weekdays: Set<Weekday> = []
    ) {
        self.frequency = frequency
        self.interval = interval
        self.end = end
        self.weekdays = weekdays
    }

    /// Human-readable summary like "Every day", "Every 2 weeks on Mon, Wed", "Every 30 min, 4 times"
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
            let sorted = weekdays.sorted { $0.sortOrder < $1.sortOrder }
            let dayNames = sorted.map(\.shortName)
            parts.append("on \(dayNames.joined(separator: ", "))")
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

    var label: String {
        switch self {
        case .never: return "Never"
        case .afterCount: return "After"
        case .untilDate: return "On date"
        }
    }
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
}
