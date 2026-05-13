import Foundation
import BuboDomain

// MARK: - Optimizable Event
// Moved to `Sources/Domain/Calendar/OptimizableEvent.swift` on 2026-05-12 to
// break the Domain ↔ Optimizer cycle (BacklogTask has a
// `toOptimizableEvent()` conversion).

// MARK: - Pomodoro Config
// Moved to `Sources/Domain/Pomodoro/PomodoroConfig.swift` on 2026-05-12 to
// break the Domain ↔ Optimizer cycle (CalendarEvent stores a
// `pomodoroConfig: PomodoroConfig?`).

// MARK: - Schedule Gene

/// A single gene: placement of one event in the schedule.
public struct ScheduleGene: Codable, Hashable, Sendable {
    public let eventId: String
    public let title: String
    public var startTime: Date
    public let duration: TimeInterval
    public let context: String?
    public let energyCost: Double
    public let priority: Double
    public let isFocusBlock: Bool
    public let storyPoints: Int?
    public let isDroppable: Bool           // whether the GA may exclude this gene
    public var isIncluded: Bool            // whether this gene is active in the schedule
    /// Pomodoro shape when the event represents a pomodoro session.
    /// Flows `OptimizableEvent` → gene → `applyScenario` so the service
    /// can re-resolve or persist the chosen shape onto the `CalendarEvent`.
    public let pomodoroConfig: PomodoroConfig?
    /// Backlog task ids bound to this gene (ordered per work round).
    /// Non-empty only for auto-pomodoro / focus-burst events.
    public let reservedTaskIds: [String]
    /// Atomic-group tag inherited from `OptimizableEvent.groupId`. Populated
    /// only for chunks of a split backlog task. Used by `applyScenario` so
    /// all chunks of one parent task link back to the same `BacklogTask.id`
    /// rather than each chunk looking up a non-existent "taskId_pN" row.
    public let groupId: String?

    /// Slot-based decoder: index into `OptimizerContext.ensureSlotRegistry()`
    /// that this gene's `startTime` resolves to. Optional so older persisted
    /// JSON (which predates the field) decodes cleanly and so tests / legacy
    /// call sites that don't thread a registry still work — `nil` means "no
    /// slot binding yet, use `startTime` as the source of truth".
    ///
    /// When non-nil, operators are expected to mutate by updating the index
    /// via the registry and then re-deriving `startTime = registry.resolvedDate(at:)`.
    /// That keeps the dual representation coherent: `slotIndex` drives the
    /// GA's discrete search, `startTime` is the continuous value every
    /// reader (fitness, UI, serialisation) already expects. See the
    /// "Slot-Alignment Design Note" in Chromosome.swift for the migration
    /// plan that ends with `startTime` becoming a computed property.
    public var slotIndex: Int?

    public var endTime: Date { startTime.addingTimeInterval(duration) }

    public init(
        eventId: String,
        title: String,
        startTime: Date,
        duration: TimeInterval,
        context: String?,
        energyCost: Double,
        priority: Double,
        isFocusBlock: Bool,
        storyPoints: Int? = nil,
        isDroppable: Bool = false,
        isIncluded: Bool = true,
        pomodoroConfig: PomodoroConfig? = nil,
        reservedTaskIds: [String] = [],
        groupId: String? = nil,
        slotIndex: Int? = nil
    ) {
        self.eventId = eventId
        self.title = title
        self.startTime = startTime
        self.duration = duration
        self.context = context
        self.energyCost = energyCost
        self.priority = priority
        self.isFocusBlock = isFocusBlock
        self.storyPoints = storyPoints
        self.isDroppable = isDroppable
        self.isIncluded = isIncluded
        self.pomodoroConfig = pomodoroConfig
        self.reservedTaskIds = reservedTaskIds
        self.groupId = groupId
        self.slotIndex = slotIndex
    }

    /// Create a copy that sets both `slotIndex` and the derived
    /// `startTime` in one go. Use this from every operator that moves
    /// a gene — mutation, repair's re-home, crossover's swap — so the
    /// two fields never drift. Passing the resolved `date` up-front
    /// avoids forcing the caller to carry the registry into fitness
    /// evaluation (which still reads `startTime`).
    public func withSlot(index: Int, date: Date) -> ScheduleGene {
        ScheduleGene(
            eventId: eventId,
            title: title,
            startTime: date,
            duration: duration,
            context: context,
            energyCost: energyCost,
            priority: priority,
            isFocusBlock: isFocusBlock,
            storyPoints: storyPoints,
            isDroppable: isDroppable,
            isIncluded: isIncluded,
            pomodoroConfig: pomodoroConfig,
            reservedTaskIds: reservedTaskIds,
            groupId: groupId,
            slotIndex: index
        )
    }

    /// Drop-in replacement for the old `withStartTime(_:)` that
    /// binds `slotIndex` through the registry in the same call. The
    /// canonical way to move a gene when you have a Date in hand
    /// and a registry available — keeps both fields in sync so
    /// `slotIndex == nil` never shows up in production state.
    ///
    /// Also snaps `startTime` to the resolved grid Date so the
    /// invariant `startTime == registry.slots[slotIndex]` holds after
    /// this call. Callers routinely pass off-grid Dates (`horizon.start`
    /// captured at the current wall-clock, `earliestStart` pulled from
    /// arbitrary user input, gap edges from fixed-event boundaries at
    /// sub-minute precision) and used to have those off-grid seconds
    /// leak into `startTime` — which then surfaced in the UI and log
    /// as times like 15:06 or 17:21 instead of the 15-/5-minute grid.
    public func withSlot(nearest date: Date, registry: SlotRegistry) -> ScheduleGene {
        let idx = registry.nearestIndex(to: date)
        let aligned = idx.flatMap { registry.resolvedDate(at: $0) } ?? date
        return ScheduleGene(
            eventId: eventId,
            title: title,
            startTime: aligned,
            duration: duration,
            context: context,
            energyCost: energyCost,
            priority: priority,
            isFocusBlock: isFocusBlock,
            storyPoints: storyPoints,
            isDroppable: isDroppable,
            isIncluded: isIncluded,
            pomodoroConfig: pomodoroConfig,
            reservedTaskIds: reservedTaskIds,
            groupId: groupId,
            slotIndex: idx
        )
    }

    /// Inherit placement (`startTime` + `slotIndex`) from another gene
    /// while keeping every other field of `self`. Used by crossover so
    /// slot bindings survive the parent-to-child transfer — without
    /// this, every crossover would invalidate `slotIndex` and force
    /// repair to re-bind every gene on the next generation.
    public func withPlacement(from other: ScheduleGene) -> ScheduleGene {
        ScheduleGene(
            eventId: eventId,
            title: title,
            startTime: other.startTime,
            duration: duration,
            context: context,
            energyCost: energyCost,
            priority: priority,
            isFocusBlock: isFocusBlock,
            storyPoints: storyPoints,
            isDroppable: isDroppable,
            isIncluded: isIncluded,
            pomodoroConfig: pomodoroConfig,
            reservedTaskIds: reservedTaskIds,
            groupId: groupId,
            slotIndex: other.slotIndex
        )
    }
}

