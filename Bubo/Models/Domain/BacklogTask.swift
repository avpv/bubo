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
    /// Optional color tag — same vocabulary as `CalendarEvent.colorTag`,
    /// shown as a colored dot in the backlog row and used by
    /// `BacklogTaskCohesion` as a secondary grouping signal so the
    /// optimizer can pack tasks the user has already grouped visually.
    var colorTag: EventColorTag?
    var dependsOn: [String] = []       // other task IDs
    var preferredPeriod: Period?        // morning / afternoon / evening
    var status: BacklogStatus = .pending
    var completedAt: Date?
    var createdAt: Date

    /// Task repeats on completion: instead of moving to `.done`, it resets to
    /// `.pending` with a fresh `createdAt`. The `recurrenceTag` is a free-form
    /// label shown in the UI ("weekly review", "daily standup") — we don't
    /// yet schedule the next occurrence automatically, just keep the row alive.
    var isRecurring: Bool = false
    var recurrenceTag: String? = nil

    /// Last mutation timestamp — used by iCloud sync to resolve conflicts
    /// when the same task was edited on two devices.  Optional for backward
    /// compatibility with data serialized before this field existed.
    var modifiedAt: Date?

    /// When the task was last scheduled by the optimizer.
    /// Used to determine carry-over: if scheduledDate < today, task is overdue.
    var scheduledDate: Date?

    /// The primary calendar event ID for this task. For tasks not split by
    /// `splitOversizedBacklogTasks`, this is the one and only event id; for
    /// tasks split into N chunks, it's the id of chunk 0 and `scheduledEventIds`
    /// holds all N. nil = unscheduled (sitting in backlog).
    var scheduledEventId: String?

    /// All calendar event ids created for this task. Always contains
    /// `scheduledEventId` as the first element when the task is scheduled.
    /// Stores >1 entry only for auto-chunked long tasks, where each chunk
    /// lands on a different day; lets the UI/cleanup paths find every
    /// scheduled slice without string-matching on "_pN" suffixes.
    var scheduledEventIds: [String] = []

    /// The Apple Reminders `calendarItemIdentifier` for tasks exported from Bubo.
    /// For tasks imported from Reminders, the ID is derived from the `reminder_` prefix.
    /// For Bubo-native tasks pushed to Reminders, this stores the created reminder's ID.
    var reminderCalendarItemId: String?

    init(
        id: String = UUID().uuidString,
        title: String,
        durationMinutes: Int = 60,
        priority: TaskPriority = .medium,
        deadline: Date? = nil,
        storyPoints: Int? = nil,
        context: String? = nil,
        colorTag: EventColorTag? = nil,
        dependsOn: [String] = [],
        preferredPeriod: Period? = nil,
        isRecurring: Bool = false,
        recurrenceTag: String? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.title = title
        self.durationMinutes = durationMinutes
        self.priority = priority
        self.deadline = deadline
        self.storyPoints = storyPoints
        self.context = context
        self.colorTag = colorTag
        self.dependsOn = dependsOn
        self.preferredPeriod = preferredPeriod
        self.isRecurring = isRecurring
        self.recurrenceTag = recurrenceTag
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
    /// Task is set aside — not deleted, but not participating in optimization
    /// or the active list. Visible under a dedicated frozen tombstone with an
    /// "Unfreeze all" action. Complements `.done` as the non-destructive way
    /// to silence a task the user isn't ready to drop entirely.
    case frozen
}

// MARK: - Cross-Device Merge

extension BacklogTask {

    /// Merge two copies of the same task — one from the local in-memory
    /// state, one freshly loaded from SwiftData after a CloudKit import.
    /// Returns the "strongest" version.
    ///
    /// We can't intercept CloudKit's own last-writer-wins row merge, so
    /// this runs as a post-import reconciliation pass: if the disk copy
    /// regressed a field that should be monotonic, we re-apply the local
    /// winner. The reverse case (disk has the newer completion, memory
    /// is stale) is also handled — the "done + completedAt set" side wins.
    ///
    /// Rules:
    ///   - `status == .done` is monotonic for non-recurring tasks: once a
    ///     task is completed on any device, a stale remote edit that says
    ///     `.pending` must not resurrect it. Guarded by `completedAt`.
    ///   - For recurring tasks, we trust `modifiedAt` — a remote "reset"
    ///     after completion is legitimate.
    ///   - `scheduledEventId` + `scheduledDate` follow `status`: when we
    ///     force status back to `.done`, the schedule slot is cleared.
    ///   - All other fields fall back to last-writer-wins via `modifiedAt`.
    static func merged(local: BacklogTask, remote: BacklogTask) -> BacklogTask {
        guard local.id == remote.id else { return remote }

        // Pick the newer base by `modifiedAt`; treat missing stamps as
        // "older than anything" so a fresh edit always wins over legacy data.
        let localStamp = local.modifiedAt ?? .distantPast
        let remoteStamp = remote.modifiedAt ?? .distantPast
        var winner = remoteStamp >= localStamp ? remote : local
        let loser  = remoteStamp >= localStamp ? local  : remote

        // Monotonic completion: if either side says "done + completedAt
        // set", preserve that over a regression. Skipped for recurring
        // tasks, which legitimately reset to `.pending` on every cycle.
        let eitherCompleted = (local.status == .done && local.completedAt != nil)
            || (remote.status == .done && remote.completedAt != nil)
        if eitherCompleted, !winner.isRecurring, winner.status != .done {
            winner.status = .done
            winner.completedAt = winner.completedAt
                ?? local.completedAt
                ?? remote.completedAt
            winner.scheduledEventId = nil
            winner.scheduledEventIds = []
            winner.scheduledDate = nil
            // Re-stamp so the monotonic promotion propagates back out to
            // the losing device on the next sync.
            winner.modifiedAt = max(localStamp, remoteStamp, winner.completedAt ?? .distantPast)
        }

        // `reminderCalendarItemId` is effectively write-once: once a task
        // is linked to Apple Reminders, losing that link to a stale remote
        // means both sides re-create the reminder, duplicating it. Keep
        // the non-nil side.
        if winner.reminderCalendarItemId == nil, loser.reminderCalendarItemId != nil {
            winner.reminderCalendarItemId = loser.reminderCalendarItemId
        }

        return winner
    }
}

// MARK: - Conversion to OptimizableEvent

extension BacklogTask {

    /// Convert a backlog task to an OptimizableEvent for the GA.
    ///
    /// `backlogIndex` is the task's 0-based position in the filtered backlog
    /// list being sent to the optimizer. When supplied, `BacklogOrderObjective`
    /// uses it to reward schedules that match the user's drag order for tasks
    /// whose priority/deadline don't otherwise differentiate them.
    func toOptimizableEvent(backlogIndex: Int? = nil) -> OptimizableEvent {
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
            isDroppable: true,
            backlogIndex: backlogIndex
        )
    }
}
