import Foundation
import SwiftData

// MARK: - Persisted Local Event

/// SwiftData model for locally-created calendar events.
@Model
final class PersistedLocalEvent {
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
    var isTask: Bool
    var deadline: Date?
    var taskStatusRaw: String
    var completedAt: Date?
    var dependsOn: [String]

    init(from event: CalendarEvent) {
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
        return event
    }

    func update(from event: CalendarEvent) {
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
    }
}

// MARK: - Persisted Cached Event

/// SwiftData model for Apple Calendar events cached for offline access.
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
    var isTask: Bool
    var deadline: Date?
    var taskStatusRaw: String
    var completedAt: Date?
    var dependsOn: [String]
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
        return event
    }
}

// MARK: - Persisted Excluded Occurrence

/// SwiftData model for excluded recurrence occurrence IDs.
@Model
final class PersistedExcludedOccurrence {
    @Attribute(.unique) var occurrenceId: String

    init(occurrenceId: String) {
        self.occurrenceId = occurrenceId
    }
}

// MARK: - Persisted Reminder Override

/// SwiftData model for per-event reminder time overrides.
@Model
final class PersistedReminderOverride {
    @Attribute(.unique) var eventId: String
    var minutes: [Int]

    init(eventId: String, minutes: [Int]) {
        self.eventId = eventId
        self.minutes = minutes
    }
}
