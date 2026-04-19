import Foundation
import SwiftData

// MARK: - Persisted Local Event
//
// CloudKit-backed models in this file (LocalEvent, ExcludedOccurrence,
// ReminderOverride) deliberately avoid `@Attribute(.unique)` because
// `NSPersistentCloudKitContainer` rejects unique constraints. Every property
// has a default value or is optional — that's a hard CloudKit-mirroring
// requirement, and the same reason `PersistedBacklogTask` is structured the
// way it is.
//
// Dedup is handled in the owning service (ReminderService) via upsert:
// `fetch` by logical key, update in place if found, otherwise insert. The
// `updatedAt` field is set on every mutation so the collapse-duplicates pass
// on load and the post-import reconcile can deterministically pick the
// latest writer.

/// SwiftData model for locally-created calendar events.
@Model
final class PersistedLocalEvent {
    var eventId: String = ""
    var title: String = ""
    var startDate: Date = Date()
    var endDate: Date = Date()
    var location: String?
    var eventDescription: String?
    var calendarName: String?
    var customReminderMinutes: [Int]?
    var recurrenceRuleData: Data?
    var seriesId: String?
    var eventTypeRaw: String = "standard"
    var colorTagRaw: String?
    var context: String?
    var storyPoints: Int?
    var isTask: Bool = false
    var deadline: Date?
    var taskStatusRaw: String = "todo"
    var completedAt: Date?
    var dependsOn: [String] = []
    /// JSON-encoded `PomodoroConfig`. Optional + defaulted so CloudKit
    /// migration is a no-op for pre-existing rows; newly-stored pomodoro
    /// events carry the resolver's chosen shape here.
    var pomodoroConfigData: Data?
    var updatedAt: Date = Date()

    init() {}

    init(from event: CalendarEvent, updatedAt: Date = Date()) {
        self.eventId = event.id
        self.updatedAt = updatedAt
        apply(event, updatedAt: updatedAt)
    }

    func apply(_ event: CalendarEvent, updatedAt: Date = Date()) {
        self.title = event.title
        self.startDate = event.startDate
        self.endDate = event.endDate
        self.location = event.location
        self.eventDescription = event.description
        self.calendarName = event.calendarName
        self.customReminderMinutes = event.customReminderMinutes
        self.recurrenceRuleData = event.recurrenceRule.flatMap { try? JSONEncoder().encode($0) }
        self.seriesId = event.seriesId
        self.eventTypeRaw = event.eventType.rawValue
        self.colorTagRaw = event.colorTag?.rawValue
        self.context = event.context
        self.storyPoints = event.storyPoints
        self.isTask = event.isTask
        self.deadline = event.deadline
        self.taskStatusRaw = event.taskStatus.rawValue
        self.completedAt = event.completedAt
        self.dependsOn = event.dependsOn
        self.pomodoroConfigData = event.pomodoroConfig.flatMap { try? JSONEncoder().encode($0) }
        self.updatedAt = updatedAt
    }

    func toCalendarEvent() -> CalendarEvent {
        let recurrenceRule: RecurrenceRule? = recurrenceRuleData.flatMap {
            try? JSONDecoder().decode(RecurrenceRule.self, from: $0)
        }
        var event = CalendarEvent(
            id: eventId,
            title: title,
            startDate: startDate,
            endDate: endDate,
            location: location,
            description: eventDescription,
            calendarName: calendarName,
            customReminderMinutes: customReminderMinutes,
            recurrenceRule: recurrenceRule,
            seriesId: seriesId,
            eventType: EventType(rawValue: eventTypeRaw) ?? .standard,
            colorTag: colorTagRaw.flatMap { EventColorTag(rawValue: $0) },
            context: context
        )
        event.storyPoints = storyPoints
        event.isTask = isTask
        event.deadline = deadline
        event.taskStatus = TaskStatus(rawValue: taskStatusRaw) ?? .todo
        event.completedAt = completedAt
        event.dependsOn = dependsOn
        event.pomodoroConfig = pomodoroConfigData.flatMap {
            try? JSONDecoder().decode(PomodoroConfig.self, from: $0)
        }
        return event
    }
}

// MARK: - Persisted Cached Event

/// SwiftData model for Apple Calendar events cached for offline access.
/// Stays local (never mirrored to CloudKit) because EventKit itself already
/// syncs iCloud calendars at the OS level, and the cache is a per-device
/// scratch pad that's atomically rebuilt on every sync. Keeping the unique
/// constraint here is safe (and useful) since this model never enters a
/// CloudKit-backed container.
@Model
final class PersistedCachedEvent {
    @Attribute(.unique) var eventId: String
    var title: String
    var startDate: Date
    var endDate: Date
    var location: String?
    var eventDescription: String?
    var calendarName: String?
    var customReminderMinutes: [Int]?
    var recurrenceRuleData: Data?
    var seriesId: String?
    var eventTypeRaw: String
    var colorTagRaw: String?
    var context: String?
    var storyPoints: Int?
    var isTask: Bool = false
    var deadline: Date?
    var taskStatusRaw: String = "todo"
    var completedAt: Date?
    var dependsOn: [String] = []
    /// JSON-encoded `PomodoroConfig`. Mirrors the field on
    /// `PersistedLocalEvent` so a pomodoro brought back from the cache
    /// still knows its shape.
    var pomodoroConfigData: Data?
    var cachedAt: Date

    init(from event: CalendarEvent, cachedAt: Date = Date()) {
        self.eventId = event.id
        self.title = event.title
        self.startDate = event.startDate
        self.endDate = event.endDate
        self.location = event.location
        self.eventDescription = event.description
        self.calendarName = event.calendarName
        self.customReminderMinutes = event.customReminderMinutes
        self.recurrenceRuleData = event.recurrenceRule.flatMap { try? JSONEncoder().encode($0) }
        self.seriesId = event.seriesId
        self.eventTypeRaw = event.eventType.rawValue
        self.colorTagRaw = event.colorTag?.rawValue
        self.context = event.context
        self.storyPoints = event.storyPoints
        self.isTask = event.isTask
        self.deadline = event.deadline
        self.taskStatusRaw = event.taskStatus.rawValue
        self.completedAt = event.completedAt
        self.dependsOn = event.dependsOn
        self.pomodoroConfigData = event.pomodoroConfig.flatMap { try? JSONEncoder().encode($0) }
        self.cachedAt = cachedAt
    }

    func toCalendarEvent() -> CalendarEvent {
        let recurrenceRule: RecurrenceRule? = recurrenceRuleData.flatMap {
            try? JSONDecoder().decode(RecurrenceRule.self, from: $0)
        }
        var event = CalendarEvent(
            id: eventId,
            title: title,
            startDate: startDate,
            endDate: endDate,
            location: location,
            description: eventDescription,
            calendarName: calendarName,
            customReminderMinutes: customReminderMinutes,
            recurrenceRule: recurrenceRule,
            seriesId: seriesId,
            eventType: EventType(rawValue: eventTypeRaw) ?? .standard,
            colorTag: colorTagRaw.flatMap { EventColorTag(rawValue: $0) },
            context: context
        )
        event.storyPoints = storyPoints
        event.isTask = isTask
        event.deadline = deadline
        event.taskStatus = TaskStatus(rawValue: taskStatusRaw) ?? .todo
        event.completedAt = completedAt
        event.dependsOn = dependsOn
        event.pomodoroConfig = pomodoroConfigData.flatMap {
            try? JSONDecoder().decode(PomodoroConfig.self, from: $0)
        }
        return event
    }
}

// MARK: - Persisted Excluded Occurrence

/// SwiftData model for excluded recurrence occurrence IDs.
@Model
final class PersistedExcludedOccurrence {
    var occurrenceId: String = ""
    var updatedAt: Date = Date()

    init() {}

    init(occurrenceId: String, updatedAt: Date = Date()) {
        self.occurrenceId = occurrenceId
        self.updatedAt = updatedAt
    }
}

// MARK: - Persisted Reminder Override

/// SwiftData model for per-event reminder time overrides.
@Model
final class PersistedReminderOverride {
    var eventId: String = ""
    var minutes: [Int] = []
    var updatedAt: Date = Date()

    init() {}

    init(eventId: String, minutes: [Int], updatedAt: Date = Date()) {
        self.eventId = eventId
        self.minutes = minutes
        self.updatedAt = updatedAt
    }
}
