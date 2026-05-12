import Foundation

// MARK: - Optimizable Event

/// An event that the optimizer can move around in the schedule.
///
/// Lives in `Domain/` rather than `Optimizer/` because `BacklogTask`
/// has a `toOptimizableEvent()` conversion method on it. Moving the
/// type here breaks the Domain ↔ Optimizer dependency cycle.
public struct OptimizableEvent: Identifiable, Codable, Hashable, Sendable {
    public let id: String
    public let title: String
    public let duration: TimeInterval
    public let deadline: Date?
    public let priority: Double            // 0…1, higher = more important
    public let context: String?            // project / category tag
    public let energyCost: Double          // 0…1, cognitive load
    public let requiredParticipants: [String]
    public let preferredHourRange: ClosedRange<Int>?  // e.g. 9...12
    public let isFocusBlock: Bool
    public let pomodoroConfig: PomodoroConfig?
    public let earliestStart: Date?        // don't schedule before this time
    public let storyPoints: Int?           // effort estimate (1, 2, 3, 5, 8, 13)
    public let dependsOn: [String]         // IDs of tasks that must finish first
    public let isDroppable: Bool           // GA can exclude this event if it doesn't fit
    /// Backlog task ids bound to this optimizable event (ordered).
    /// Non-empty only for pomodoro sessions produced by `.pomodoroSession`
    /// or `.focusBurst` — one entry per work round when the session is
    /// filled with backlog work.
    public let reservedTaskIds: [String]
    /// Position in the user's backlog at the moment the event was collected.
    /// Populated only for events coming from `BacklogService` via
    /// `collectBacklogTasks`; stays `nil` for calendar-derived events.
    /// `BacklogOrderObjective` reads this so that backlog tasks whose
    /// priority/deadline are identical end up placed in the order the user
    /// dragged them into — the GA actively prefers matching visual order
    /// instead of relying on a single stable-sort pass in the greedy seed.
    public let backlogIndex: Int?
    /// Atomic-group tag: events sharing a non-nil `groupId` must be
    /// included-or-dropped together (enforced by `AtomicGroupConstraint`).
    /// Populated by `IntentCompiler.splitOversizedBacklogTasks` when a
    /// long backlog task is chunked across days, so the GA can't place
    /// chunk 1 and 3 while dropping 2 — leaving a task half-scheduled.
    public let groupId: String?

    public init(
        id: String = UUID().uuidString,
        title: String,
        duration: TimeInterval,
        deadline: Date? = nil,
        priority: Double = 0.5,
        context: String? = nil,
        energyCost: Double = 0.5,
        requiredParticipants: [String] = [],
        preferredHourRange: ClosedRange<Int>? = nil,
        isFocusBlock: Bool = false,
        pomodoroConfig: PomodoroConfig? = nil,
        earliestStart: Date? = nil,
        storyPoints: Int? = nil,
        dependsOn: [String] = [],
        isDroppable: Bool = false,
        reservedTaskIds: [String] = [],
        backlogIndex: Int? = nil,
        groupId: String? = nil
    ) {
        self.id = id
        self.title = title
        self.duration = duration
        self.deadline = deadline
        self.priority = priority
        self.context = context
        self.energyCost = energyCost
        self.requiredParticipants = requiredParticipants
        self.preferredHourRange = preferredHourRange
        self.isFocusBlock = isFocusBlock
        self.pomodoroConfig = pomodoroConfig
        self.earliestStart = earliestStart
        self.storyPoints = storyPoints
        self.dependsOn = dependsOn
        self.isDroppable = isDroppable
        self.reservedTaskIds = reservedTaskIds
        self.backlogIndex = backlogIndex
        self.groupId = groupId
    }
}
