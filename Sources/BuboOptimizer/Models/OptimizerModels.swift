import Foundation
import BuboDomain

// MARK: - Optimizable Event
// Moved to `Sources/BuboDomain/Calendar/OptimizableEvent.swift` on 2026-05-12 to
// break the Domain ↔ Optimizer cycle (BacklogTask has a
// `toOptimizableEvent()` conversion).

// MARK: - Pomodoro Config
// Moved to `Sources/BuboDomain/Pomodoro/PomodoroConfig.swift` on 2026-05-12 to
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
public struct OptimizerContext: Sendable {
    public let fixedEvents: [CalendarEvent]
    public let movableEvents: [OptimizableEvent]
    public let workingHours: ClosedRange<Int>              // e.g. 9...18
    public let planningHorizon: DateInterval
    public let preferences: OptimizerPreferences
    public let participantAvailability: [String: [DateInterval]]  // participantId -> free slots
    public let calendar: Calendar
    public let rng: GARandom

    /// Adaptive operator selector. `ScheduleChromosome.mutate` consults
    /// this to pick a mutation operator per call instead of rolling
    /// uniformly. Shared across every mutation in a single run so the
    /// arm reward statistics accumulate.
    public let mutationBandit: MutationBandit

    /// Adaptive destroy-strategy selector for `MutationOperator.lnsDay`.
    /// Roulette-selects one of five ALNS destroy heuristics per LNS call;
    /// weights learn from per-call fitness deltas. Shared across islands
    /// same as `mutationBandit` so strategy rewards accumulate globally.
    public let lnsStrategyBandit: LNSStrategyBandit

    /// Second bandit for the repair half of the ALNS cycle — chooses
    /// between handwritten branch-and-bound, regret insertion, and the
    /// CP-SAT adapter per LNS call. Trained with the same fitness-delta
    /// signal as `lnsStrategyBandit`, so the combined policy converges on
    /// the destroy × repair pair that's best for the current landscape
    /// without having to enumerate all 15 pairs as independent arms.
    public let lnsRepairBandit: LNSRepairBandit

    /// Attention head for `CrossoverStrategy.contextual`. Contextual
    /// crossover scores every gene pair through this head before
    /// deciding which parent to inherit from. Shared across islands so
    /// the head's learnable weights absorb experience from every
    /// population.
    public let contextualCrossoverHead: GeneAttentionHead

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
    public let conflictGraphHolder: ConflictGraphHolder?

    /// Optional tabu memory consulted by LNS destroy when picking
    /// which events to rip out. When nil the destroy operators fall
    /// back to their original heuristic selection.
    public let tabuMemory: TabuMemory?

    /// Optional CP-SAT-style repair adapter. When supplied and the
    /// destroy window is at least `largeWindowThreshold` genes, the
    /// chromosome's `applyLNS` delegates to this stronger solver
    /// instead of the built-in handwritten branch-and-bound. nil =
    /// always use the built-in path.
    public let cpSATRepairer: CPSATRepairer?
    public let cpSATWindowThreshold: Int

    /// Lazy holder for the slot registry — the discrete search space
    /// the GA samples from. Built once per run and shared across every
    /// value-semantic copy of this context via the reference holder
    /// (same pattern as `conflictGraphHolder`). `ensureSlotRegistry()`
    /// builds on demand when the holder is nil, so legacy callers
    /// (tests, one-shot contexts) don't have to plumb one in.
    public let slotRegistryHolder: SlotRegistryHolder?

    /// Lazy holder for per-movable-event feasible slot domains. Each
    /// domain is the subset of registry indices that satisfy the
    /// event's static constraints (earliestStart, deadline,
    /// working-hours fit, duration-aware fixed-event non-overlap) and
    /// is consulted by mutation operators to sample from a
    /// pre-filtered set instead of recomputing
    /// `SlotRegistry.allowedIndices` and the overlap scan per call.
    /// `ensureSlotDomains()` builds on demand when the holder is nil,
    /// matching `slotRegistryHolder`'s lazy-build contract.
    public let slotDomainsHolder: SlotDomainsHolder?

    public init(
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
    public func ensureConflictGraph() -> ScheduleConflictGraph {
        if let holder = conflictGraphHolder {
            return holder.get(for: self)
        }
        return ScheduleConflictGraph.build(from: self)
    }

    /// Returns the precomputed slot registry. Goes through the shared
    /// holder on the production path; callers without a holder (tests,
    /// legacy one-shot contexts) get an inline build on first access.
    /// Same pattern as `ensureConflictGraph`.
    public func ensureSlotRegistry() -> SlotRegistry {
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
    public func ensureSlotDomain(for eventId: String) -> SlotDomain {
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
    public func backlogIndexMap() -> [String: Int] {
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
public struct OptimizerPreferences: Codable, Sendable {
    public var focusBlockWeight: Double
    public var pomodoroFitWeight: Double
    public var conflictWeight: Double
    public var taskPlacementWeight: Double
    public var weekBalanceWeight: Double
    public var energyCurveWeight: Double
    public var multiPersonWeight: Double
    public var breakWeight: Double
    public var deadlineWeight: Double
    public var contextSwitchWeight: Double
    public var bufferWeight: Double
    public var meetingClusteringWeight: Double
    public var taskInclusionWeight: Double
    /// Weight for `BacklogOrderObjective`. Optional so existing persisted
    /// preferences (JSON blobs without this key) still decode cleanly — a
    /// missing value reads through the default below. Consumers should route
    /// through that default instead of force-unwrapping.
    public var backlogOrderWeight: Double?

    /// Fallback when `backlogOrderWeight` is nil. Sized to match
    /// `taskPlacementWeight` (default 1.0) — backlog order is a
    /// first-class preference when the user asked to include the
    /// backlog, not a tiebreaker. At the previous 0.5 value a GA
    /// could save 5% of fitness via Buffer/ContextSwitch wins by
    /// violating three out of four desired-order pairs, which
    /// surfaced as "task 1 scheduled after tasks 2 and 3 on next
    /// week" patterns in the logs.
    public static let defaultBacklogOrderWeight: Double = 1.5

    /// Weight for `DayCompactnessObjective`. Optional so existing
    /// persisted preferences decode cleanly without the key.
    public var dayCompactnessWeight: Double?

    /// Fallback when `dayCompactnessWeight` is nil. Moderate — pulls
    /// same-day tasks together without overruling Buffer's "keep a
    /// few minutes between events" or BreakPlacement's hard break
    /// windows.
    public static let defaultDayCompactnessWeight: Double = 0.5

    // Energy model
    /// Hours of day the user considers peak productivity windows.
    /// A single-element set models the classic "one peak" case;
    /// multi-element sets let users with split energy (e.g. morning
    /// + post-lunch) nudge the planner toward multiple windows.
    /// Invariant: never empty — UI and intent boundary enforce this.
    public var peakEnergyHours: Set<Int>
    public var energyDecayRate: Double       // how fast energy drops
    /// Personal energy curve from check-in data (24 values, 0…1 per hour).
    /// nil = use static Gaussian centred on peakEnergyHours.
    public var personalEnergyCurve: [Double]?

    /// Representative single peak hour for callers that only accept one
    /// (e.g. `predictedCurve(defaultPeakHour:)`). Picks the earliest
    /// selected hour so it stays deterministic and matches the
    /// single-peak case exactly.
    public var primaryPeakEnergyHour: Int {
        peakEnergyHours.min() ?? 10
    }

    /// Smallest absolute distance, in hours, from `hour` to any peak
    /// hour. Used by fitness objectives so multi-peak users get
    /// credit for scheduling near any of their productive windows.
    public func peakEnergyDistance(from hour: Int) -> Int {
        peakEnergyHours.map { abs(hour - $0) }.min() ?? 0
    }

    /// Fractional-hour variant for callers that compute a Double hour
    /// (e.g. including minutes).
    public func peakEnergyDistance(from hour: Double) -> Double {
        peakEnergyHours.map { abs(hour - Double($0)) }.min() ?? 0
    }

    // Break rules
    public var maxConsecutiveMeetingMinutes: Int
    public var minBreakMinutes: Int
    public var lunchWindowStart: Int         // hour
    public var lunchWindowEnd: Int           // hour

    // Buffer rules
    public var defaultBufferMinutes: Int
    public var heavyMeetingBufferMinutes: Int

    // Balance
    public var maxMeetingsPerDay: Int
    public var idealFocusBlockMinutes: Int

    // Meeting clustering
    public var preferredClusterWindowStart: Int     // hour — meetings clustered after this
    public var preferredClusterWindowEnd: Int       // hour — meetings clustered before this
    public var maxMeetingsPerCluster: Int           // avoid marathon meeting blocks

    /// Weekdays on which the planner is allowed to place movable events.
    /// Uses Foundation's 1-indexed weekday convention
    /// (1 = Sunday, 2 = Monday, …, 7 = Saturday) so the values round-trip
    /// through `Calendar.component(.weekday, from:)` without translation.
    ///
    /// Default is Mon–Fri — matches the overwhelming common case and the
    /// original `skipWeekends = true` default this field replaced.
    /// Callers who want to allow Sat/Sun should set `Set(1...7)`.
    public var workingDays: Set<Int>

    /// Default weekdays for a brand-new install / seed context. Mon–Fri.
    public static let defaultWorkingDays: Set<Int> = [2, 3, 4, 5, 6]

    /// True iff `date`'s weekday is in `workingDays`. Every former
    /// weekend-aware check routes through this one helper so
    /// Mon/Wed/Fri-only or "work Saturdays" schedules behave
    /// correctly too — the planner simply follows the configured set.
    public func isWorkingDay(_ date: Date, calendar: Calendar) -> Bool {
        workingDays.contains(calendar.component(.weekday, from: date))
    }

    public init(
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
public struct OptimizerResult: Sendable {

    public init(
        scenarios: [ScheduleScenario],
        metadata: OptimizationMetadata
    ) {
        self.scenarios = scenarios
        self.metadata = metadata
    }

    public let scenarios: [ScheduleScenario]
    public let metadata: OptimizationMetadata
}

public struct ScheduleScenario: Identifiable, Sendable {

    public init(
        genes: [ScheduleGene],
        fitness: Double,
        objectiveBreakdown: [String: Double],
        constraintViolations: [String],
        taskSequenceByDay: [Date: [String]]? = nil,
        sourceSignature: TaskSignature? = nil
    ) {
        self.genes = genes
        self.fitness = fitness
        self.objectiveBreakdown = objectiveBreakdown
        self.constraintViolations = constraintViolations
        self.taskSequenceByDay = taskSequenceByDay
        self.sourceSignature = sourceSignature
    }

    public let id = UUID()
    public let genes: [ScheduleGene]
    public let fitness: Double
    public let objectiveBreakdown: [String: Double]
    public let constraintViolations: [String]

    /// Optimized task execution order within each day's Pomodoro blocks.
    /// Keys are day start dates (normalized via `Calendar.startOfDay(for:)`);
    /// values are event IDs in recommended order.
    /// Populated by `planDayWithSequencing` — nil when sequencing wasn't applied.
    public var taskSequenceByDay: [Date: [String]]?

    /// Workload identity at the moment this scenario was produced.
    /// `BuboOptimizer.acceptScenario` / `rejectScenario` /
    /// `recordManualEdit` use this to route feedback into the
    /// correct per-workload learner bundle, even after subsequent
    /// optimizations on different workloads.
    /// `nil` for scenarios produced outside `BuboOptimizer` (e.g.
    /// hand-built fixtures).
    public var sourceSignature: TaskSignature?

    /// Genes actively placed in the schedule (excludes dropped droppable genes).
    public var activeGenes: [ScheduleGene] { genes.filter { $0.isIncluded } }

    /// Number of droppable tasks that the GA chose not to include.
    public var droppedCount: Int { genes.count { !$0.isIncluded && $0.isDroppable } }

    /// Convert genes back to CalendarEvents for display.
    /// Only includes active genes; optimizer-generated events default to movable.
    public func toCalendarEvents() -> [CalendarEvent] {
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

public struct OptimizationMetadata: Sendable {

    public init(
        generations: Int,
        totalDuration: TimeInterval,
        bestFitness: Double,
        averageFitness: Double,
        convergenceGeneration: Int
    ) {
        self.generations = generations
        self.totalDuration = totalDuration
        self.bestFitness = bestFitness
        self.averageFitness = averageFitness
        self.convergenceGeneration = convergenceGeneration
    }

    public let generations: Int
    public let totalDuration: TimeInterval
    public let bestFitness: Double
    public let averageFitness: Double
    public let convergenceGeneration: Int
}

// MARK: - User Feedback

/// Tracks user actions on optimizer suggestions for preference learning.
public enum UserFeedback: Codable, Sendable {
    case accepted(scenarioFitness: Double, weights: [String: Double])
    case rejected(scenarioFitness: Double, weights: [String: Double])
    case modified(originalGenes: [ScheduleGene], editedGenes: [ScheduleGene], weights: [String: Double])
}
