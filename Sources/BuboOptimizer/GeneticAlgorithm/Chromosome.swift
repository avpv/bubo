import Foundation
import simd

// MARK: - Schedule Chromosome

/// A chromosome representing a complete schedule assignment.
/// Each gene maps one movable event to a specific time slot.
public struct ScheduleChromosome: Chromosome, AdaptiveMutationChromosome, Sendable {

    public init(
        genes: [ScheduleGene],
        fitness: Double = 0.0,
        rawFitness: Double = 0.0,
        isFitnessReal: Bool = false,
        needsEvaluation: Bool = true,
        objectiveCache: [String: Double]? = nil,
        perDayObjectiveCache: [String: [Date: Double]]? = nil,
        perComponentObjectiveCache: [String: [Int: Double]]? = nil,
        geneDaysSnapshot: [Date]? = nil,
        mutatedGeneIndices: IndexSet? = nil,
        lastMutationOperator: MutationOperator? = nil,
        lastDestroyStrategy: LNSDestroyStrategy? = nil,
        lastRepairStrategy: LNSRepairStrategy? = nil,
        selfAdaptiveMutationRate: Double = 0,
        cachedFeatures: ContiguousArray<Double>? = nil
    ) {
        self.genes = genes
        self.fitness = fitness
        self.rawFitness = rawFitness
        self.isFitnessReal = isFitnessReal
        self.needsEvaluation = needsEvaluation
        self.objectiveCache = objectiveCache
        self.perDayObjectiveCache = perDayObjectiveCache
        self.perComponentObjectiveCache = perComponentObjectiveCache
        self.geneDaysSnapshot = geneDaysSnapshot
        self.mutatedGeneIndices = mutatedGeneIndices
        self.lastMutationOperator = lastMutationOperator
        self.lastDestroyStrategy = lastDestroyStrategy
        self.lastRepairStrategy = lastRepairStrategy
        self.selfAdaptiveMutationRate = selfAdaptiveMutationRate
        self.cachedFeatures = cachedFeatures
    }

    public var genes: [ScheduleGene]
    public var fitness: Double = 0.0
    public var rawFitness: Double = 0.0

    /// True iff `fitness`/`rawFitness` were produced by the real
    /// `FitnessEvaluator` (or an equally-faithful evaluator like
    /// `StabilityEvaluator`). False when the value is a surrogate
    /// prediction from `MultiFidelityEvaluator` tier-1 or the
    /// surrogate-assisted per-chromosome screen. Anything the GA emits
    /// externally — archived scenarios, metadata, `bestEver` at
    /// shutdown — must have this flag true; callers that need that
    /// guarantee should force `FitnessEvaluator.evaluateAndAssign`
    /// when the flag is false.
    ///
    /// The invariant is deliberately one-way: a surrogate write sets
    /// it to false, a real write sets it to true, and no code reads
    /// the flag during selection/elitism — the multi-fidelity funnel
    /// intentionally ranks on mixed signals to amortize evaluation
    /// cost. The flag is a boundary contract, not a ranking input.
    public var isFitnessReal: Bool = false

    /// Tracks whether this chromosome needs fitness re-evaluation.
    /// Set to true on creation, crossover, and mutation; cleared after evaluation.
    public var needsEvaluation: Bool = true

    /// Cached per-objective scores for incremental evaluation.
    /// Populated after full evaluation; reused when only a subset of genes change.
    public var objectiveCache: [String: Double]?

    /// Per-day breakdown for `DayPartitionedObjective` instances. Keys are
    /// objective names; values are `[dayStart: dayScore]`. When delta evaluation
    /// runs, only days that contain mutated genes (or used to, before the
    /// mutation) are rescored — unaffected days are read from this cache.
    public var perDayObjectiveCache: [String: [Date: Double]]?

    /// Per-component breakdown for `ComponentPartitionedObjective`
    /// instances. Outer key = objective name; inner key = component
    /// index from `ScheduleConflictGraph.componentOf`. Components that
    /// don't contain any mutated gene keep their cached score across
    /// delta evaluations.
    public var perComponentObjectiveCache: [String: [Int: Double]]?

    /// For each gene position, the day it sat on the last time this chromosome
    /// was fully evaluated. Used to spot "a gene moved from day X to day Y"
    /// and mark both X and Y as dirty, so per-day delta evaluation doesn't
    /// leave stale scores on abandoned days. `nil` means "no prior evaluation"
    /// and forces a full pass.
    public var geneDaysSnapshot: [Date]?

    /// Indices of genes that were modified since last evaluation.
    /// Used by delta evaluation to skip recomputing unaffected local objectives.
    public var mutatedGeneIndices: IndexSet?

    /// The operator picked by the `MutationBandit` on the last `mutate()`
    /// call. The GA loop reads this post-evaluation to attribute the
    /// fitness delta back to the operator, closing the LinUCB feedback
    /// loop. `nil` only on freshly-constructed chromosomes whose
    /// `mutate()` has not yet run. Does not participate in
    /// equality/hashing.
    public var lastMutationOperator: MutationOperator?

    /// The destroy strategy used on the most recent LNS call. `nil` when
    /// `lastMutationOperator != .lnsDay`. The GA loop reads this to feed
    /// `LNSStrategyBandit` the same fitness delta that went to the
    /// operator-level bandit, so strategy weights adapt with experience.
    public var lastDestroyStrategy: LNSDestroyStrategy?

    /// Repair half of the ALNS pair. Siblings `lastMutationOperator` and
    /// `lastDestroyStrategy` — the GA loop feeds the same fitness delta
    /// into `LNSRepairBandit` so both ends of the destroy × repair pair
    /// get trained on the same signal.
    public var lastRepairStrategy: LNSRepairStrategy?

    /// Self-adaptive mutation rate encoded directly in the genome. When > 0
    /// it overrides the rate the GA would otherwise pass to `mutate(rate:)`,
    /// and is itself perturbed on every mutation — so a chromosome descended
    /// from individuals that benefited from higher rates will keep mutating
    /// aggressively, and vice versa. 0 = disabled (the GA's externally-set
    /// rate wins, preserving pre-existing behaviour).
    public var selfAdaptiveMutationRate: Double = 0

    /// Cached 16-dim feature vector for surrogate / QD consumers.
    /// Populated lazily on first extraction and invalidated on any
    /// mutation (`mutate`) or repair that changes gene placement.
    /// Surrogate screening hits this cache for every offspring
    /// evaluation — eliminating the re-aggregation pass saves ~10-30µs
    /// per offspring, multiplied by generations × populationSize this
    /// is a meaningful slice of the per-run cost.
    public var cachedFeatures: ContiguousArray<Double>?

    /// Equality ignores needsEvaluation and caches — two chromosomes with the same genes and fitness are equal.
    public static func == (lhs: ScheduleChromosome, rhs: ScheduleChromosome) -> Bool {
        lhs.genes == rhs.genes && lhs.fitness == rhs.fitness
    }

    /// Hash the same fields used by `==`. Keeping this in sync with equality is
    /// a Hashable invariant; `fitness` is quantized to 4 decimal places so
    /// float noise between otherwise-identical chromosomes doesn't produce
    /// accidental hash divergence that would defeat duplicate detection.
    public func hash(into hasher: inout Hasher) {
        hasher.combine(genes)
        hasher.combine(Int64((fitness * 10_000).rounded()))
    }

    // MARK: - Slot-Based Decoder — Implementation
    //
    // The GA's discrete search space is the `SlotRegistry` stored on
    // `OptimizerContext.slotRegistryHolder` (built lazily via
    // `ensureSlotRegistry()`). Every valid 15-min start in the
    // horizon — intersected with `workingDays`, `workingHours`, and
    // minus fixed-event blocks — becomes a single integer index.
    // `ScheduleGene.slotIndex: Int?` carries that index alongside the
    // continuous `startTime: Date` during the dual-storage migration:
    //
    //   * Seeders (`random`, `greedyWithOrder`, `cpSeeded`) populate
    //     `slotIndex` via `registry.nearestIndex(to:)` after each
    //     placement. New chromosomes land in the registry by
    //     construction.
    //   * Mutations (shift/moveDay/snap/guided) operate on
    //     `slotIndex` with integer arithmetic (clamp, random-in-
    //     range, nearest) and re-derive `startTime` from the
    //     registry. The legacy Date fallback stays only for empty
    //     registries (degenerate horizons, tests) and gene ancestors
    //     that haven't been re-seeded yet.
    //   * Crossover inherits placement via `withPlacement(from:)`,
    //     which copies both `startTime` and `slotIndex` so slot
    //     bindings survive parent-to-child transfer.
    //   * Repair re-binds `slotIndex` after every relocation
    //     (`withSlot(index:date:)`) so the gene's two fields never
    //     drift.
    //
    // The continuous `Date` side of the dual storage stays because
    // dozens of readers — fitness objectives, constraints, UI,
    // apply-to-calendar, serialisation, LNS occupied-interval math —
    // still consume `startTime` directly. Making `startTime` a
    // computed property over `slotIndex` + registry would touch
    // every one of those sites and is the follow-up step: once a
    // local CI run confirms the dual path is stable, `startTime`
    // flips to computed and `slotIndex` becomes the sole stored
    // field — the full `Int`-only decoder described in the original
    // review.
    //
    // Invariants held by all operators above:
    //   1. When `slotIndex` is non-nil, `startTime == registry.slots[slotIndex]`.
    //   2. No code path introduces a `startTime` off the 15-min grid.
    //   3. `withStartTime(_:)` invalidates `slotIndex` (nil) so
    //      callers must explicitly re-bind via the registry when
    //      they want slot-aware behaviour — no silent sync drift.


}
