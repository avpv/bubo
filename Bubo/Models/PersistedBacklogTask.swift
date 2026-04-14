import Foundation
import SwiftData

// MARK: - Persisted Backlog Task (SwiftData)

/// SwiftData record for a backlog task.  Mirrors the in-memory `BacklogTask`
/// struct field-for-field.  Stored locally only — no CloudKit — so init is
/// fast and never blocks the main thread trying to authenticate with iCloud.
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
    /// JSON-encoded `[String]`.
    var dependsOnData: Data?
    var preferredPeriodRaw: String?
    var statusRaw: String = "pending"
    var completedAt: Date?
    var createdAt: Date = Date()
    var modifiedAt: Date?
    var scheduledDate: Date?
    var scheduledEventId: String?
    var reminderCalendarItemId: String?

    /// Plain integer position.  `BacklogService` rewrites all rows on every
    /// save, so there's no need for fractional indexing or conflict
    /// resolution — `sortOrder` simply mirrors the in-memory array index.
    var sortOrder: Int = 0

    init() {}

    init(from task: BacklogTask, sortOrder: Int) {
        self.taskId = task.id
        self.title = task.title
        self.durationMinutes = task.durationMinutes
        self.priorityRaw = task.priority.rawValue
        self.deadline = task.deadline
        self.storyPoints = task.storyPoints
        self.context = task.context
        self.dependsOnData = try? JSONEncoder().encode(task.dependsOn)
        self.preferredPeriodRaw = task.preferredPeriod?.rawValue
        self.statusRaw = task.status.rawValue
        self.completedAt = task.completedAt
        self.createdAt = task.createdAt
        self.modifiedAt = task.modifiedAt
        self.scheduledDate = task.scheduledDate
        self.scheduledEventId = task.scheduledEventId
        self.reminderCalendarItemId = task.reminderCalendarItemId
        self.sortOrder = sortOrder
    }

    func toBacklogTask() -> BacklogTask {
        let deps: [String] = dependsOnData.flatMap {
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
            dependsOn: deps,
            preferredPeriod: preferredPeriodRaw.flatMap { Period(rawValue: $0) },
            createdAt: createdAt
        )
        task.status = BacklogStatus(rawValue: statusRaw) ?? .pending
        task.completedAt = completedAt
        task.modifiedAt = modifiedAt
        task.scheduledDate = scheduledDate
        task.scheduledEventId = scheduledEventId
        task.reminderCalendarItemId = reminderCalendarItemId
        return task
    }
}
