import Foundation

// MARK: - Event Type

/// Distinguishes regular calendar events from Pomodoro sessions.
enum EventType: String, Codable, Hashable {
    case standard
    case pomodoro
}

struct CalendarEvent: Identifiable, Codable, Hashable {
    let id: String
    let title: String
    let startDate: Date
    let endDate: Date
    let location: String?
    let description: String?
    let calendarName: String?
    var customReminderMinutes: [Int]?
    var recurrenceRule: RecurrenceRule?
    /// Non-nil when this event is an expanded occurrence of a recurring series.
    var seriesId: String?
    /// The type of event — standard calendar event or Pomodoro session.
    var eventType: EventType

    // MARK: - Static formatters (avoid re-creation per call)

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "d MMMM, EEEE"
        return f
    }()

    // MARK: - Computed properties

    /// True for events created locally (not from Apple Calendar via EventKit).
    var isLocalEvent: Bool {
        !id.hasPrefix("apple_")
    }

    var isRecurring: Bool {
        recurrenceRule != nil || seriesId != nil
    }

    var isUpcoming: Bool {
        endDate > Date()
    }

    var timeUntilStart: TimeInterval {
        startDate.timeIntervalSinceNow
    }

    var minutesUntilStart: Int {
        Int(timeUntilStart / 60)
    }

    var formattedTime: String {
        Self.timeFormatter.string(from: startDate)
    }

    var formattedDate: String {
        Self.dateFormatter.string(from: startDate)
    }

    var formattedTimeRange: String {
        "\(Self.timeFormatter.string(from: startDate)) – \(Self.timeFormatter.string(from: endDate))"
    }
}
