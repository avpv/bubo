import Foundation
import SwiftData

// MARK: - Persisted Backlog Task (SwiftData + CloudKit)

/// SwiftData model for backlog tasks, synced across devices via CloudKit.
/// The struct `BacklogTask` remains the in-memory / API type; this class
/// is the persistence layer only.
@Model
final class PersistedBacklogTask {
    var taskId: String = ""
    var title: String = ""
    var durationMinutes: Int = 60
    var priorityRaw: String = "medium"
    var deadline: Date?
    var storyPoints: Int?
    var context: String?
    /// JSON-encoded `[String]` — CloudKit-safe storage for array data.
    var dependsOnData: Data?
    var preferredPeriodRaw: String?
    var statusRaw: String = "pending"
    var completedAt: Date?
    var createdAt: Date = Date()
    var modifiedAt: Date?
    var scheduledDate: Date?
    var scheduledEventId: String?

    /// User-controlled ordering.  Uses `Double` with gaps (fractional
    /// indexing) so that a reorder only touches ONE record — minimises
    /// CloudKit conflicts when two devices reorder simultaneously.
    var sortOrder: Double = 0

    init() {}

    init(from task: BacklogTask, sortOrder: Double) {
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
        self.sortOrder = sortOrder
    }

    // MARK: - Conversion

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
        return task
    }

    func update(from task: BacklogTask) {
        title = task.title
        durationMinutes = task.durationMinutes
        priorityRaw = task.priority.rawValue
        deadline = task.deadline
        storyPoints = task.storyPoints
        context = task.context
        dependsOnData = try? JSONEncoder().encode(task.dependsOn)
        preferredPeriodRaw = task.preferredPeriod?.rawValue
        statusRaw = task.status.rawValue
        completedAt = task.completedAt
        modifiedAt = task.modifiedAt
        scheduledDate = task.scheduledDate
        scheduledEventId = task.scheduledEventId
    }
}
