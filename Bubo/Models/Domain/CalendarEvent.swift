import Foundation

// MARK: - Event Color Tag

/// Predefined color choices for events.
///
/// The SwiftUI `Color` mapping lives in
/// `Views/Components/EventColorTag+Color.swift` so this type stays pure
/// domain — no UI framework import.
enum EventColorTag: String, Codable, Hashable, CaseIterable, Sendable {
    case red, orange, yellow, green, blue, purple, pink

    /// UserDefaults key for the color-to-context-label map. Referenced
    /// from `CloudSyncService.syncedKeys` so a single rename keeps the
    /// storage and cloud-sync lists in step.
    static let contextLabelsDefaultsKey = "BuboColorContextLabels"

    /// User-configurable label for using color tags as context groups.
    /// Stored in UserDefaults so users can assign meaning to colors
    /// (e.g. red = "urgent", blue = "backend", green = "personal").
    var contextLabel: String? {
        get { Self.contextLabels[self] }
    }

    /// Load all color-to-context mappings from UserDefaults.
    static var contextLabels: [EventColorTag: String] {
        get {
            guard let data = UserDefaults.standard.data(forKey: contextLabelsDefaultsKey),
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
                UserDefaults.standard.set(data, forKey: contextLabelsDefaultsKey)
                CloudSyncService.shared.push(contextLabelsDefaultsKey)
            }
        }
    }

    /// Set a context label for a specific color tag.
    static func setContextLabel(_ label: String?, for tag: EventColorTag) {
        var labels = contextLabels
        labels[tag] = label
        contextLabels = labels
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
    var id: String
    /// Mutable so inline-rename in `EventRowView` can mutate a copy and
    /// hand it to `ReminderService.updateLocalEvent`. Was `let` before
    /// the inline-edit feature; nothing in the codebase depends on the
    /// title being immutable.
    var title: String
    var startDate: Date
    var endDate: Date
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
    /// IDs of tasks that must be completed before this one can start.
    var dependsOn: [String] = []

    /// Whether the optimizer is allowed to move this event to a different time slot.
    /// Defaults to `false` for events synced from external calendars (apple_ prefix).
    /// Set to `true` for user-created meetings that can be rescheduled.
    var isMovable: Bool = false

    /// Resolved pomodoro shape (work / break / rounds / long break) for
    /// pomodoro-type events. Populated by `OptimizerService.applyScenario`
    /// from `PomodoroConfigResolver.resolveShape` using the event's actual
    /// start hour. `TimerScreenView` reads it to drive the rounded timer,
    /// and `PomodoroHistoryService` records it on completion for future
    /// resolver runs. `nil` for standard events and legacy pomodoros
    /// created before this field existed.
    var pomodoroConfig: PomodoroConfig? = nil

    /// Ordered backlog tasks packed into this pomodoro. Empty for
    /// single-task sessions created by `.pomodoroSession`; populated by
    /// `.focusBurst` so the timer can show `taskSequence[round - 1].title`
    /// at the start of each work round and mark every task scheduled
    /// against this event. Stored as a value array (not ids) so
    /// deletion / renaming of a backlog row can't desync what the timer
    /// shows mid-session.
    var pomodoroTaskSequence: [TaskSequenceEntry] = []

    /// Entry in `pomodoroTaskSequence` — a snapshot of the backlog task
    /// at scheduling time. Snapshotting the title keeps the display
    /// stable even if the user renames the task during the session.
    struct TaskSequenceEntry: Codable, Hashable, Sendable {
        let taskId: String
        let title: String
    }

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
        "\(Self.timeFormatter.string(from: startDate))–\(Self.timeFormatter.string(from: endDate))"
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

    /// Stable identifier shared by every event in the same pomodoro
    /// session — the leading portion of `id` before the `_occ{N}` /
    /// `_break{N}` / `_longbreak` segment suffix. Used by the timeline
    /// rendering to group adjacent segments into one container with
    /// shared brackets — the visual «one structured block» that the
    /// `pomodoroSession` intent represents in the optimizer's input.
    /// Returns nil for non-pomodoro events. Birman: «rules are
    /// objects on the screen» — the session is now a visible group, not
    /// just a per-segment icon.
    var pomodoroSessionBaseId: String? {
        guard eventType == .pomodoro else { return nil }
        // Strip every recognised segment suffix; whichever matches
        // first produces the shared base. Order matters: `_longbreak`
        // before `_break` so the longer suffix isn't truncated to
        // «long».
        for suffix in ["_longbreak", "_break", "_occ"] {
            if let range = id.range(of: #"\#(suffix)\d*$"#, options: .regularExpression) {
                return String(id[..<range.lowerBound])
            }
        }
        // Standalone pomodoro events without a numbered suffix — the
        // whole id is the base. Rare but supported (single-segment
        // sessions).
        return id
    }

    /// The 1-based round number within a Pomodoro session, extracted from the event ID suffix.
    /// Work events use `_occ{N}` (0-based), breaks use `_break{N}` (0-based).
    var pomodoroRoundNumber: Int? {
        guard eventType == .pomodoro else { return nil }
        if id.contains("_longbreak") { return nil } // long break is after all rounds
        // Extract trailing digit(s) from _occ{N} or _break{N}
        if let range = id.range(of: #"_(occ|break)(\d+)$"#, options: .regularExpression) {
            let suffix = id[range]
            if let digits = suffix.split(whereSeparator: { !$0.isNumber }).last,
               let index = Int(digits) {
                return index + 1 // convert 0-based to 1-based
            }
        }
        return 1 // standalone pomodoro = round 1
    }

    /// Total number of rounds in this Pomodoro session, from the recurrence rule.
    var pomodoroTotalRounds: Int? {
        guard eventType == .pomodoro, let rule = recurrenceRule, rule.pomodoroMode else { return nil }
        if case .afterCount(let count) = rule.end { return count }
        return nil
    }

    // MARK: - Inline Pomodoro Phase (pomodoroConfig-driven)
    //
    // Phase model for single-event pomodoros created by the optimizer
    // (`pomodoroConfig != nil`). Separate from the id-suffix path above
    // which applies to recurrence-expanded pomodoros. Callers should
    // prefer this path when `pomodoroConfig != nil`.

    /// A concrete moment within a `pomodoroConfig`-driven session.
    struct PomodoroPhase: Equatable {
        enum Kind: Equatable {
            case work(round: Int, total: Int)
            case shortBreak(afterRound: Int)
            case longBreak
            case done
        }
        let kind: Kind
        let phaseStart: Date
        let phaseEnd: Date
        /// Work rounds fully completed by `phaseStart`. For a finished
        /// session, equals `config.rounds`.
        let completedRounds: Int
        let totalRounds: Int

        var duration: TimeInterval { phaseEnd.timeIntervalSince(phaseStart) }
    }

    /// Walk the pomodoro timeline forward to find which phase contains
    /// `now`. Returns `nil` when the event has no `pomodoroConfig`
    /// (i.e. non-optimizer pomodoros or regular events).
    func currentPomodoroPhase(at now: Date) -> PomodoroPhase? {
        guard let config = pomodoroConfig else { return nil }
        let elapsed = max(0, now.timeIntervalSince(startDate))
        var cursor: TimeInterval = 0
        let workSec = TimeInterval(config.workMinutes * 60)
        let breakSec = TimeInterval(config.breakMinutes * 60)
        let longBreakSec = TimeInterval(config.longBreakMinutes * 60)

        for r in 0..<config.rounds {
            let workStart = cursor
            let workEnd = workStart + workSec
            if elapsed < workEnd {
                return PomodoroPhase(
                    kind: .work(round: r + 1, total: config.rounds),
                    phaseStart: startDate.addingTimeInterval(workStart),
                    phaseEnd: startDate.addingTimeInterval(workEnd),
                    completedRounds: r,
                    totalRounds: config.rounds
                )
            }
            cursor = workEnd
            if r < config.rounds - 1 {
                let breakEnd = cursor + breakSec
                if elapsed < breakEnd {
                    return PomodoroPhase(
                        kind: .shortBreak(afterRound: r + 1),
                        phaseStart: startDate.addingTimeInterval(cursor),
                        phaseEnd: startDate.addingTimeInterval(breakEnd),
                        completedRounds: r + 1,
                        totalRounds: config.rounds
                    )
                }
                cursor = breakEnd
            }
        }

        if longBreakSec > 0 {
            let longBreakEnd = cursor + longBreakSec
            if elapsed < longBreakEnd {
                return PomodoroPhase(
                    kind: .longBreak,
                    phaseStart: startDate.addingTimeInterval(cursor),
                    phaseEnd: startDate.addingTimeInterval(longBreakEnd),
                    completedRounds: config.rounds,
                    totalRounds: config.rounds
                )
            }
            cursor = longBreakEnd
        }

        return PomodoroPhase(
            kind: .done,
            phaseStart: startDate.addingTimeInterval(cursor),
            phaseEnd: endDate,
            completedRounds: config.rounds,
            totalRounds: config.rounds
        )
    }
}
