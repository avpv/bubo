import Foundation
import SwiftUI

// MARK: - Event Color Tag

/// Predefined color choices for events.
enum EventColorTag: String, Codable, Hashable, CaseIterable, Sendable {
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

    /// User-configurable label for using color tags as context groups.
    /// Stored in UserDefaults so users can assign meaning to colors
    /// (e.g. red = "urgent", blue = "backend", green = "personal").
    var contextLabel: String? {
        get { Self.contextLabels[self] }
    }

    /// Load all color-to-context mappings from UserDefaults.
    static var contextLabels: [EventColorTag: String] {
        get {
            guard let data = UserDefaults.standard.data(forKey: "BuboColorContextLabels"),
                  let map = try? JSONDecoder().decode([String: String].self, from: data) else {
                return [:]
            }
            var result: [EventColorTag: String] = [:]
            for (key, value) in map {
                if let tag = EventColorTag(rawValue: key) {
                    result[tag] = value
                }
            }
            return result
        }
        set {
            let map = Dictionary(uniqueKeysWithValues: newValue.map { ($0.key.rawValue, $0.value) })
            if let data = try? JSONEncoder().encode(map) {
                UserDefaults.standard.set(data, forKey: "BuboColorContextLabels")
            }
        }
    }

    /// Set a context label for a specific color tag.
    static func setContextLabel(_ label: String?, for tag: EventColorTag) {
        var labels = contextLabels
        labels[tag] = label
        contextLabels = labels
    }

    /// Map a CGColor (e.g. from EKCalendar) to the nearest EventColorTag
    /// by comparing hue, saturation, and brightness in HSB space.
    static func from(cgColor: CGColor) -> EventColorTag? {
        #if canImport(AppKit)
        guard let nsColor = NSColor(cgColor: cgColor)?.usingColorSpace(.deviceRGB) else { return nil }
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        nsColor.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        #else
        return nil
        #endif

        // Achromatic colors (gray/white/black) — no meaningful hue
        guard s > 0.15 && b > 0.15 else { return nil }

        let hue = h * 360  // 0–360

        // Map hue ranges to tags
        switch hue {
        case 0..<15:     return .red
        case 15..<45:    return .orange
        case 45..<70:    return .yellow
        case 70..<165:   return .green
        case 165..<195:  return .blue   // cyan-ish → blue
        case 195..<260:  return .blue
        case 260..<290:  return .purple
        case 290..<340:  return .pink
        case 340...360:  return .red
        default:         return nil
        }
    }
}

// MARK: - Event Type

/// Distinguishes regular calendar events from Pomodoro sessions.
enum EventType: String, Codable, Hashable, Sendable {
    case standard
    case pomodoro
}

/// Tracks the lifecycle of a task.
enum TaskStatus: String, Codable, Hashable, Sendable, CaseIterable {
    case todo
    case inProgress
    case done
}

struct CalendarEvent: Identifiable, Codable, Hashable, Sendable {
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
    /// Optional project/category tag for optimizer context grouping.
    /// When set, takes priority over colorTag and calendarName for context resolution.
    var context: String?
    /// Optional story-point estimate for the task (e.g. 1, 2, 3, 5, 8, 13).
    var storyPoints: Int?

    /// Whether this item is a task (as opposed to a calendar event/meeting).
    /// Tasks support story points and are optimized differently.
    var isTask: Bool = false
    /// Task deadline — the date by which this task must be completed.
    var deadline: Date?
    /// Task status — tracks lifecycle from creation to completion.
    var taskStatus: TaskStatus = .todo
    /// When the task was marked as done.
    var completedAt: Date?

    /// Whether the optimizer is allowed to move this event to a different time slot.
    /// Defaults to `false` for events synced from external calendars (apple_ prefix).
    /// Set to `true` for user-created meetings that can be rescheduled.
    var isMovable: Bool = false

    // MARK: - Static formatters (avoid re-creation per call)

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.timeStyle = .short
        return f
    }()

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("dMMMEEEE")
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

    var duration: TimeInterval {
        endDate.timeIntervalSince(startDate)
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

    // MARK: - Meeting Link Detection

    /// Extracts a meeting link (Zoom, Google Meet, Microsoft Teams, Webex) from
    /// the event's description (notes) or location fields.
    var meetingLink: URL? {
        let patterns = [
            // Zoom
            "https?://[a-zA-Z0-9.-]*zoom\\.us/[^\\s<>\"']+",
            // Google Meet
            "https?://meet\\.google\\.com/[^\\s<>\"']+",
            // Microsoft Teams
            "https?://teams\\.microsoft\\.com/[^\\s<>\"']+",
            // Webex
            "https?://[a-zA-Z0-9.-]*webex\\.com/[^\\s<>\"']+",
        ]
        let combined = patterns.joined(separator: "|")
        guard let regex = try? NSRegularExpression(pattern: combined, options: .caseInsensitive) else {
            return nil
        }

        // Search location first (often contains the link directly), then description
        for text in [location, description].compactMap({ $0 }) where !text.isEmpty {
            let range = NSRange(text.startIndex..., in: text)
            if let match = regex.firstMatch(in: text, range: range),
               let matchRange = Range(match.range, in: text) {
                return URL(string: String(text[matchRange]))
            }
        }
        return nil
    }

    /// A short label for the meeting service, e.g. "Zoom", "Google Meet".
    var meetingServiceName: String? {
        guard let host = meetingLink?.host?.lowercased() else { return nil }
        if host.contains("zoom.us") { return "Zoom" }
        if host.contains("meet.google.com") { return "Google Meet" }
        if host.contains("teams.microsoft.com") { return "Teams" }
        if host.contains("webex.com") { return "Webex" }
        return "Meeting"
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
