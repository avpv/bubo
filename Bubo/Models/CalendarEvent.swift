import Foundation
import SwiftUI

// MARK: - Event Color Tag

/// Predefined color choices for events.
enum EventColorTag: String, Codable, Hashable, CaseIterable {
    case red, orange, yellow, green, blue, purple, pink

    var color: Color {
        switch self {
        case .red: .red
        case .orange: .orange
        case .yellow: .yellow
        case .green: .green
        case .blue: .blue
        case .purple: .purple
        case .pink: .pink
        }
    }
}

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
    /// Optional user-chosen color for the event.
    var colorTag: EventColorTag?

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

    var formattedEndTime: String {
        Self.timeFormatter.string(from: endDate)
    }

    var formattedDate: String {
        Self.dateFormatter.string(from: startDate)
    }

    var formattedTimeRange: String {
        "\(Self.timeFormatter.string(from: startDate)) – \(Self.timeFormatter.string(from: endDate))"
    }

    // MARK: - Pomodoro Segment

    /// The type of segment within a Pomodoro session.
    enum PomodoroSegment {
        case work
        case shortBreak
        case longBreak

        var iconName: String {
            switch self {
            case .work: "brain.head.profile"
            case .shortBreak: "cup.and.saucer"
            case .longBreak: "moon.zzz"
            }
        }

        var label: String {
            switch self {
            case .work: "Work"
            case .shortBreak: "Break"
            case .longBreak: "Long break"
            }
        }
    }

    /// Determines the Pomodoro segment type based on event ID pattern.
    var pomodoroSegment: PomodoroSegment? {
        guard eventType == .pomodoro else { return nil }
        if id.contains("_longbreak") { return .longBreak }
        if id.contains("_break") { return .shortBreak }
        return .work
    }
}
