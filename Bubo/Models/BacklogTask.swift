import Foundation

// MARK: - Backlog Task

/// A persistent task that lives in the backlog until completed.
/// Unlike CalendarEvent tasks, BacklogTask is never "consumed" by optimization —
/// it persists across sessions and is automatically carried over when unscheduled.
struct BacklogTask: Identifiable, Codable, Hashable, Sendable {
    let id: String
    var title: String
    var durationMinutes: Int
    var priority: TaskPriority
    var deadline: Date?
    var storyPoints: Int?
    var context: String?               // project / category
    var dependsOn: [String] = []       // other task IDs
    var preferredPeriod: Period?        // morning / afternoon / evening
    var status: BacklogStatus = .pending
    var completedAt: Date?
    var createdAt: Date

    /// Last mutation timestamp — used by iCloud sync to resolve conflicts
    /// when the same task was edited on two devices.  Optional for backward
    /// compatibility with data serialized before this field existed.
    var modifiedAt: Date?

    /// When the task was last scheduled by the optimizer.
    /// Used to determine carry-over: if scheduledDate < today, task is overdue.
    var scheduledDate: Date?

    /// The calendar event ID created when this task was placed in the schedule.
    /// nil = unscheduled (sitting in backlog).
    var scheduledEventId: String?

    init(
        id: String = UUID().uuidString,
        title: String,
        durationMinutes: Int = 60,
        priority: TaskPriority = .medium,
        deadline: Date? = nil,
        storyPoints: Int? = nil,
        context: String? = nil,
        dependsOn: [String] = [],
        preferredPeriod: Period? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.title = title
        self.durationMinutes = durationMinutes
        self.priority = priority
        self.deadline = deadline
        self.storyPoints = storyPoints
        self.context = context
        self.dependsOn = dependsOn
        self.preferredPeriod = preferredPeriod
        self.createdAt = createdAt
    }
}

// MARK: - Task Priority

enum TaskPriority: String, Codable, Hashable, Sendable, CaseIterable {
    case low
    case medium
    case high

    var numericValue: Double {
        switch self {
        case .low: return 0.3
        case .medium: return 0.5
        case .high: return 0.9
        }
    }

    var label: String {
        switch self {
        case .low: return "Low"
        case .medium: return "Medium"
        case .high: return "High"
        }
    }
}

// MARK: - Backlog Status

enum BacklogStatus: String, Codable, Hashable, Sendable, CaseIterable {
    /// Task is in the backlog, not yet scheduled.
    case pending
    /// Task has been placed in the schedule by the optimizer.
    case scheduled
    /// Task is completed.
    case done
}

// MARK: - Conversion to OptimizableEvent

extension BacklogTask {

    /// Convert a backlog task to an OptimizableEvent for the GA.
    func toOptimizableEvent() -> OptimizableEvent {
        let effectiveEnergy = adjustedEnergy(
            base: priority == .high ? 0.7 : 0.5,
            storyPoints: storyPoints
        )
        return OptimizableEvent(
            id: id,
            title: title,
            duration: TimeInterval(durationMinutes * 60),
            deadline: deadline,
            priority: priority.numericValue,
            context: context,
            energyCost: effectiveEnergy,
            preferredHourRange: preferredPeriod?.hourRange,
            isFocusBlock: false,
            storyPoints: storyPoints,
            dependsOn: dependsOn,
            isDroppable: true
        )
    }
}
