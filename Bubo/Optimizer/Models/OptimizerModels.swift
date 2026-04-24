import Foundation

// MARK: - Optimizable Event

/// An event that the optimizer can move around in the schedule.
struct OptimizableEvent: Identifiable, Codable, Hashable, Sendable {
    let id: String
    let title: String
    let duration: TimeInterval
    let deadline: Date?
    let priority: Double            // 0…1, higher = more important
    let context: String?            // project / category tag
    let energyCost: Double          // 0…1, cognitive load
    let requiredParticipants: [String]
    let preferredHourRange: ClosedRange<Int>?  // e.g. 9...12
    let isFocusBlock: Bool
    let pomodoroConfig: PomodoroConfig?
    let earliestStart: Date?        // don't schedule before this time
    let storyPoints: Int?           // effort estimate (1, 2, 3, 5, 8, 13)
    let dependsOn: [String]         // IDs of tasks that must finish first
    let isDroppable: Bool           // GA can exclude this event if it doesn't fit
    /// Backlog task ids bound to this optimizable event (ordered).
    /// Non-empty only for pomodoro sessions produced by `.pomodoroSession`
    /// or `.focusBurst` — one entry per work round when the session is
    /// filled with backlog work.
    let reservedTaskIds: [String]
    /// Position in the user's backlog at the moment the event was collected.
    /// Populated only for events coming from `BacklogService` via
    /// `collectBacklogTasks`; stays `nil` for calendar-derived events.
    /// `BacklogOrderObjective` reads this so that backlog tasks whose
    /// priority/deadline are identical end up placed in the order the user
    /// dragged them into — the GA actively prefers matching visual order
    /// instead of relying on a single stable-sort pass in the greedy seed.
    let backlogIndex: Int?
    /// Atomic-group tag: events sharing a non-nil `groupId` must be
    /// included-or-dropped together (enforced by `AtomicGroupConstraint`).
    /// Populated by `IntentCompiler.splitOversizedBacklogTasks` when a
    /// long backlog task is chunked across days, so the GA can't place
    /// chunk 1 and 3 while dropping 2 — leaving a task half-scheduled.
    let groupId: String?

    init(
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

// MARK: - Pomodoro Config

struct PomodoroConfig: Codable, Hashable, Sendable {
    let workMinutes: Int
    let breakMinutes: Int
    let rounds: Int
    let longBreakMinutes: Int

    /// Wall-clock minutes from first round start to end of long break.
    /// The last round has no trailing short break, so we have
    /// `rounds` works + `rounds - 1` short breaks + optional long break.
    var totalMinutes: Int {
        workMinutes * rounds
            + breakMinutes * max(0, rounds - 1)
            + longBreakMinutes
    }
}

// MARK: - Schedule Gene

/// A single gene: placement of one event in the schedule.
struct ScheduleGene: Codable, Hashable, Sendable {
    let eventId: String
    let title: String
    var startTime: Date
    let duration: TimeInterval
    let context: String?
    let energyCost: Double
    let priority: Double
    let isFocusBlock: Bool
    let storyPoints: Int?
    let isDroppable: Bool           // whether the GA may exclude this gene
    var isIncluded: Bool            // whether this gene is active in the schedule
    /// Pomodoro shape when the event represents a pomodoro session.
    /// Flows `OptimizableEvent` → gene → `applyScenario` so the service
    /// can re-resolve or persist the chosen shape onto the `CalendarEvent`.
    let pomodoroConfig: PomodoroConfig?
    /// Backlog task ids bound to this gene (ordered per work round).
    /// Non-empty only for auto-pomodoro / focus-burst events.
    let reservedTaskIds: [String]
    /// Atomic-group tag inherited from `OptimizableEvent.groupId`. Populated
    /// only for chunks of a split backlog task. Used by `applyScenario` so
    /// all chunks of one parent task link back to the same `BacklogTask.id`
    /// rather than each chunk looking up a non-existent "taskId_pN" row.
    let groupId: String?

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
    var slotIndex: Int?

    var endTime: Date { startTime.addingTimeInterval(duration) }

    init(
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
    func withSlot(index: Int, date: Date) -> ScheduleGene {
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
    func withSlot(nearest date: Date, registry: SlotRegistry) -> ScheduleGene {
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
    func withPlacement(from other: ScheduleGene) -> ScheduleGene {
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

// MARK: - Optimizer Context

/// All data the optimizer needs to generate and evaluate schedules.
///
/// Note on determinism: `rng` is a reference-typed `GARandom` shared across
/// every operator (mutation, crossover, selection, …) during a run. Passing
/// a seeded RNG makes the whole optimization reproducible, which is what the
/// benchmark/regression suite relies on. Default is `GARandom()` with a
/// system-derived seed so production runs stay non-repetitive while still
/// being internally deterministic (the seed is recoverable via `rng.seed`
/// for replaying a failing run).
struct OptimizerContext: Sendable {
    let fixedEvents: [CalendarEvent]
    let movableEvents: [OptimizableEvent]
    let workingHours: ClosedRange<Int>              // e.g. 9...18
    let planningHorizon: DateInterval
    let preferences: OptimizerPreferences
    let participantAvailability: [String: [DateInterval]]  // participantId -> free slots
    let calendar: Calendar
    let rng: GARandom

    /// Adaptive operator selector. `ScheduleChromosome.mutate` consults
    /// this to pick a mutation operator per call instead of rolling
    /// uniformly. Shared across every mutation in a single run so the
    /// arm reward statistics accumulate.
    let mutationBandit: MutationBandit

    /// Adaptive destroy-strategy selector for `MutationOperator.lnsDay`.
    /// Roulette-selects one of five ALNS destroy heuristics per LNS call;
    /// weights learn from per-call fitness deltas. Shared across islands
    /// same as `mutationBandit` so strategy rewards accumulate globally.
    let lnsStrategyBandit: LNSStrategyBandit

    /// Second bandit for the repair half of the ALNS cycle — chooses
    /// between handwritten branch-and-bound, regret insertion, and the
    /// CP-SAT adapter per LNS call. Trained with the same fitness-delta
    /// signal as `lnsStrategyBandit`, so the combined policy converges on
    /// the destroy × repair pair that's best for the current landscape
    /// without having to enumerate all 15 pairs as independent arms.
    let lnsRepairBandit: LNSRepairBandit

    /// Attention head for `CrossoverStrategy.contextual`. Contextual
    /// crossover scores every gene pair through this head before
    /// deciding which parent to inherit from. Shared across islands so
    /// the head's learnable weights absorb experience from every
    /// population.
    let contextualCrossoverHead: GeneAttentionHead

    /// Preprocessed structural graph over `movableEvents`. Held via a
    /// reference-type cache so every copy of the context (Swift value
    /// semantics) points at the same built graph — fitness evaluators,
    /// mutation operators, and QD descriptors all pay the build cost
    /// exactly once per run.
    ///
    /// Uses by consumers:
    ///   * mutation bandit context features (conflict density, chain depth);
    ///   * graph-aware crossover (keep components intact);
    ///   * QD archive's precedence-tightness descriptor;
    ///   * per-component delta evaluation for global objectives.
    ///
    /// Stays `nil` on legacy code paths that don't yet pass a holder;
    /// `ensureConflictGraph()` builds on demand in that case.
    let conflictGraphHolder: ConflictGraphHolder?

    /// Optional tabu memory consulted by LNS destroy when picking
    /// which events to rip out. When nil the destroy operators fall
    /// back to their original heuristic selection.
    let tabuMemory: TabuMemory?

    /// Optional CP-SAT-style repair adapter. When supplied and the
    /// destroy window is at least `largeWindowThreshold` genes, the
    /// chromosome's `applyLNS` delegates to this stronger solver
    /// instead of the built-in handwritten branch-and-bound. nil =
    /// always use the built-in path.
    let cpSATRepairer: CPSATRepairer?
    let cpSATWindowThreshold: Int

    /// Lazy holder for the slot registry — the discrete search space
    /// the GA samples from. Built once per run and shared across every
    /// value-semantic copy of this context via the reference holder
    /// (same pattern as `conflictGraphHolder`). `ensureSlotRegistry()`
    /// builds on demand when the holder is nil, so legacy callers
    /// (tests, one-shot contexts) don't have to plumb one in.
    let slotRegistryHolder: SlotRegistryHolder?

    /// Lazy holder for per-movable-event feasible slot domains. Each
    /// domain is the subset of registry indices that satisfy the
    /// event's static constraints (earliestStart, deadline,
    /// working-hours fit, duration-aware fixed-event non-overlap) and
    /// is consulted by mutation operators to sample from a
    /// pre-filtered set instead of recomputing
    /// `SlotRegistry.allowedIndices` and the overlap scan per call.
    /// `ensureSlotDomains()` builds on demand when the holder is nil,
    /// matching `slotRegistryHolder`'s lazy-build contract.
    let slotDomainsHolder: SlotDomainsHolder?

    init(
        fixedEvents: [CalendarEvent] = [],
        movableEvents: [OptimizableEvent] = [],
        workingHours: ClosedRange<Int> = 9...18,
        planningHorizon: DateInterval = DateInterval(
            start: Date(),
            duration: 7 * 24 * 3600
        ),
        preferences: OptimizerPreferences = OptimizerPreferences(),
        participantAvailability: [String: [DateInterval]] = [:],
        calendar: Calendar = .current,
        rng: GARandom = GARandom(),
        mutationBandit: MutationBandit = MutationBandit(),
        lnsStrategyBandit: LNSStrategyBandit = LNSStrategyBandit(),
        lnsRepairBandit: LNSRepairBandit = LNSRepairBandit(),
        contextualCrossoverHead: GeneAttentionHead = GeneAttentionHead(),
        conflictGraphHolder: ConflictGraphHolder? = nil,
        tabuMemory: TabuMemory? = nil,
        cpSATRepairer: CPSATRepairer? = nil,
        cpSATWindowThreshold: Int = 20,
        slotRegistryHolder: SlotRegistryHolder? = nil,
        slotDomainsHolder: SlotDomainsHolder? = nil
    ) {
        self.fixedEvents = fixedEvents
        self.movableEvents = movableEvents
        self.workingHours = workingHours
        self.planningHorizon = planningHorizon
        self.preferences = preferences
        self.participantAvailability = participantAvailability
        self.calendar = calendar
        self.rng = rng
        self.mutationBandit = mutationBandit
        self.lnsStrategyBandit = lnsStrategyBandit
        self.lnsRepairBandit = lnsRepairBandit
        self.contextualCrossoverHead = contextualCrossoverHead
        // Production entry points construct a shared holder so every
        // context copy hits the same cache; tests and one-shot
        // contexts omit it and pay the build cost on first access.
        self.conflictGraphHolder = conflictGraphHolder
        self.tabuMemory = tabuMemory
        self.cpSATRepairer = cpSATRepairer
        self.cpSATWindowThreshold = cpSATWindowThreshold
        self.slotRegistryHolder = slotRegistryHolder
        self.slotDomainsHolder = slotDomainsHolder
    }

    /// Returns a materialised conflict graph for this context. Goes
    /// through the shared holder when available (built once per run)
    /// and falls back to building inline when no holder was supplied.
    /// The holder path is the fast path — expect tests to hit the
    /// inline fallback and production to hit the cache.
    func ensureConflictGraph() -> ScheduleConflictGraph {
        if let holder = conflictGraphHolder {
            return holder.get(for: self)
        }
        return ScheduleConflictGraph.build(from: self)
    }

    /// Returns the precomputed slot registry. Goes through the shared
    /// holder on the production path; callers without a holder (tests,
    /// legacy one-shot contexts) get an inline build on first access.
    /// Same pattern as `ensureConflictGraph`.
    func ensureSlotRegistry() -> SlotRegistry {
        if let holder = slotRegistryHolder {
            return holder.get(for: self)
        }
        return SlotRegistry.build(from: self)
    }

    /// Returns this movable event's precomputed slot domain — the set
    /// of registry indices where the event can feasibly start given
    /// its static constraints plus duration-aware fixed-event
    /// non-overlap. Goes through the shared holder on the production
    /// path; falls back to an inline build for tests that don't plumb
    /// a holder through.
    func ensureSlotDomain(for eventId: String) -> SlotDomain {
        if let holder = slotDomainsHolder {
            return holder.domain(for: eventId, in: self)
        }
        guard let event = movableEvents.first(where: { $0.id == eventId }) else {
            return .empty
        }
        return SlotDomain.build(for: event, registry: ensureSlotRegistry(), context: self)
    }

    /// `eventId → backlogIndex` map over `movableEvents`. Built on demand
    /// by callers that need a backlog-order tiebreaker (LNS destroy, CP
    /// repair variable selection, warm-start topological ordering,
    /// contextual crossover attention). Events without a `backlogIndex`
    /// are omitted — callers should treat "not present" as "no preference".
    func backlogIndexMap() -> [String: Int] {
        var map: [String: Int] = [:]
        map.reserveCapacity(movableEvents.count)
        for event in movableEvents {
            if let idx = event.backlogIndex {
                map[event.id] = idx
            }
        }
        return map
    }
}

// MARK: - Optimizer Preferences

/// User preferences that influence optimization weights.
struct OptimizerPreferences: Codable, Sendable {
    var focusBlockWeight: Double
    var pomodoroFitWeight: Double
    var conflictWeight: Double
    var taskPlacementWeight: Double
    var weekBalanceWeight: Double
    var energyCurveWeight: Double
    var multiPersonWeight: Double
    var breakWeight: Double
    var deadlineWeight: Double
    var contextSwitchWeight: Double
    var bufferWeight: Double
    var meetingClusteringWeight: Double
    var taskInclusionWeight: Double
    /// Weight for `BacklogOrderObjective`. Optional so existing persisted
    /// preferences (JSON blobs without this key) still decode cleanly — a
    /// missing value reads through the default below. Consumers should route
    /// through that default instead of force-unwrapping.
    var backlogOrderWeight: Double?

    /// Fallback when `backlogOrderWeight` is nil. Sized to match
    /// `taskPlacementWeight` (default 1.0) — backlog order is a
    /// first-class preference when the user asked to include the
    /// backlog, not a tiebreaker. At the previous 0.5 value a GA
    /// could save 5% of fitness via Buffer/ContextSwitch wins by
    /// violating three out of four desired-order pairs, which
    /// surfaced as "task 1 scheduled after tasks 2 and 3 on next
    /// week" patterns in the logs.
    static let defaultBacklogOrderWeight: Double = 1.5

    /// Weight for `DayCompactnessObjective`. Optional so existing
    /// persisted preferences decode cleanly without the key.
    var dayCompactnessWeight: Double?

    /// Fallback when `dayCompactnessWeight` is nil. Moderate — pulls
    /// same-day tasks together without overruling Buffer's "keep a
    /// few minutes between events" or BreakPlacement's hard break
    /// windows.
    static let defaultDayCompactnessWeight: Double = 0.5

    // Energy model
    /// Hours of day the user considers peak productivity windows.
    /// A single-element set models the classic "one peak" case;
    /// multi-element sets let users with split energy (e.g. morning
    /// + post-lunch) nudge the planner toward multiple windows.
    /// Invariant: never empty — UI and intent boundary enforce this.
    var peakEnergyHours: Set<Int>
    var energyDecayRate: Double       // how fast energy drops
    /// Personal energy curve from check-in data (24 values, 0…1 per hour).
    /// nil = use static Gaussian centred on peakEnergyHours.
    var personalEnergyCurve: [Double]?

    /// Representative single peak hour for callers that only accept one
    /// (e.g. `predictedCurve(defaultPeakHour:)`). Picks the earliest
    /// selected hour so it stays deterministic and matches the
    /// single-peak case exactly.
    var primaryPeakEnergyHour: Int {
        peakEnergyHours.min() ?? 10
    }

    /// Smallest absolute distance, in hours, from `hour` to any peak
    /// hour. Used by fitness objectives so multi-peak users get
    /// credit for scheduling near any of their productive windows.
    func peakEnergyDistance(from hour: Int) -> Int {
        peakEnergyHours.map { abs(hour - $0) }.min() ?? 0
    }

    /// Fractional-hour variant for callers that compute a Double hour
    /// (e.g. including minutes).
    func peakEnergyDistance(from hour: Double) -> Double {
        peakEnergyHours.map { abs(hour - Double($0)) }.min() ?? 0
    }

    // Break rules
    var maxConsecutiveMeetingMinutes: Int
    var minBreakMinutes: Int
    var lunchWindowStart: Int         // hour
    var lunchWindowEnd: Int           // hour

    // Buffer rules
    var defaultBufferMinutes: Int
    var heavyMeetingBufferMinutes: Int

    // Balance
    var maxMeetingsPerDay: Int
    var idealFocusBlockMinutes: Int

    // Meeting clustering
    var preferredClusterWindowStart: Int     // hour — meetings clustered after this
    var preferredClusterWindowEnd: Int       // hour — meetings clustered before this
    var maxMeetingsPerCluster: Int           // avoid marathon meeting blocks

    /// Weekdays on which the planner is allowed to place movable events.
    /// Uses Foundation's 1-indexed weekday convention
    /// (1 = Sunday, 2 = Monday, …, 7 = Saturday) so the values round-trip
    /// through `Calendar.component(.weekday, from:)` without translation.
    ///
    /// Default is Mon–Fri — matches the overwhelming common case and the
    /// original `skipWeekends = true` default this field replaced.
    /// Callers who want to allow Sat/Sun should set `Set(1...7)`.
    var workingDays: Set<Int>

    /// Default weekdays for a brand-new install / seed context. Mon–Fri.
    static let defaultWorkingDays: Set<Int> = [2, 3, 4, 5, 6]

    /// True iff `date`'s weekday is in `workingDays`. Every former
    /// weekend-aware check routes through this one helper so
    /// Mon/Wed/Fri-only or "work Saturdays" schedules behave
    /// correctly too — the planner simply follows the configured set.
    func isWorkingDay(_ date: Date, calendar: Calendar) -> Bool {
        workingDays.contains(calendar.component(.weekday, from: date))
    }

    init(
        focusBlockWeight: Double = 1.0,
        pomodoroFitWeight: Double = 0.8,
        conflictWeight: Double = 10.0,      // high penalty
        taskPlacementWeight: Double = 1.0,
        weekBalanceWeight: Double = 0.8,
        energyCurveWeight: Double = 0.9,
        multiPersonWeight: Double = 5.0,    // high priority
        breakWeight: Double = 1.2,
        deadlineWeight: Double = 3.0,       // important
        contextSwitchWeight: Double = 0.7,
        bufferWeight: Double = 0.6,
        meetingClusteringWeight: Double = 0.8,
        taskInclusionWeight: Double = 1.0,
        backlogOrderWeight: Double? = nil,
        dayCompactnessWeight: Double? = nil,
        peakEnergyHours: Set<Int> = [10],
        energyDecayRate: Double = 0.1,
        personalEnergyCurve: [Double]? = nil,
        maxConsecutiveMeetingMinutes: Int = 120,
        minBreakMinutes: Int = 10,
        lunchWindowStart: Int = 12,
        lunchWindowEnd: Int = 14,
        defaultBufferMinutes: Int = 5,
        heavyMeetingBufferMinutes: Int = 15,
        maxMeetingsPerDay: Int = 6,
        idealFocusBlockMinutes: Int = 120,
        preferredClusterWindowStart: Int = 9,
        preferredClusterWindowEnd: Int = 13,
        maxMeetingsPerCluster: Int = 4,
        workingDays: Set<Int> = OptimizerPreferences.defaultWorkingDays
    ) {
        self.focusBlockWeight = focusBlockWeight
        self.pomodoroFitWeight = pomodoroFitWeight
        self.conflictWeight = conflictWeight
        self.taskPlacementWeight = taskPlacementWeight
        self.weekBalanceWeight = weekBalanceWeight
        self.energyCurveWeight = energyCurveWeight
        self.multiPersonWeight = multiPersonWeight
        self.breakWeight = breakWeight
        self.deadlineWeight = deadlineWeight
        self.contextSwitchWeight = contextSwitchWeight
        self.bufferWeight = bufferWeight
        self.meetingClusteringWeight = meetingClusteringWeight
        self.taskInclusionWeight = taskInclusionWeight
        self.backlogOrderWeight = backlogOrderWeight
        self.dayCompactnessWeight = dayCompactnessWeight
        self.peakEnergyHours = peakEnergyHours
        self.energyDecayRate = energyDecayRate
        self.personalEnergyCurve = personalEnergyCurve
        self.maxConsecutiveMeetingMinutes = maxConsecutiveMeetingMinutes
        self.minBreakMinutes = minBreakMinutes
        self.lunchWindowStart = lunchWindowStart
        self.lunchWindowEnd = lunchWindowEnd
        self.defaultBufferMinutes = defaultBufferMinutes
        self.heavyMeetingBufferMinutes = heavyMeetingBufferMinutes
        self.maxMeetingsPerDay = maxMeetingsPerDay
        self.idealFocusBlockMinutes = idealFocusBlockMinutes
        self.preferredClusterWindowStart = preferredClusterWindowStart
        self.preferredClusterWindowEnd = preferredClusterWindowEnd
        self.maxMeetingsPerCluster = maxMeetingsPerCluster
        self.workingDays = workingDays
    }
}


// MARK: - Optimizer Result

/// The output of a single optimization run.
struct OptimizerResult: Sendable {
    let scenarios: [ScheduleScenario]
    let metadata: OptimizationMetadata
}

struct ScheduleScenario: Identifiable, Sendable {
    let id = UUID()
    let genes: [ScheduleGene]
    let fitness: Double
    let objectiveBreakdown: [String: Double]
    let constraintViolations: [String]

    /// Optimized task execution order within each day's Pomodoro blocks.
    /// Keys are day start dates (normalized via `Calendar.startOfDay(for:)`);
    /// values are event IDs in recommended order.
    /// Populated by `planDayWithSequencing` — nil when sequencing wasn't applied.
    var taskSequenceByDay: [Date: [String]]?

    /// Workload identity at the moment this scenario was produced.
    /// `BuboOptimizer.acceptScenario` / `rejectScenario` /
    /// `recordManualEdit` use this to route feedback into the
    /// correct per-workload learner bundle, even after subsequent
    /// optimizations on different workloads.
    /// `nil` for scenarios produced outside `BuboOptimizer` (e.g.
    /// hand-built fixtures).
    var sourceSignature: TaskSignature?

    /// Genes actively placed in the schedule (excludes dropped droppable genes).
    var activeGenes: [ScheduleGene] { genes.filter { $0.isIncluded } }

    /// Number of droppable tasks that the GA chose not to include.
    var droppedCount: Int { genes.count { !$0.isIncluded && $0.isDroppable } }

    /// Convert genes back to CalendarEvents for display.
    /// Only includes active genes; optimizer-generated events default to movable.
    func toCalendarEvents() -> [CalendarEvent] {
        activeGenes.map { gene in
            var event = CalendarEvent(
                id: gene.eventId,
                title: gene.title,
                startDate: gene.startTime,
                endDate: gene.endTime,
                location: nil,
                description: nil,
                calendarName: "Optimizer",
                eventType: gene.pomodoroConfig != nil ? .pomodoro : .standard
            )
            event.isMovable = true
            event.isTask = gene.storyPoints != nil
            event.pomodoroConfig = gene.pomodoroConfig
            event.storyPoints = gene.storyPoints
            return event
        }
    }
}

struct OptimizationMetadata: Sendable {
    let generations: Int
    let totalDuration: TimeInterval
    let bestFitness: Double
    let averageFitness: Double
    let convergenceGeneration: Int
}

// MARK: - User Feedback

/// Tracks user actions on optimizer suggestions for preference learning.
enum UserFeedback: Codable, Sendable {
    case accepted(scenarioFitness: Double, weights: [String: Double])
    case rejected(scenarioFitness: Double, weights: [String: Double])
    case modified(originalGenes: [ScheduleGene], editedGenes: [ScheduleGene], weights: [String: Double])
}
