import Foundation
import SwiftData

// MARK: - Persisted Backlog Task (SwiftData)

/// SwiftData record for a backlog task.  Mirrors the in-memory `BacklogTask`
/// struct field-for-field.  Stored locally by default; can opt into CloudKit
/// sync via the `BuboCloudSyncEnabled` flag (see `BuboApp.init`).
/// All properties have defaults or are optional so the CloudKit mirror is
/// happy when the flag is on.
///
/// `BacklogService` owns the only `ModelContainer` reference and uses a fresh
/// `ModelContext` per operation, the same pattern as `EventCache`.  We never
/// touch `container.mainContext`, which avoids the whole class of SwiftData
/// threading hazards that cost us v1.10.30 through v1.10.41.
@Model
final class PersistedBacklogTask {
    var taskId: String = ""
    var title: String = ""
    var durationMinutes: Int = 60
    var priorityRaw: String = "medium"
    var deadline: Date?
    var storyPoints: Int?
    var context: String?
    /// `EventColorTag.rawValue` — optional + defaulted nil so CloudKit
    /// migration is a no-op for pre-existing rows.
    var colorTagRaw: String?
    /// JSON-encoded `[String]`.
    var dependsOnData: Data?
    var preferredPeriodRaw: String?
    var statusRaw: String = "pending"
    var completedAt: Date?
    var createdAt: Date = Date()
    var modifiedAt: Date?
    var scheduledDate: Date?
    var scheduledEventId: String?
    /// JSON-encoded `[String]`. Holds every chunk event id for auto-chunked
    /// long tasks; nil on legacy rows (decoded as an empty list, which the
    /// service back-fills from `scheduledEventId` the next time the task is
    /// scheduled).
    var scheduledEventIdsData: Data?
    var reminderCalendarItemId: String?
    /// Recurrence flags added in v1.11. Default false / nil keeps legacy rows
    /// working unchanged — an older record simply decodes to a non-recurring task.
    var isRecurring: Bool = false
    var recurrenceTag: String?

    /// Rich task fields that round-trip through Apple Reminders. Added after
    /// the initial schema — defaulted to nil so older CloudKit rows decode
    /// without migration.
    var notes: String?
    /// URL stored as a string so SwiftData/CloudKit serialize it as scalar
    /// text instead of a blob. `toBacklogTask` parses it back on load.
    var urlString: String?
    var location: String?

    /// JSON-encoded `[Subtask]`. nil on legacy rows (decoded as empty list).
    /// Stored as a blob rather than a CloudKit relationship because the
    /// nested model is intentionally lightweight (id/title/done) and lives
    /// only inside its parent — no cross-row queries needed.
    var subtasksData: Data?

    /// JSON-encoded `[String]`. Free-form text tags; nil on legacy rows
    /// decodes as an empty list. Stored as a blob (vs. one row per tag)
    /// for the same reason as `subtasksData` — tags live inside their
    /// parent task and aren't queried independently.
    var tagsData: Data?

    /// Plain integer position.  `BacklogService` rewrites `sortOrder` on
    /// every save in line with the in-memory array index — the incremental
    /// diff touches only rows whose position actually moved, but the
    /// invariant (`sortOrder == tasks.index(of: task)`) is maintained on
    /// every write, so there's no need for fractional indexing or conflict
    /// resolution.
    var sortOrder: Int = 0

    init() {}

    init(from task: BacklogTask, sortOrder: Int) {
        self.taskId = task.id
        self.sortOrder = sortOrder
        apply(task)
    }

    /// Update an existing persisted row in place from a fresh `BacklogTask`
    /// snapshot. Used by the incremental-save path so mutations touch only
    /// the rows that actually changed instead of wiping and rebuilding the
    /// whole table.
    func apply(_ task: BacklogTask, sortOrder: Int? = nil) {
        self.title = task.title
        self.durationMinutes = task.durationMinutes
        self.priorityRaw = task.priority.rawValue
        self.deadline = task.deadline
        self.storyPoints = task.storyPoints
        self.context = task.context
        self.colorTagRaw = task.colorTag?.rawValue
        self.dependsOnData = try? JSONEncoder().encode(task.dependsOn)
        self.preferredPeriodRaw = task.preferredPeriod?.rawValue
        self.statusRaw = task.status.rawValue
        self.completedAt = task.completedAt
        self.createdAt = task.createdAt
        self.modifiedAt = task.modifiedAt
        self.scheduledDate = task.scheduledDate
        self.scheduledEventId = task.scheduledEventId
        self.scheduledEventIdsData = task.scheduledEventIds.isEmpty
            ? nil
            : (try? JSONEncoder().encode(task.scheduledEventIds))
        self.reminderCalendarItemId = task.reminderCalendarItemId
        self.isRecurring = task.isRecurring
        self.recurrenceTag = task.recurrenceTag
        self.notes = task.notes
        self.urlString = task.url?.absoluteString
        self.location = task.location
        self.subtasksData = task.subtasks.isEmpty
            ? nil
            : (try? JSONEncoder().encode(task.subtasks))
        self.tagsData = task.tags.isEmpty
            ? nil
            : (try? JSONEncoder().encode(task.tags))
        if let sortOrder { self.sortOrder = sortOrder }
    }

    func toBacklogTask() -> BacklogTask {
        let deps: [String] = dependsOnData.flatMap {
            try? JSONDecoder().decode([String].self, from: $0)
        } ?? []

        let subs: [Subtask] = subtasksData.flatMap {
            try? JSONDecoder().decode([Subtask].self, from: $0)
        } ?? []

        let tags: [String] = tagsData.flatMap {
            try? JSONDecoder().decode([String].self, from: $0)
        } ?? []

        var task = BacklogTask(
            id: taskId,
            title: title,
            durationMinutes: durationMinutes,
            priority: TaskPriority(rawValue: priorityRaw) ?? .medium,
            deadline: deadline,
            storyPoints: storyPoints,
            context: context,
            colorTag: colorTagRaw.flatMap { EventColorTag(rawValue: $0) },
            dependsOn: deps,
            preferredPeriod: preferredPeriodRaw.flatMap { Period(rawValue: $0) },
            isRecurring: isRecurring,
            recurrenceTag: recurrenceTag,
            notes: notes,
            url: urlString.flatMap(URL.init(string:)),
            location: location,
            subtasks: subs,
            tags: tags,
            createdAt: createdAt
        )
        task.status = BacklogStatus(rawValue: statusRaw) ?? .pending
        task.completedAt = completedAt
        task.modifiedAt = modifiedAt
        task.scheduledDate = scheduledDate
        task.scheduledEventId = scheduledEventId
        // Legacy rows predate `scheduledEventIdsData` — fall back to the
        // singular `scheduledEventId` so the task still reports at least one
        // slot. The service refreshes the list on the next schedule pass.
        if let data = scheduledEventIdsData,
           let decoded = try? JSONDecoder().decode([String].self, from: data) {
            task.scheduledEventIds = decoded
        } else if let legacyId = scheduledEventId {
            task.scheduledEventIds = [legacyId]
        }
        task.reminderCalendarItemId = reminderCalendarItemId
        return task
    }
}
