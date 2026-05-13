import Foundation
import BuboDomain

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

