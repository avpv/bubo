import Foundation

// MARK: - Fitness Objective Protocol

/// A single objective function that scores a schedule chromosome.
/// Higher scores = better. All scores are normalized to [0, 1].
protocol FitnessObjective {
    var name: String { get }
    var weight: Double { get set }

    /// Evaluate the objective for a chromosome. Returns a score in [0, 1].
    func evaluate(chromosome: ScheduleChromosome, context: OptimizerContext) -> Double
}

// MARK: - Day-Partitioned Objective

/// An objective that naturally decomposes into independent per-day scores.
///
/// `BreakObjective`, `BufferObjective`, and similar aggregate-per-day
/// objectives conform so the evaluator can rescore only the days touched by a
/// mutation instead of the whole horizon. Huge savings on weekly planning
/// runs where a single mutation typically disturbs one day out of seven.
///
/// Non-conforming objectives (global structure, event-level) fall back to the
/// full-evaluation path — no correctness difference, just a missed speedup.
protocol DayPartitionedObjective: FitnessObjective {
    /// Evaluate every populated day. Keys are `calendar.startOfDay(for:)` dates.
    func evaluatePerDay(
        chromosome: ScheduleChromosome,
        context: OptimizerContext
    ) -> [Date: Double]

    /// Evaluate a single day — the fast path for delta evaluation. The
    /// default just re-runs `evaluatePerDay` and picks the requested entry;
    /// conformers are expected to override with a scoped implementation
    /// that only visits that day's genes. Without the override, no speedup
    /// is realized over full evaluation.
    func evaluateOneDay(
        day: Date,
        chromosome: ScheduleChromosome,
        context: OptimizerContext
    ) -> Double

    /// Reduce the per-day scores to a scalar fitness in [0, 1]. Default:
    /// arithmetic mean, with an empty-day fallback of 1.0 to match the
    /// existing objectives' behaviour.
    func combinePerDay(_ perDay: [Date: Double]) -> Double
}

extension DayPartitionedObjective {
    func evaluateOneDay(
        day: Date,
        chromosome: ScheduleChromosome,
        context: OptimizerContext
    ) -> Double {
        evaluatePerDay(chromosome: chromosome, context: context)[day] ?? 1.0
    }

    func combinePerDay(_ perDay: [Date: Double]) -> Double {
        guard !perDay.isEmpty else { return 1.0 }
        return perDay.values.reduce(0, +) / Double(perDay.count)
    }
}

// MARK: - Component-Partitioned Objective

/// An objective whose score decomposes into independent per-component
/// scores, where "component" is a weakly-connected component of the
/// `ScheduleConflictGraph`. Two genes in different components can
/// never structurally affect each other's contribution — so a
/// mutation that only touches component A doesn't require rescoring
/// component B.
///
/// Unlike `DayPartitionedObjective`, partitioning here is driven by
/// graph structure rather than the calendar. The two axes compose
/// orthogonally: an objective can conform to both and the evaluator
/// will pick whichever decomposition is cheaper for the current
/// mutation (component-level when the hit set is small; day-level
/// when a day-wide recompute is anyway needed).
protocol ComponentPartitionedObjective: FitnessObjective {
    /// Score a single component (identified by an array of event IDs).
    /// Implementations must read *only* genes whose `eventId` is in
    /// `componentMembers`; touching other genes silently defeats the
    /// cache.
    func evaluateComponent(
        members: [String],
        chromosome: ScheduleChromosome,
        context: OptimizerContext
    ) -> Double

    /// Reduce per-component scores into a scalar fitness in [0, 1].
    /// Default: arithmetic mean, with an empty-component fallback of
    /// 1.0 so workloads without any structural coupling score
    /// neutrally.
    func combineComponents(_ perComponent: [Int: Double]) -> Double
}

extension ComponentPartitionedObjective {
    func combineComponents(_ perComponent: [Int: Double]) -> Double {
        guard !perComponent.isEmpty else { return 1.0 }
        return perComponent.values.reduce(0, +) / Double(perComponent.count)
    }

    /// Default global evaluation: walk every component and combine.
    /// Objectives that only conform to the component protocol get a
    /// working `evaluate(chromosome:context:)` for free via this.
    func evaluate(chromosome: ScheduleChromosome, context: OptimizerContext) -> Double {
        let graph = context.ensureConflictGraph()
        let components = graph.allComponents()
        guard !components.isEmpty else { return 1.0 }
        var perComponent: [Int: Double] = [:]
        for (idx, members) in components.enumerated() {
            perComponent[idx] = evaluateComponent(
                members: members, chromosome: chromosome, context: context
            )
        }
        return combineComponents(perComponent)
    }
}

// MARK: - Fitness Evaluator

/// Combines multiple objectives into a single weighted fitness score.
/// Also applies constraint penalties.
/// Thread safety: a fresh evaluator is created per optimization run.
/// Weights are set before the GA starts and not mutated during evolution.
final class FitnessEvaluator: @unchecked Sendable {
    var objectives: [any FitnessObjective]
    let constraintEngine: ConstraintEngine

    /// Optional population-level memoization. When set, `evaluateAndAssign`
    /// consults the cache before calling objectives; crossover/mutation-
    /// generated duplicates (20-40% of offspring on fast configs) return
    /// immediately. `nil` = caching disabled, e.g. for ad-hoc evaluation
    /// calls from UI code paths where duplicates are unlikely.
    let cache: FitnessCache?

    init(
        objectives: [any FitnessObjective],
        constraintEngine: ConstraintEngine = .standard,
        cache: FitnessCache? = nil
    ) {
        self.objectives = objectives
        self.constraintEngine = constraintEngine
        self.cache = cache
    }

    /// All default objectives with weights from preferences.
    /// Creates a fresh `FitnessCache` per evaluator instance so cache scope
    /// matches run scope — different contexts (fixedEvents, preferences)
    /// produce different fitness for the same fingerprint.
    static func standard(preferences: OptimizerPreferences) -> FitnessEvaluator {
        FitnessEvaluator(
            objectives: [
                FocusBlockObjective(weight: preferences.focusBlockWeight),
                PomodoroFitObjective(weight: preferences.pomodoroFitWeight),
                ConflictObjective(weight: preferences.conflictWeight),
                TaskPlacementObjective(weight: preferences.taskPlacementWeight),
                WeekBalanceObjective(weight: preferences.weekBalanceWeight),
                EnergyCurveObjective(weight: preferences.energyCurveWeight),
                MultiPersonObjective(weight: preferences.multiPersonWeight),
                BreakObjective(weight: preferences.breakWeight),
                DeadlineObjective(weight: preferences.deadlineWeight),
                ContextSwitchObjective(weight: preferences.contextSwitchWeight),
                BufferObjective(weight: preferences.bufferWeight),
                MeetingClusteringObjective(weight: preferences.meetingClusteringWeight),
                TaskInclusionObjective(weight: preferences.taskInclusionWeight),
                PrecedenceObjective(weight: 0.6),
            ],
            constraintEngine: .standard,
            cache: FitnessCache()
        )
    }

    // MARK: - Objective Classification
    //
    // Delta-eval capability is now discovered at runtime via
    // `objective as? DayPartitionedObjective`; explicit classification
    // lists would immediately rot as new objectives opt in. The following
    // objectives conform today:
    //   BreakPlacement, Buffer  — original two.
    //   FocusBlock, ContextSwitch, MeetingClustering — converted when
    //     delta-evaluation was extended in the NSGA-III rewrite.
    // Remaining objectives (Conflict, PomodoroFit, TaskPlacement,
    // WeekBalance, MultiPerson, EnergyBalance, Deadline, TaskInclusion)
    // stay global because their scores depend on cross-day structure or
    // properties that don't decompose cleanly per day.

    // MARK: - Evaluation

    /// Compute the total fitness for a chromosome.
    /// Returns a value in [0, 1] — 0 = completely infeasible, 1 = perfect.
    func evaluate(chromosome: ScheduleChromosome, context: OptimizerContext) -> Double {
        // Hard constraint check — infeasible solutions get near-zero fitness
        // but we still give a tiny gradient based on violation magnitude
        // so the GA can evolve toward feasibility.
        if !constraintEngine.isValid(chromosome, context: context) {
            // Only use hard constraint penalties for the gradient (not soft)
            let hardPenalty = constraintEngine.constraints
                .filter { $0.isHard }
                .reduce(0.0) { $0 + $1.penalty(for: chromosome, context: context) }
            // Map penalty to (0, 0.09] — lower penalty = closer to 0.09
            // Ceiling at 0.09 ensures infeasible < feasible (which starts at 0.1)
            return 0.09 / (1.0 + hardPenalty * 0.01)
        }

        // Soft constraint penalty (only from soft constraints, already validated hard ones)
        let softPenalty = constraintEngine.constraints
            .filter { !$0.isHard }
            .reduce(0.0) { $0 + $1.penalty(for: chromosome, context: context) }

        // Compute weighted objective sum
        let totalWeight = objectives.reduce(0.0) { $0 + $1.weight }
        guard totalWeight > 0 else { return 0.1 }

        var weightedSum = 0.0
        for objective in objectives {
            let score = max(0, min(1, objective.evaluate(chromosome: chromosome, context: context)))
            weightedSum += score * objective.weight
        }

        let normalizedScore = weightedSum / totalWeight  // [0, 1]

        // Soft penalty reduces score multiplicatively
        let penaltyFactor = 1.0 / (1.0 + softPenalty * 0.01)

        // Feasible solutions: [0.1, 1.0] — always above infeasible ceiling of 0.09
        return 0.1 + normalizedScore * penaltyFactor * 0.9
    }

    /// Evaluate and assign fitness to a chromosome (mutating).
    /// Skips evaluation if the chromosome hasn't changed since last evaluation.
    ///
    /// Evaluation proceeds through three tiers, cheapest first:
    ///   1. `needsEvaluation == false` → already scored, nothing to do.
    ///   2. `FitnessCache` hit → reuse the stored score for an identical
    ///      fingerprint seen earlier in the run.
    ///   3. Fall through to delta or full evaluation; delta recomputes only
    ///      dirty days for `DayPartitionedObjective`s. Result is memoized.
    func evaluateAndAssign(_ chromosome: inout ScheduleChromosome, context: OptimizerContext) {
        guard chromosome.needsEvaluation else { return }

        // Tier 2: cache probe. Only worthwhile if cache is wired.
        if let cache = cache {
            let key = ChromosomeFingerprint(chromosome.genes)
            if let hit = cache.lookup(key) {
                chromosome.fitness = hit.fitness
                chromosome.rawFitness = hit.fitness
                chromosome.objectiveCache = hit.objectiveCache
                // Drop per-day cache: the hit's scalar cache is authoritative
                // but we don't memoize per-day inside FitnessCache (would bloat
                // the cache without helping). Next delta eval will fall back
                // to full for day-partitioned objectives, which is still cheap
                // because they individually only scan per-day events.
                chromosome.perDayObjectiveCache = nil
                chromosome.geneDaysSnapshot = nil
                chromosome.mutatedGeneIndices = nil
                chromosome.needsEvaluation = false
                return
            }
        }

        // Tier 3: evaluate (delta-where-possible) and memoize.
        let result = evaluateDelta(
            chromosome: chromosome,
            context: context
        )
        chromosome.fitness = result.fitness
        chromosome.rawFitness = result.fitness
        chromosome.objectiveCache = result.objectiveCache
        chromosome.perDayObjectiveCache = result.perDayCache
        chromosome.geneDaysSnapshot = result.geneDaysSnapshot
        chromosome.mutatedGeneIndices = nil
        chromosome.needsEvaluation = false

        if let cache = cache {
            let key = ChromosomeFingerprint(chromosome.genes)
            cache.store(
                key,
                entry: FitnessCache.Entry(fitness: result.fitness, objectiveCache: result.objectiveCache)
            )
        }
    }

    /// Result of a (delta or full) evaluation.
    struct EvaluationResult {
        let fitness: Double
        let objectiveCache: [String: Double]
        let perDayCache: [String: [Date: Double]]
        let geneDaysSnapshot: [Date]
    }

    /// Delta-aware evaluation. When the caller supplied a usable prior cache
    /// and an index hint, `DayPartitionedObjective` instances rescore only
    /// days that contain mutated genes or that used to contain them. Other
    /// objectives always recompute in full — that's intentional: the current
    /// classification table in this file doesn't yet describe their gene
    /// dependencies precisely enough to safely skip them, and miscached
    /// scalars would silently degrade fitness quality.
    ///
    /// Returning the `geneDaysSnapshot` lets the caller install it on the
    /// chromosome; the next delta eval uses it to detect "moved day" cases
    /// (gene was on day X before mutation, now on day Y → both are dirty).
    func evaluateDelta(
        chromosome: ScheduleChromosome,
        context: OptimizerContext
    ) -> EvaluationResult {
        let cal = context.calendar
        let currentGeneDays = chromosome.genes.map { cal.startOfDay(for: $0.startTime) }

        // Hard constraint check short-circuits delta pathways. Infeasible
        // solutions get the same tiny gradient as in the non-delta path;
        // the caches are returned unchanged so the next delta eval can
        // resume where it left off if the mutation fixes the violation.
        if !constraintEngine.isValid(chromosome, context: context) {
            let hardPenalty = constraintEngine.constraints
                .filter { $0.isHard }
                .reduce(0.0) { $0 + $1.penalty(for: chromosome, context: context) }
            let fitness = 0.09 / (1.0 + hardPenalty * 0.01)
            return EvaluationResult(
                fitness: fitness,
                objectiveCache: chromosome.objectiveCache ?? [:],
                perDayCache: chromosome.perDayObjectiveCache ?? [:],
                geneDaysSnapshot: currentGeneDays
            )
        }

        let softPenalty = constraintEngine.constraints
            .filter { !$0.isHard }
            .reduce(0.0) { $0 + $1.penalty(for: chromosome, context: context) }

        let totalWeight = objectives.reduce(0.0) { $0 + $1.weight }
        guard totalWeight > 0 else {
            return EvaluationResult(
                fitness: 0.1,
                objectiveCache: [:],
                perDayCache: [:],
                geneDaysSnapshot: currentGeneDays
            )
        }

        // Can we delta-evaluate day-partitioned objectives?
        //
        // We need all three:
        //   - prior perDay cache exists (we have something to reuse)
        //   - prior geneDays snapshot exists (we can compute the moved-day set)
        //   - mutatedGeneIndices is set (we know which genes might have moved)
        //   - snapshot length matches current gene count (no insertion/deletion)
        //
        // Missing any piece drops us to full per-day evaluation for the
        // partitioned objectives (still correct, just slower).
        let canDeltaPerDay = chromosome.perDayObjectiveCache != nil
            && chromosome.geneDaysSnapshot != nil
            && chromosome.geneDaysSnapshot?.count == chromosome.genes.count
            && (chromosome.mutatedGeneIndices?.isEmpty == false)

        let dirtyDays: Set<Date>?
        if canDeltaPerDay,
           let prevDays = chromosome.geneDaysSnapshot,
           let mutated = chromosome.mutatedGeneIndices {
            var dirty = Set<Date>()
            for idx in mutated {
                guard idx < currentGeneDays.count, idx < prevDays.count else {
                    // Shouldn't happen given the length check, but defensive
                    // so we don't index-trap on a partially-mutated clone.
                    dirty = Set(currentGeneDays)
                    break
                }
                dirty.insert(currentGeneDays[idx])
                dirty.insert(prevDays[idx])
            }
            dirtyDays = dirty
        } else {
            dirtyDays = nil
        }

        var scalarCache: [String: Double] = [:]
        var perDayCache: [String: [Date: Double]] = [:]
        var weightedSum = 0.0

        for objective in objectives {
            let score: Double

            if let partitioned = objective as? DayPartitionedObjective {
                // Day-partitioned: evaluate only dirty days, read the rest
                // from the per-day cache.
                let newPerDay = evaluatePerDayWithDelta(
                    objective: partitioned,
                    chromosome: chromosome,
                    context: context,
                    previousPerDay: chromosome.perDayObjectiveCache?[objective.name],
                    dirtyDays: dirtyDays
                )
                let combined = partitioned.combinePerDay(newPerDay)
                score = max(0, min(1, combined))
                perDayCache[objective.name] = newPerDay
            } else {
                // Non-partitioned: always recompute. No safe way to know
                // which genes this objective depends on without a full
                // dependency model, and a stale cached score would corrupt
                // the fitness landscape the GA is climbing.
                score = max(0, min(1, objective.evaluate(chromosome: chromosome, context: context)))
            }

            scalarCache[objective.name] = score
            weightedSum += score * objective.weight
        }

        let normalizedScore = weightedSum / totalWeight
        let penaltyFactor = 1.0 / (1.0 + softPenalty * 0.01)
        let fitness = 0.1 + normalizedScore * penaltyFactor * 0.9

        return EvaluationResult(
            fitness: fitness,
            objectiveCache: scalarCache,
            perDayCache: perDayCache,
            geneDaysSnapshot: currentGeneDays
        )
    }

    /// For a `DayPartitionedObjective`, compute the new per-day map by
    /// reusing the previous scores for clean days and asking the objective
    /// to rescore only dirty days. When no prior cache or no dirty-day hint
    /// exists, falls back to a full per-day scan.
    private func evaluatePerDayWithDelta(
        objective: DayPartitionedObjective,
        chromosome: ScheduleChromosome,
        context: OptimizerContext,
        previousPerDay: [Date: Double]?,
        dirtyDays: Set<Date>?
    ) -> [Date: Double] {
        guard let prev = previousPerDay, let dirty = dirtyDays else {
            // No prior / no hint → full per-day sweep.
            return objective.evaluatePerDay(chromosome: chromosome, context: context)
        }

        // Start from the previous scores; rescore only the dirty days so
        // unrelated days keep their cached value. We also need to prune
        // entries whose days no longer contain any gene, otherwise stale
        // days would linger and inflate the denominator in `combinePerDay`.
        let cal = context.calendar
        var currentDays = Set<Date>()
        for gene in chromosome.genes where gene.isIncluded {
            currentDays.insert(cal.startOfDay(for: gene.startTime))
        }
        for event in context.fixedEvents {
            currentDays.insert(cal.startOfDay(for: event.startDate))
        }

        var next: [Date: Double] = [:]
        next.reserveCapacity(currentDays.count)

        for day in currentDays {
            if dirty.contains(day) {
                next[day] = objective.evaluateOneDay(
                    day: day,
                    chromosome: chromosome,
                    context: context
                )
            } else if let cached = prev[day] {
                next[day] = cached
            } else {
                // Day present now but wasn't scored before — happens when a
                // gene moved onto a previously-empty day. Score it fresh.
                next[day] = objective.evaluateOneDay(
                    day: day,
                    chromosome: chromosome,
                    context: context
                )
            }
        }

        return next
    }

    /// Legacy-compatible wrapper that returns only the scalar cache. Kept for
    /// the few call sites that want a flat breakdown without caring about
    /// per-day structure (e.g. scenario comparison).
    func evaluateIncremental(
        chromosome: ScheduleChromosome,
        previousCache: [String: Double]?,
        mutatedIndices: IndexSet?,
        context: OptimizerContext
    ) -> (fitness: Double, cache: [String: Double]) {
        let result = evaluateDelta(chromosome: chromosome, context: context)
        return (result.fitness, result.objectiveCache)
    }

    /// Detailed breakdown of all objective scores (clamped to [0, 1]).
    func objectiveBreakdown(
        for chromosome: ScheduleChromosome,
        context: OptimizerContext
    ) -> [String: Double] {
        var result: [String: Double] = [:]
        for objective in objectives {
            result[objective.name] = max(0, min(1, objective.evaluate(chromosome: chromosome, context: context)))
        }
        return result
    }

    /// Update weights from preferences (e.g., after preference learning).
    func updateWeights(from preferences: OptimizerPreferences) {
        for i in objectives.indices {
            switch objectives[i].name {
            case "FocusBlock":      objectives[i].weight = preferences.focusBlockWeight
            case "PomodoroFit":     objectives[i].weight = preferences.pomodoroFitWeight
            case "Conflict":        objectives[i].weight = preferences.conflictWeight
            case "TaskPlacement":   objectives[i].weight = preferences.taskPlacementWeight
            case "WeekBalance":     objectives[i].weight = preferences.weekBalanceWeight
            case "EnergyBalance":   objectives[i].weight = preferences.energyCurveWeight
            case "MultiPerson":     objectives[i].weight = preferences.multiPersonWeight
            case "BreakPlacement":  objectives[i].weight = preferences.breakWeight
            case "Deadline":        objectives[i].weight = preferences.deadlineWeight
            case "ContextSwitch":   objectives[i].weight = preferences.contextSwitchWeight
            case "Buffer":              objectives[i].weight = preferences.bufferWeight
            case "MeetingClustering":   objectives[i].weight = preferences.meetingClusteringWeight
            default: break
            }
        }
    }
}
