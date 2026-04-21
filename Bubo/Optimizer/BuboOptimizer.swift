import Foundation
import os

/// Diagnostics log for `optimizeWeek` — captures the input workload
/// (working window, busy fixed slots, tasks) and the scenarios the GA
/// produced (placements per day, dropped tasks, fitness breakdown). Read
/// via Console.app → subsystem `com.avpv.Bubo`, category `PlanWeek`.
private let planWeekLogger = Logger(subsystem: "com.avpv.Bubo", category: "PlanWeek")

// MARK: - BuboOptimizer

/// Main facade for the Bubo schedule optimization engine.
/// Combines GA core, constraints, objectives, re-optimization,
/// scenario generation, and preference learning into a single API.
///
/// All optimization methods are async and run the GA on a background thread
/// to keep the main thread responsive.
@MainActor
@Observable
final class BuboOptimizer {

    // MARK: - Components

    let preferenceLearner = PreferenceLearner()
    let reoptimizer = IncrementalReoptimizer()

    /// Number of scenarios to return per optimization.
    var scenarioCount: Int = 3

    // MARK: - Per-Workload Learned State
    //
    // The bandit, attention head, and surrogate are all stateful
    // workload-sensitive learners. A 5-event workload's good operator
    // mix, gene-attention scoring, and fitness landscape are all
    // qualitatively different from a 50-event workload's. Sharing
    // any of them across substantially different workloads
    // cross-contaminates.
    //
    // Resolution: bundle the three together as a `WorkloadLearners`
    // record, key by `TaskSignature`, share a single LRU. Two
    // optimizations on the same calendar reuse the bundle; different
    // workloads get fresh learners. The LRU caps memory.
    //
    // Feedback (`acceptScenario` / `rejectScenario` / `recordManualEdit`)
    // routes via `lastRunSignature` so the user's response always
    // reaches the learners that produced the result.

    /// Per-signature learner bundle. Class (not struct) so identity
    /// equality (`===`) is unambiguous in tests and so callers reason
    /// about "the same bundle" without thinking about value-type
    /// semantics around its four reference-typed fields.
    final class WorkloadLearners {
        let bandit: MutationBandit
        let lnsBandit: LNSStrategyBandit
        let head: GeneAttentionHead
        let surrogate: RBFSurrogate

        init() {
            self.bandit = MutationBandit()
            self.lnsBandit = LNSStrategyBandit()
            self.head = GeneAttentionHead()
            self.surrogate = RBFSurrogate()
        }
    }

    private var learnersBySignature: [TaskSignature: WorkloadLearners] = [:]
    private var learnerLRU: [TaskSignature] = []

    /// Maximum number of distinct task signatures whose learner
    /// bundles are kept in memory. Older bundles evict on overflow.
    /// Default 8 covers most users (2-3 active calendars + a few
    /// experimental ones); raise for power users juggling many
    /// distinct task pools.
    var maxCachedLearnerBundles: Int = 8

    /// Signature of the most recent optimize() invocation. Used by
    /// feedback methods to find the learner bundle to update.
    private(set) var lastRunSignature: TaskSignature?

    /// Look up (or create) the learner bundle for `context`'s task
    /// signature. Refreshes LRU position. Evicts oldest on overflow.
    func learners(for context: OptimizerContext) -> WorkloadLearners {
        let signature = TaskSignature(context: context)
        if let existing = learnersBySignature[signature] {
            learnerLRU.removeAll { $0 == signature }
            learnerLRU.append(signature)
            return existing
        }
        let fresh = WorkloadLearners()
        learnersBySignature[signature] = fresh
        learnerLRU.append(signature)
        while learnerLRU.count > maxCachedLearnerBundles {
            let evicted = learnerLRU.removeFirst()
            learnersBySignature.removeValue(forKey: evicted)
        }
        return fresh
    }

    // MARK: - Graph Caches
    //
    // Long-lived memoization layers shared across optimization runs.
    //
    // * `intentGraphCache` (`IntentGraphSalsaCache`): QueryDB-backed
    //   with per-intent / per-pair / per-phase decomposition. A
    //   single chip edit invalidates only the queries that touched
    //   the edited intent — other compile entries, pair conflicts,
    //   and phase buckets stay warm across the edit. Whole-graph
    //   entries are bounded by an LRU so a long session with many
    //   distinct shapes doesn't grow unbounded.
    //
    // * `conflictGraphCache` (`ScheduleConflictGraphSalsaCache`):
    //   QueryDB-backed with per-event metadata and per-pair overlap
    //   queries. The whole-graph build still routes through
    //   `ScheduleConflictGraph.build` — the domain's existing
    //   participant-index + sort-sweep fast paths already bypass
    //   the O(N²) pair predicate evaluation Salsa would accelerate.
    //   Per-event / per-pair caching is scaffolding for external
    //   consumers (e.g. UI-driven "does this pair conflict?"
    //   queries) and future build variants.
    //
    // Both caches replaced the prior hash-keyed LRU implementations;
    // the LRU variants (`IntentGraphCache`, `ScheduleConflictGraphCache`)
    // stay available for tests that want simpler memoization semantics.

    let intentGraphCache = IntentGraphSalsaCache()
    let conflictGraphCache = ScheduleConflictGraphSalsaCache()

    // MARK: - State

    private(set) var isOptimizing = false
    private(set) var lastResult: OptimizerResult?

    /// The current schedule genes (movable events placement).
    var currentSchedule: [ScheduleGene] = []

    /// Captured from the most recent `optimize()` call — used by adaptive
    /// feedback methods to record accepted/rejected outcomes into the
    /// temporal warm-start store and buffer fit. Cleared by `reset()`.
    private(set) var lastOptimizationContext: OptimizerContext?

    // MARK: - Configuration

    var gaConfig: GAConfiguration = .default
    var islandConfig: IslandConfiguration = .default
    var preferences: OptimizerPreferences = OptimizerPreferences()

    // MARK: - Full Optimization (Async)

    /// Run a full optimization for the given context.
    /// Uses island model GA with multiple parallel populations and periodic migration.
    /// The GA runs on a background thread; progress updates are dispatched to main.
    ///
    /// Concurrency: launching multiple `optimize()` calls in parallel
    /// on the same `BuboOptimizer` is safe. Calls for different
    /// workload signatures use disjoint learner bundles. Calls for
    /// the *same* signature share the bundle's bandit/head/surrogate
    /// — every mutating operation on those classes is lock-protected
    /// and individually idempotent (LinUCB updates are commutative,
    /// surrogate sample appends are independent, head weight updates
    /// commute within clamp), so concurrent updates produce a
    /// well-defined post-state without serialization. The non-
    /// determinism is bounded by the order of evaluation completions
    /// and is the same kind of bounded variance the GA tolerates by
    /// design.
    func optimize(
        context: OptimizerContext,
        overrideConfig: GAConfiguration? = nil,
        overrideIslandConfig: IslandConfiguration? = nil
    ) async -> OptimizerResult {
        isOptimizing = true
        defer { isOptimizing = false }

        // Apply learned preferences, merging with (not replacing) user preferences
        var prefs = context.preferences
        preferenceLearner.applyToPreferences(&prefs)
        // Learner-driven preference prelude: DPO weight overlay +
        // chance-constrained buffer fit applied on top of user prefs.
        // Both are safe no-ops when their feature flags are off.
        adjustPreferencesFromLearners(prefs: &prefs, context: context)

        // Resolve per-workload learners (bandit + head + surrogate)
        // by task signature so learning persists across runs on the
        // same calendar but different workloads stay isolated.
        // `lastRunSignature` is recorded so feedback methods know
        // which bundle to update.
        let signature = TaskSignature(context: context)
        let workloadLearners = learners(for: context)
        lastRunSignature = signature

        // RNG is *split* from the caller's generator, not shared:
        // `GARandom` is a reference type, and two concurrent
        // `optimize()` calls would otherwise interleave draws from
        // a single stream. The split keeps the caller's stream
        // reproducible across concurrent runs.
        let preliminarySuite = obtainLearnerSuite(for: context)
        let tabuToInject: TabuMemory? = schedulingFeatures.useTabuMemory
            ? preliminarySuite.tabu
            : nil
        let cpSATToInject: CPSATRepairer? = schedulingFeatures.useCPSATRepair
            ? CPSATRepairer()
            : nil
        let adjustedContext = OptimizerContext(
            fixedEvents: context.fixedEvents,
            movableEvents: context.movableEvents,
            workingHours: context.workingHours,
            planningHorizon: context.planningHorizon,
            preferences: prefs,
            participantAvailability: context.participantAvailability,
            calendar: context.calendar,
            rng: context.rng.split(),
            mutationBandit: workloadLearners.bandit,
            lnsStrategyBandit: workloadLearners.lnsBandit,
            contextualCrossoverHead: workloadLearners.head,
            tabuMemory: tabuToInject,
            cpSATRepairer: cpSATToInject,
            cpSATWindowThreshold: schedulingFeatures.cpSATWindowThreshold
        )
        // Stash for learner-feedback callbacks (acceptScenario etc).
        lastOptimizationContext = adjustedContext

        let evaluator = FitnessEvaluator.standard(preferences: prefs)
        let config = overrideConfig ?? gaConfig
        let capturedIslandConfig = overrideIslandConfig ?? islandConfig
        let capturedScenarioCount = scenarioCount

        // Survivor selector: MOEA/D-AWA when explicitly enabled
        // (beneficial at 8+ objectives), else adaptive NSGA-III
        // with HypE-lite tiebreak. Both read per-objective scores
        // from the chromosome cache so survivor selection imposes
        // zero extra evaluation cost.
        let moeadState: MOEADState? = schedulingFeatures.useMOEADAWASurvivor
            ? MOEAD_AWA.forScheduleEvaluator(
                evaluator: evaluator,
                populationSize: max(2, config.populationSize * 2)
            )
            : nil
        // Adaptive hypervolume sample count. Two signals matter:
        //
        //   1. Objective count `d`. HV estimator variance grows with
        //      dimensionality; more objectives need more samples to
        //      keep relative error bounded. We scale linearly in `d`
        //      — the principled 2^d bound saturates the clamp for
        //      our 13-objective evaluator and loses resolution, so a
        //      linear proxy is pragmatic.
        //
        //   2. Population size bounds the *useful* sample budget: with
        //      a 20-individual `.instant` population the Pareto front
        //      has at most ~20 points and there's no benefit to
        //      measuring its volume with 8 000 samples — most land in
        //      pure-dominated or pure-undominated regions that carry
        //      no tiebreaking signal.
        //
        // `popSize × d × 4` clamped to [256, 8 000] gives:
        //     popSize=20, d=13  → 1040   (was 1600 static cap-hit)
        //     popSize=60, d=13  → 3120   (was 8000)
        //     popSize=100, d=13 → 5200   (was 8000)
        //     popSize≥192, d=13 → 8000   (original full budget)
        // so tiny runs save ~80% of HV cost and full-scale runs are
        // unaffected.
        let objectiveCount = max(1, evaluator.objectives.count)
        let hvSamples = min(
            8_000,
            max(256, config.populationSize * objectiveCount * 4)
        )
        let multiObjective = MultiObjectiveContext<ScheduleChromosome>.schedule(
            evaluator: evaluator,
            populationSize: config.populationSize,
            hypervolumeSampleCount: hvSamples,
            moeadState: moeadState
        )

        // Quality-Diversity archive shared across every island so
        // productive genotypes discovered anywhere feed every
        // population.
        // Quality-Diversity archive is per-run — its incumbents carry
        // concrete gene IDs that only make sense for this workload's
        // movable event set. Attempting to cross-wire archives from
        // different optimize() calls would inject invalid chromosomes.
        let qdArchive = QualityDiversityArchive(resolution: 6)

        // Gradient refiner for elite fine-tuning. Pure value type;
        // safe to capture across threads.
        let gradientRefiner = ScheduleGradientRefiner()

        // Surrogate from the per-signature learner bundle.
        let surrogate = workloadLearners.surrogate

        // Canonical objective ordering for surrogate's objective-vector
        // prediction. Must match the order `MultiObjectiveContext`
        // reads from `objectiveCache`, else NSGA-III associates
        // surrogate-predicted individuals with the wrong reference
        // directions.
        let objectiveNames = evaluator.objectives.map(\.name)

        // Schedule-specific evolution hooks. Composed via the generic
        // `EvolutionHooks` API so the engine never sees schedule types.
        //
        // The evaluator does two things differently from the baseline
        // path:
        //   (1) On surrogate-accept, it fills `objectiveCache` with a
        //       predicted objective vector so NSGA-III / hypervolume
        //       selection sees non-zero per-axis scores. Without this,
        //       surrogate-predicted individuals land on front 0 with
        //       a phantom-perfect Pareto position.
        //   (2) On calibration refresh / high-uncertainty real
        //       evaluation, it passes the surrogate's pre-call
        //       prediction back via `priorPrediction` so rolling MAE
        //       in telemetry actually tracks drift.
        let surrogateAssistedEvaluator: @Sendable (inout ScheduleChromosome) -> Void = { chromosome in
            // `extractOrCache` populates `chromosome.cachedFeatures`
            // so the next screen on this chromosome (possible after a
            // no-op through crossover/elitism) skips the full aggregate
            // pass. Invalidation happens inside `mutate` / `repair`.
            let features = ScheduleFeatureVector.extractOrCache(&chromosome, context: adjustedContext).values
            switch surrogate.screen(features: features) {
            case .accept(let predicted, let predictedObjectives):
                chromosome.fitness = predicted
                chromosome.rawFitness = predicted
                chromosome.needsEvaluation = false
                // Surrogate prediction — mark as phantom so downstream
                // boundary checks (MAP-Elites archival, scenario
                // emission) can force a real evaluation before the
                // value is trusted externally.
                chromosome.isFitnessReal = false
                if let vec = predictedObjectives, vec.count == objectiveNames.count {
                    var cache: [String: Double] = [:]
                    cache.reserveCapacity(objectiveNames.count)
                    for (i, name) in objectiveNames.enumerated() {
                        cache[name] = vec[i]
                    }
                    chromosome.objectiveCache = cache
                }
            case .realEvaluate(_, let priorPrediction):
                evaluator.evaluateAndAssign(&chromosome, context: adjustedContext)
                let objectivesVec: ContiguousArray<Double>?
                if let cache = chromosome.objectiveCache {
                    var v = ContiguousArray<Double>()
                    v.reserveCapacity(objectiveNames.count)
                    for name in objectiveNames {
                        v.append(cache[name] ?? 0)
                    }
                    objectivesVec = v
                } else {
                    objectivesVec = nil
                }
                surrogate.record(
                    features: features,
                    fitness: chromosome.rawFitness,
                    objectives: objectivesVec,
                    priorPrediction: priorPrediction
                )
            }
        }

        var hookComponents: [EvolutionHooks<ScheduleChromosome>] = [
            ScheduleEvolutionHooks.qualityDiversityFeeding(archive: qdArchive),
            ScheduleEvolutionHooks.qualityDiversityEmission(archive: qdArchive, emissionRate: 0.12),
            ScheduleEvolutionHooks.gradientRefinement(
                refiner: gradientRefiner,
                interval: 35,
                candidates: 3,
                evaluate: surrogateAssistedEvaluator
            ),
        ]
        if schedulingFeatures.useCMAMEEmitter {
            // CMA-ME samples around the population's current best.
            // 5% emission rate keeps cost modest while still
            // letting the covariance-adapted Gaussian probe locally.
            hookComponents.append(
                ScheduleEvolutionHooks.cmaMEEmission(
                    archive: qdArchive,
                    emissionRate: 0.05,
                    templateProvider: { population in
                        population.individuals.max(by: { $0.rawFitness < $1.rawFitness })
                    },
                    evaluate: surrogateAssistedEvaluator
                )
            )
        }
        let hooks = ScheduleEvolutionHooks.compose(
            contentsOf: hookComponents
        )

        // Run island model GA on background thread. All islands share
        // the per-workload `bandit` and `head` from `workloadLearners`
        // via `adjustedContext`. User feedback (`acceptScenario` /
        // `rejectScenario`) routes via `lastRunSignature` so it
        // updates the same bundle on subsequent optimizations of the
        // same workload.
        //
        // `FederatedMutationBandit` remains available as an opt-in
        // optimization for callers that want per-island bandits with
        // periodic merging — not wired by default because it fights
        // with the persistent-feedback path.
        // Collect warm-start seeds from the learner suite so the
        // initial population starts inside the basin of recent
        // accepted solutions and respects GNN-derived priorities.
        let extraSeeds: [ScheduleChromosome] = collectWarmStartSeeds(context: adjustedContext)
        let learnerSuite = obtainLearnerSuite(for: adjustedContext)
        let migrationBandit = schedulingFeatures.useMigrationBandit
            ? learnerSuite.migrationBandit
            : nil

        // Multi-fidelity funnel: when enabled, wrap the per-chromo
        // surrogate-assisted evaluator into a batch screen +
        // tier-2 promotion. Declared as a `@Sendable` closure so it
        // can cross the Task.detached boundary without the
        // evaluator's inout state leaking.
        let multiFidelityBatch: (@Sendable (inout [ScheduleChromosome]) -> Void)?
        if schedulingFeatures.useMultiFidelityFunnel {
            let funnel = MultiFidelityEvaluator(
                surrogate: workloadLearners.surrogate,
                evaluator: evaluator
            )
            let adjustedCtxLocal = adjustedContext
            multiFidelityBatch = { batch in
                _ = funnel.evaluateBatch(&batch, context: adjustedCtxLocal)
            }
        } else {
            multiFidelityBatch = nil
        }

        let (population, convergenceGen, duration) = await Task.detached(priority: .userInitiated) {
            let startTime = Date()

            let islandGA = IslandModelGA<ScheduleChromosome>(
                islandConfig: capturedIslandConfig,
                baseConfig: config,
                context: adjustedContext,
                evaluate: surrogateAssistedEvaluator,
                multiObjective: multiObjective,
                hooks: hooks,
                extraSeeds: extraSeeds,
                migrationBandit: migrationBandit,
                batchEvaluate: multiFidelityBatch
            )

            // Cooperative cancellation: `islandGA.run()` throws
            // `CancellationError` when the enclosing Task is cancelled
            // mid-evolution. We surface whatever `bestEver` was found
            // before interruption so the UI always gets a usable
            // (if suboptimal) result.
            let pop: [ScheduleChromosome]
            do {
                pop = try islandGA.run()
            } catch is CancellationError {
                if let best = islandGA.bestEver {
                    pop = [best]
                } else {
                    pop = []
                }
            } catch {
                pop = islandGA.bestEver.map { [$0] } ?? []
            }
            let elapsed = Date().timeIntervalSince(startTime)
            return (pop, islandGA.convergenceGeneration, elapsed)
        }.value

        // Back on main thread — deposit every island individual into the
        // MAP-Elites archive and read diverse scenarios out of it.
        // Note on the two coexisting archive flavours:
        //   - `QualityDiversityArchive` (during-GA) bins on
        //     focusMass / morningSkew / daySpread to drive *emitter*
        //     selection inside evolution.
        //   - `MAPElitesArchive` (post-GA, here) bins on
        //     focusQuality / meetingDensity / inclusionRatio —
        //     user-meaningful axes — to pick the *display* set of
        //     scenarios. Different axes serve different consumers,
        //     so the two coexist deliberately.
        //
        // Force real evaluation on every candidate whose `rawFitness`
        // is a surrogate prediction, before archival. During evolution
        // the multi-fidelity funnel and the surrogate-assisted
        // per-chromosome evaluator both stamp `rawFitness` with
        // predictions that can disagree with ground truth — in
        // particular, a feasible chromosome can receive a prediction
        // below 0.1 because its neighbours in feature space include
        // infeasible training samples. The archive would then pick a
        // "best" cell whose rawFitness is a phantom, and
        // `IntentCompiler` would surface a spurious "Not enough room"
        // dialog for a trivially-schedulable workload.
        //
        // Writers set `isFitnessReal` to reflect which path produced
        // the score; here we only pay for a fresh evaluation on
        // chromosomes that are still phantom. In the common `.quick`
        // case with a warmed surrogate this skips a majority of the
        // combined population, so the check is strictly cheaper than
        // a blind re-eval of every individual.
        var verifiedPopulation = population
        for i in verifiedPopulation.indices where !verifiedPopulation[i].isFitnessReal {
            verifiedPopulation[i].needsEvaluation = true
            evaluator.evaluateAndAssign(&verifiedPopulation[i], context: adjustedContext)
        }
        var archive = MAPElitesArchive()
        archive.depositAll(verifiedPopulation, context: adjustedContext)
        // Stamp every scenario with the run's task signature so
        // feedback methods can route updates to the correct
        // per-workload learner bundle even after later runs on
        // different workloads.
        var scenarios = archive.diverseScenarios(
            count: capturedScenarioCount,
            evaluator: evaluator,
            context: adjustedContext
        ).map { scenario -> ScheduleScenario in
            var stamped = scenario
            stamped.sourceSignature = signature
            return stamped
        }
        // Scenario refinement: lex ranking, active-learning pair
        // surfacing, path relinking, diffusion polish. Each step
        // checks its own feature flag and no-ops when disabled.
        scenarios = refineAndRankScenarios(
            scenarios: scenarios,
            context: adjustedContext,
            evaluator: evaluator
        )

        let populationCount = verifiedPopulation.prefix(10).count
        let metadata = OptimizationMetadata(
            generations: convergenceGen,
            totalDuration: duration,
            bestFitness: verifiedPopulation.first?.fitness ?? 0,
            averageFitness: populationCount > 0
                ? verifiedPopulation.prefix(10).reduce(0) { $0 + $1.fitness } / Double(populationCount)
                : 0,
            convergenceGeneration: convergenceGen
        )

        let result = OptimizerResult(scenarios: scenarios, metadata: metadata)
        lastResult = result

        if let best = scenarios.first {
            currentSchedule = best.genes
        }

        return result
    }

    // MARK: - Pareto Optimize (alias)

    /// NSGA-III is now the default survivor-selection strategy, so this
    /// method is a thin alias over `optimize`. Kept to avoid breaking
    /// callers that specifically asked for Pareto-aware scenarios.
    func optimizeWithPareto(
        context: OptimizerContext,
        overrideConfig: GAConfiguration? = nil,
        overrideIslandConfig: IslandConfiguration? = nil
    ) async -> OptimizerResult {
        await optimize(
            context: context,
            overrideConfig: overrideConfig,
            overrideIslandConfig: overrideIslandConfig
        )
    }

    // MARK: - Quick Optimize (Day)

    func optimizeToday(
        fixedEvents: [CalendarEvent],
        movableEvents: [OptimizableEvent],
        workingHours: ClosedRange<Int> = 9...18
    ) async -> OptimizerResult {
        let cal = Calendar.current
        let todayStart = cal.startOfDay(for: Date())
        let todayEnd = cal.date(byAdding: .day, value: 1, to: todayStart)!

        let context = OptimizerContext(
            fixedEvents: fixedEvents.filter { $0.startDate >= todayStart && $0.startDate < todayEnd },
            movableEvents: movableEvents,
            workingHours: workingHours,
            planningHorizon: DateInterval(start: max(Date(), todayStart), end: todayEnd),
            preferences: preferences
        )

        return await optimize(context: context, overrideConfig: .quick, overrideIslandConfig: .quick)
    }

    // MARK: - Weekly Optimize

    func optimizeWeek(
        fixedEvents: [CalendarEvent],
        movableEvents: [OptimizableEvent],
        workingHours: ClosedRange<Int> = 9...18,
        participantAvailability: [String: [DateInterval]] = [:]
    ) async -> OptimizerResult {
        let now = Date()
        let weekEnd = Calendar.current.date(byAdding: .day, value: 7, to: now)!
        let horizon = DateInterval(start: now, end: weekEnd)

        let context = OptimizerContext(
            fixedEvents: fixedEvents,
            movableEvents: movableEvents,
            workingHours: workingHours,
            planningHorizon: horizon,
            preferences: preferences,
            participantAvailability: participantAvailability
        )

        // Problem-size-aware config: a 4-task week does NOT need 240
        // individuals × 400 generations × 4 islands. Scale the solver
        // budget to the search-space size so interactive "plan week"
        // stays under a few seconds on sparse backlogs without losing
        // solution quality on dense ones.
        let (gaCfg, islandCfg) = configForWorkload(
            movableEvents: movableEvents,
            fixedEvents: fixedEvents
        )

        logPlanWeekInputs(
            fixedEvents: fixedEvents,
            movableEvents: movableEvents,
            workingHours: workingHours,
            horizon: horizon,
            gaCfg: gaCfg,
            islandCfg: islandCfg
        )
        let wallStart = Date()
        let result = await optimize(
            context: context,
            overrideConfig: gaCfg,
            overrideIslandConfig: islandCfg
        )
        logPlanWeekResult(
            result: result,
            movableEvents: movableEvents,
            wallDuration: Date().timeIntervalSince(wallStart)
        )
        return result
    }

    /// Pick GA + island config scaled continuously to the effective
    /// workload size. The search space is dominated by two things:
    ///
    ///   • N = movable event count (placement decisions per week)
    ///   • H = total movable hours / working hours per week
    ///       (how packed the week has to be — 3 four-hour tasks are a
    ///       harder bin-packing than 8 thirty-minute tasks).
    ///
    /// A single "difficulty" scalar `D` combines both; population,
    /// generations and wallclock budget all scale linearly with it.
    /// This avoids the cliff-edges the old bucketed version had at
    /// N = 4 / 9 / 21 where a single extra task silently doubled the
    /// solver budget.
    ///
    /// `D` is clamped into [0.05, 1.0] where:
    ///   • D ≤ 0.1   → workload fits within `.instant`-class budget
    ///   • D ≈ 0.3   → around `.quick`-class
    ///   • D ≈ 0.7   → around single-pop `.default`-class
    ///   • D ≥ 0.9   → falls through to the instance's configured
    ///                 `.island` (heavy full-budget path)
    ///
    /// Returning `nil` for either override means "use instance default".
    private func configForWorkload(
        movableEvents: [OptimizableEvent],
        fixedEvents: [CalendarEvent]
    ) -> (GAConfiguration?, IslandConfiguration?) {
        let difficulty = workloadDifficulty(
            movableEvents: movableEvents,
            fixedEvents: fixedEvents
        )

        // Above ~0.9 the workload is heavy enough to justify the full
        // island config. Delegate to instance defaults.
        guard difficulty < 0.9 else { return (nil, nil) }

        let single = IslandConfiguration(
            islandCount: 1,
            migrationInterval: 10,
            migrationSize: 1,
            topology: .ring,
            emigrantSelection: .best,
            immigrantReplacement: .worst,
            diversifyIslands: false,
            adaptiveMigration: false,
            routeByProductivity: false
        )

        // Linear interpolation between `.instant` and `.default` as
        // difficulty rises. Crossover into island mode happens at
        // D ≥ 0.75 where two islands start to pay for themselves.
        let popSize = Self.lerpInt(start: 20, end: 100, at: difficulty)
        let maxGen = Self.lerpInt(start: 30, end: 200, at: difficulty)
        let timeout = Self.lerpDouble(start: 0.8, end: 8.0, at: difficulty)

        // Memetic hill climb and CHC restarts are expensive but
        // valuable on harder problems. Off entirely for `.instant`-
        // class tiers (they waste budget on tiny search spaces); on
        // from the mid-tier onwards with cadence matched to the
        // generation budget.
        let memeticInterval = difficulty >= 0.5 ? max(5, maxGen / 8) : 0
        let memeticCandidates = difficulty >= 0.5 ? 3 : 3
        let memeticSteps = difficulty >= 0.5 ? 6 : 5

        let ga = GAConfiguration(
            populationSize: popSize,
            maxGenerations: maxGen,
            mutationRate: 0.18,
            crossoverRate: 0.82,
            eliteCount: max(1, popSize / 25),
            selectionStrategy: .tournament(size: 3),
            crossoverStrategy: .contextual(temperature: 0.5),
            convergenceThreshold: 0.003,
            convergencePatience: max(6, maxGen / 20),
            adaptiveMutation: true,
            diversityThreshold: 0.01,
            immigrationRate: 0.1,
            greedySeedFraction: 0.2,
            enableRepair: true,
            adaptiveCrossover: difficulty >= 0.5,
            memeticHillClimbInterval: memeticInterval,
            memeticHillClimbCandidates: memeticCandidates,
            memeticHillClimbSteps: memeticSteps,
            wallclockTimeout: timeout
        )

        // Two islands appear at the high end; their extra cost only
        // pays off once the search space is big enough for migration
        // to meaningfully diversify exploration.
        let islandCfg: IslandConfiguration = difficulty >= 0.75 ? .quick : single
        return (ga, islandCfg)
    }

    /// Combined workload difficulty scalar in [0.05, 1.0].
    ///
    /// `countFactor` is asymptotic — 30 tasks pushes the factor to
    /// ~0.95, 50 tasks to ~0.99. `densityFactor` looks at week
    /// saturation: 40 movable hours over a 5-day × 9-hour working
    /// week saturates the schedule and forces more search even if N
    /// is small. Taking the *max* of the two means either factor
    /// alone can trigger the heavy tier — a handful of very long
    /// tasks doesn't get under-served.
    private func workloadDifficulty(
        movableEvents: [OptimizableEvent],
        fixedEvents: [CalendarEvent]
    ) -> Double {
        let n = Double(movableEvents.count)
        // Saturating curve: N=1 → ~0.04, N=8 → ~0.30, N=20 → ~0.60,
        // N=40 → ~0.90. Half-life around 20 tasks.
        let countFactor = 1.0 - exp(-n / 20.0)

        // Planning horizon is 7 days in optimizeWeek; we approximate
        // the weekday working hours by 5 × 9h = 45h. Fixed events eat
        // into that budget — subtract their total duration from the
        // denominator so a calendar already half-full with meetings
        // pushes the density up.
        let movableHours = movableEvents.reduce(0.0) { $0 + $1.duration / 3600.0 }
        let fixedHours = fixedEvents.reduce(0.0) { acc, ev in
            acc + ev.endDate.timeIntervalSince(ev.startDate) / 3600.0
        }
        let availableHours = max(5.0, 45.0 - fixedHours)
        let densityFactor = min(1.0, movableHours / availableHours)

        return max(0.05, min(1.0, max(countFactor, densityFactor)))
    }

    // MARK: - PlanWeek Diagnostics Logging

    /// Log the consolidated input the GA is about to see: working
    /// window, busy fixed slots broken down by day, movable task list,
    /// and the adaptive GA budget picked for this workload. Intended
    /// for diagnosing "the optimizer is making odd choices" reports —
    /// a side-by-side of this and `logPlanWeekResult` tells you
    /// whether a surprising placement is an input problem (not enough
    /// room, conflicting deadline) or a solver problem (budget too
    /// small, bad fitness trade-off).
    private func logPlanWeekInputs(
        fixedEvents: [CalendarEvent],
        movableEvents: [OptimizableEvent],
        workingHours: ClosedRange<Int>,
        horizon: DateInterval,
        gaCfg: GAConfiguration?,
        islandCfg: IslandConfiguration?
    ) {
        let df = DateFormatter()
        df.dateFormat = "EEE dd.MM"
        let tf = DateFormatter()
        tf.dateFormat = "HH:mm"
        let cal = Calendar.current

        let fixedInWindow = fixedEvents.filter { horizon.intersects(DateInterval(start: $0.startDate, end: max($0.endDate, $0.startDate))) }
        let fixedHours = fixedInWindow.reduce(0.0) { $0 + $1.endDate.timeIntervalSince($1.startDate) / 3600.0 }
        let movableHours = movableEvents.reduce(0.0) { $0 + $1.duration / 3600.0 }
        let workHoursPerDay = Double(workingHours.upperBound - workingHours.lowerBound)
        let difficulty = workloadDifficulty(movableEvents: movableEvents, fixedEvents: fixedEvents)

        var lines: [String] = []
        lines.append("=== PlanWeek inputs ===")
        lines.append(String(format: "horizon: %@ → %@ (%.1fh/day × window)",
                            df.string(from: horizon.start),
                            df.string(from: horizon.end),
                            workHoursPerDay))
        lines.append("working hours: \(workingHours.lowerBound):00-\(workingHours.upperBound):00")
        lines.append(String(format: "tasks: %d (%.1fh total), fixed: %d (%.1fh), difficulty: %.2f",
                            movableEvents.count, movableHours,
                            fixedInWindow.count, fixedHours,
                            difficulty))

        // Busy slots per day — the "сводные слоты" view: everything
        // already occupied that the GA must route around.
        lines.append("-- busy slots per day --")
        let fixedByDay = Dictionary(grouping: fixedInWindow) { cal.startOfDay(for: $0.startDate) }
        for day in fixedByDay.keys.sorted() {
            let dayEvents = fixedByDay[day]!.sorted { $0.startDate < $1.startDate }
            let busyH = dayEvents.reduce(0.0) { $0 + $1.endDate.timeIntervalSince($1.startDate) / 3600.0 }
            let freeH = max(0, workHoursPerDay - busyH)
            var parts: [String] = []
            parts.append("\(df.string(from: day)): \(dayEvents.count) busy (\(String(format: "%.1f", busyH))h), ~\(String(format: "%.1f", freeH))h free")
            for ev in dayEvents.prefix(6) {
                parts.append("  \(tf.string(from: ev.startDate))-\(tf.string(from: ev.endDate)) \(ev.title)")
            }
            if dayEvents.count > 6 {
                parts.append("  … (+\(dayEvents.count - 6) more)")
            }
            lines.append(parts.joined(separator: "\n"))
        }

        lines.append("-- movable tasks --")
        for (i, ev) in movableEvents.enumerated() {
            var flags: [String] = []
            if ev.isFocusBlock { flags.append("focus") }
            if ev.isDroppable { flags.append("droppable") }
            if !ev.dependsOn.isEmpty { flags.append("deps=\(ev.dependsOn.count)") }
            if let gid = ev.groupId { flags.append("group=\(gid.prefix(6))") }
            if let pref = ev.preferredHourRange {
                flags.append("pref=\(pref.lowerBound)-\(pref.upperBound)")
            }
            let deadlineStr = ev.deadline.map { " deadline=\(df.string(from: $0))" } ?? ""
            let earliestStr = ev.earliestStart.map { " earliest=\(df.string(from: $0))" } ?? ""
            let ctx = ev.context.map { " ctx=\($0)" } ?? ""
            let flagStr = flags.isEmpty ? "" : " [\(flags.joined(separator: ","))]"
            lines.append(String(format: "  %2d. %.1fh p=%.2f e=%.2f%@%@%@%@ %@",
                                i + 1,
                                ev.duration / 3600.0,
                                ev.priority,
                                ev.energyCost,
                                ctx,
                                deadlineStr,
                                earliestStr,
                                flagStr,
                                ev.title))
        }

        let gaDesc: String
        if let ga = gaCfg {
            gaDesc = "pop=\(ga.populationSize) maxGen=\(ga.maxGenerations) timeout=\(String(format: "%.1fs", ga.wallclockTimeout)) mut=\(String(format: "%.2f", ga.mutationRate)) xover=\(String(format: "%.2f", ga.crossoverRate))"
        } else {
            gaDesc = "instance default (pop=\(gaConfig.populationSize) maxGen=\(gaConfig.maxGenerations))"
        }
        let islandDesc: String
        if let ic = islandCfg {
            islandDesc = "islands=\(ic.islandCount) mig=\(ic.migrationInterval)/\(ic.migrationSize)"
        } else {
            islandDesc = "instance default (islands=\(islandConfig.islandCount))"
        }
        lines.append("GA budget: \(gaDesc) | \(islandDesc)")

        planWeekLogger.info("\(lines.joined(separator: "\n"), privacy: .public)")
    }

    /// Log what the GA returned: per-scenario placements grouped by
    /// day, dropped tasks, fitness with top objective breakdown, and
    /// solver metadata (generations, convergence, wall time). Pair
    /// with `logPlanWeekInputs` to see whether the final schedule
    /// lines up with the inputs and constraints.
    private func logPlanWeekResult(
        result: OptimizerResult,
        movableEvents: [OptimizableEvent],
        wallDuration: TimeInterval
    ) {
        let df = DateFormatter()
        df.dateFormat = "EEE dd.MM"
        let tf = DateFormatter()
        tf.dateFormat = "HH:mm"
        let cal = Calendar.current
        let titleById = Dictionary(uniqueKeysWithValues: movableEvents.map { ($0.id, $0.title) })

        var lines: [String] = []
        lines.append("=== PlanWeek result ===")
        let meta = result.metadata
        lines.append(String(format: "scenarios=%d, wall=%.2fs (GA=%.2fs), gen=%d, convergedAt=%d, bestFit=%.4f, avgFit=%.4f",
                            result.scenarios.count,
                            wallDuration,
                            meta.totalDuration,
                            meta.generations,
                            meta.convergenceGeneration,
                            meta.bestFitness,
                            meta.averageFitness))

        if result.scenarios.isEmpty {
            lines.append("(no scenarios produced — GA returned empty population)")
            planWeekLogger.info("\(lines.joined(separator: "\n"), privacy: .public)")
            return
        }

        for (idx, scenario) in result.scenarios.enumerated() {
            lines.append("-- scenario #\(idx + 1) --")
            let active = scenario.activeGenes
            let dropped = scenario.genes.filter { !$0.isIncluded }
            lines.append(String(format: "fitness=%.4f, placed=%d, dropped=%d, violations=%d",
                                scenario.fitness,
                                active.count,
                                dropped.count,
                                scenario.constraintViolations.count))

            // Top objectives (most-negative first — those hurt fitness
            // the most and usually explain surprising trade-offs).
            let topObjectives = scenario.objectiveBreakdown
                .sorted { $0.value < $1.value }
                .prefix(5)
            if !topObjectives.isEmpty {
                let objStr = topObjectives
                    .map { "\($0.key)=\(String(format: "%.3f", $0.value))" }
                    .joined(separator: ", ")
                lines.append("top objectives: \(objStr)")
            }

            if !scenario.constraintViolations.isEmpty {
                let shown = scenario.constraintViolations.prefix(5).joined(separator: "; ")
                let suffix = scenario.constraintViolations.count > 5
                    ? " (+\(scenario.constraintViolations.count - 5) more)" : ""
                lines.append("violations: \(shown)\(suffix)")
            }

            // Placements grouped by day — the "how the optimizer
            // laid tasks into slots" view the user asked for.
            let byDay = Dictionary(grouping: active) { cal.startOfDay(for: $0.startTime) }
            for day in byDay.keys.sorted() {
                let genes = byDay[day]!.sorted { $0.startTime < $1.startTime }
                let dayHours = genes.reduce(0.0) { $0 + $1.duration / 3600.0 }
                lines.append("  \(df.string(from: day)) — \(genes.count) tasks, \(String(format: "%.1f", dayHours))h:")
                for g in genes {
                    let title = titleById[g.eventId] ?? g.title
                    let mins = Int((g.duration / 60).rounded())
                    lines.append("    \(tf.string(from: g.startTime))-\(tf.string(from: g.endTime)) (\(mins)m) \(title)")
                }
            }

            if !dropped.isEmpty {
                let names = dropped.prefix(8).map { titleById[$0.eventId] ?? $0.title }
                let suffix = dropped.count > 8 ? " (+\(dropped.count - 8) more)" : ""
                lines.append("  dropped: \(names.joined(separator: ", "))\(suffix)")
            }
        }

        // Cross-scenario: which tasks never got placed by any scenario?
        // A task that's always dropped usually means the inputs can't
        // fit it, not that the GA missed an option.
        let everPlaced = Set(result.scenarios.flatMap { $0.activeGenes.map(\.eventId) })
        let neverPlaced = movableEvents.filter { !everPlaced.contains($0.id) }
        if !neverPlaced.isEmpty {
            let names = neverPlaced.prefix(8).map(\.title)
            let suffix = neverPlaced.count > 8 ? " (+\(neverPlaced.count - 8) more)" : ""
            lines.append("never placed across any scenario: \(names.joined(separator: ", "))\(suffix)")
        }

        planWeekLogger.info("\(lines.joined(separator: "\n"), privacy: .public)")
    }

    private static func lerpInt(start: Int, end: Int, at t: Double) -> Int {
        let clamped = max(0.0, min(1.0, t))
        let raw = Double(start) + clamped * Double(end - start)
        return max(min(start, end), min(max(start, end), Int(raw.rounded())))
    }

    private static func lerpDouble(start: Double, end: Double, at t: Double) -> Double {
        let clamped = max(0.0, min(1.0, t))
        return start + clamped * (end - start)
    }

    // MARK: - Incremental Re-optimization (#26)

    func reoptimize(
        trigger: ReoptimizationTrigger,
        context: OptimizerContext
    ) async -> OptimizerResult? {
        isOptimizing = true
        defer { isOptimizing = false }

        var prefs = context.preferences
        preferenceLearner.applyToPreferences(&prefs)

        let evaluator = FitnessEvaluator.standard(preferences: prefs)
        let schedule = currentSchedule
        // Capture reoptimizer config as values for thread safety
        let stabilityWeight = reoptimizer.stabilityWeight
        let minimumImprovement = reoptimizer.minimumImprovement

        let reopt = IncrementalReoptimizer()
        reopt.stabilityWeight = stabilityWeight
        reopt.minimumImprovement = minimumImprovement

        let result = await Task.detached(priority: .userInitiated) {
            reopt.reoptimize(
                currentSchedule: schedule,
                trigger: trigger,
                context: context,
                evaluator: evaluator,
                config: .quick
            )
        }.value

        // Update internal state if re-optimization succeeded
        if let result = result, let best = result.scenarios.first {
            currentSchedule = best.genes
            lastResult = result
        }

        return result
    }

    // MARK: - Instant Reflow

    /// Ultra-fast re-optimization for live preview and drag-to-schedule.
    /// Uses .instant config (~20 generations, ~100ms) with warm start.
    /// Returns the best genes or nil if no improvement found.
    func instantReflow(context: OptimizerContext) async -> [ScheduleGene]? {
        var prefs = context.preferences
        preferenceLearner.applyToPreferences(&prefs)

        let evaluator = FitnessEvaluator.standard(preferences: prefs)
        let schedule = currentSchedule

        let result = await Task.detached(priority: .userInitiated) {
            let reopt = IncrementalReoptimizer()
            reopt.stabilityWeight = 3.0  // prefer stability for preview
            reopt.minimumImprovement = 0.01  // accept smaller improvements

            return reopt.reoptimize(
                currentSchedule: schedule,
                trigger: .periodicRefresh,
                context: context,
                evaluator: evaluator,
                config: .instant
            )
        }.value

        return result?.scenarios.first?.genes
    }

    // MARK: - User Feedback (#24)
    //
    // Feedback fans out to three learners:
    //   • `PreferenceLearner` — evolves per-objective weights via its
    //     meta-GA (unchanged, instance-level by design).
    //   • The per-workload `MutationBandit` — bounded LinUCB reward
    //     per operator nudges arm estimates so operators that
    //     produced accepted schedules get reinforced on subsequent
    //     runs *of the same workload*.
    //   • The per-workload `GeneAttentionHead` — a small weight step
    //     biases contextual crossover toward / away from patterns
    //     associated with accepted / rejected results.
    //
    // Routing: feedback methods read `scenario.sourceSignature` and
    // look up the matching learner bundle. This is robust under
    // multiple optimizations on different workloads — a manual edit
    // on a stale scenario from workload A correctly updates A's
    // bundle even after runs B, C have happened since. Falls back
    // to silent no-op for scenarios with no `sourceSignature` (e.g.
    // hand-built fixtures).
    //
    // Update magnitude is intentionally small (~0.1) so one noisy
    // feedback event doesn't dominate learned state; many events
    // converge.
    //
    // Known limitation: `recordManualEdit` receives `original` and
    // `edited` gene arrays but currently only uses the act of
    // editing as a global "close but not right" signal. The
    // semantic *diff* (which genes the user moved, by how much) is
    // not yet pulled into per-operator credit assignment — a future
    // refinement that would require lineage tracking per offspring.

    func acceptScenario(_ scenario: ScheduleScenario) {
        currentSchedule = scenario.genes
        preferenceLearner.recordAcceptance(scenarioFitness: scenario.fitness)
        propagateFeedbackReward(+0.1, scenario: scenario)
        // Propagate acceptance to adaptive learners: DPO + temporal warm-start
        // using whichever other scenarios from the last run act as
        // implicit runner-ups.
        let runnerUps: [ScheduleScenario] = (lastResult?.scenarios ?? [])
            .filter { $0.id != scenario.id }
        propagateAcceptFeedback(
            accepted: scenario,
            runnerUps: runnerUps,
            context: lastOptimizationContext
        )
        // Training pipeline: append to replay buffer; may trigger a
        // training cycle once the accept cadence threshold is hit.
        trainingRecordAccept(accepted: scenario, runnerUps: runnerUps)
    }

    func rejectScenario(_ scenario: ScheduleScenario) {
        preferenceLearner.recordRejection(scenarioFitness: scenario.fitness)
        propagateFeedbackReward(-0.1, scenario: scenario)
        // Model a rejection as a preference against the rejected vs.
        // the top-fitness alternative. Cheap source of DPO signal.
        if let best = lastResult?.scenarios.first, best.id != scenario.id,
           let bundle = lookupLearnerSuite(for: scenario),
           schedulingFeatures.useDPOWeightLearning {
            bundle.dpo.observe(pair: DPOPreferencePair(
                winnerScores: best.objectiveBreakdown,
                loserScores: scenario.objectiveBreakdown,
                confidence: 1.0
            ))
        }
        trainingRecordReject(
            rejected: scenario,
            allScenarios: lastResult?.scenarios ?? []
        )
    }

    func recordManualEdit(scenario: ScheduleScenario, edited: [ScheduleGene]) {
        currentSchedule = edited
        preferenceLearner.recordModification(original: scenario.genes, edited: edited)
        guard let bundle = bundle(for: scenario) else { return }
        for op in MutationOperator.allCases {
            bundle.bandit.record(op: op, reward: -0.03)
        }
        bundle.head.updateWeights(features: [1, 1, 1, 1, 1], rewardSign: -0.3)
    }

    /// Backwards-compatible overload accepting raw gene arrays. Use
    /// the `scenario`-typed overload when you have a `ScheduleScenario`
    /// in hand — it correctly routes feedback by `sourceSignature`.
    /// This overload routes via `lastRunSignature` (correct only when
    /// no later optimizations have happened).
    func recordManualEdit(original: [ScheduleGene], edited: [ScheduleGene]) {
        currentSchedule = edited
        preferenceLearner.recordModification(original: original, edited: edited)
        guard let signature = lastRunSignature,
              let bundle = learnersBySignature[signature] else { return }
        for op in MutationOperator.allCases {
            bundle.bandit.record(op: op, reward: -0.03)
        }
        bundle.head.updateWeights(features: [1, 1, 1, 1, 1], rewardSign: -0.3)
    }

    /// Resolve the learner bundle a scenario refers to. Prefers
    /// `scenario.sourceSignature` (set by `optimize()`). Falls back to
    /// `lastRunSignature` for hand-built scenarios that have no
    /// signature stamped.
    private func bundle(for scenario: ScheduleScenario) -> WorkloadLearners? {
        let key = scenario.sourceSignature ?? lastRunSignature
        guard let key else { return nil }
        return learnersBySignature[key]
    }

    /// Apply a uniform reward signal to every bandit arm and a
    /// scenario-magnitude-scaled nudge to the attention head, for
    /// the workload that produced the scenario. Uniform across
    /// operators because we don't retain per-gene lineage; LinUCB's
    /// context features already discriminate regimes, so "reinforce
    /// whatever you were doing" averages out over many feedback
    /// events.
    private func propagateFeedbackReward(_ reward: Double, scenario: ScheduleScenario) {
        guard let bundle = bundle(for: scenario) else { return }
        for op in MutationOperator.allCases {
            bundle.bandit.record(op: op, reward: reward)
        }
        let rewardSign: Double = reward == 0 ? 0 : (reward < 0 ? -1 : 1)
        let signedMagnitude = rewardSign * max(0.3, scenario.fitness)
        bundle.head.updateWeights(features: [1, 1, 1, 1, 1], rewardSign: signedMagnitude)
    }

    // MARK: - Scenario Comparison (#27)

    func compareLastScenarios() -> [ScenarioComparison] {
        guard let result = lastResult else { return [] }
        return ScenarioComparer.compare(result.scenarios)
    }

    // MARK: - Focus Block Suggestions (#1)

    func suggestFocusBlocks(
        count: Int = 2,
        durationMinutes: Int = 120,
        fixedEvents: [CalendarEvent],
        workingHours: ClosedRange<Int> = 9...18
    ) async -> OptimizerResult {
        let focusEvents = (0..<count).map { i in
            OptimizableEvent(
                title: "Focus Block \(i + 1)",
                duration: TimeInterval(durationMinutes * 60),
                priority: 0.8,
                context: "focus",
                energyCost: 0.7,
                preferredHourRange: 9...12,
                isFocusBlock: true
            )
        }

        return await optimizeToday(
            fixedEvents: fixedEvents,
            movableEvents: focusEvents,
            workingHours: workingHours
        )
    }

    // MARK: - Meeting Scheduling (#5, #16)

    func suggestMeetingSlot(
        title: String,
        durationMinutes: Int,
        participants: [String],
        fixedEvents: [CalendarEvent],
        participantAvailability: [String: [DateInterval]],
        workingHours: ClosedRange<Int> = 9...18
    ) async -> OptimizerResult {
        let meetingEvent = OptimizableEvent(
            title: title,
            duration: TimeInterval(durationMinutes * 60),
            priority: 0.9,
            context: "meeting",
            energyCost: 0.6,
            requiredParticipants: participants
        )

        return await optimizeWeek(
            fixedEvents: fixedEvents,
            movableEvents: [meetingEvent],
            workingHours: workingHours,
            participantAvailability: participantAvailability
        )
    }

    // MARK: - Pomodoro Task Sequence Optimization

    /// Optimize the order of tasks within a Pomodoro session.
    /// Uses a dedicated permutation GA (PomodoroSequenceChromosome) that considers
    /// energy curve, context switches, deadline urgency, and cognitive load alternation.
    ///
    /// Returns tasks reordered for optimal execution within the session.
    func optimizePomodoroSequence(
        tasks: [OptimizableEvent],
        sessionStart: Date = Date(),
        weights: PomodoroSequenceEvaluator.Weights = .default
    ) async -> [OptimizableEvent] {
        guard tasks.count > 1 else { return tasks }

        let capturedTasks = tasks
        let capturedStart = sessionStart
        let capturedWeights = weights
        let capturedPrefs = preferences

        return await Task.detached(priority: .userInitiated) {
            PomodoroSequenceOptimizer.optimize(
                tasks: capturedTasks,
                sessionStart: capturedStart,
                preferences: capturedPrefs,
                config: .quick,
                weights: capturedWeights
            )
        }.value
    }

    // MARK: - Day Planning (#6)

    func planDay(
        tasks: [OptimizableEvent],
        fixedEvents: [CalendarEvent],
        workingHours: ClosedRange<Int> = 9...18
    ) async -> OptimizerResult {
        await optimizeToday(
            fixedEvents: fixedEvents,
            movableEvents: tasks,
            workingHours: workingHours
        )
    }

    // MARK: - Day Planning with Pomodoro Sequencing

    /// Two-phase optimization:
    /// 1. Schedule GA places tasks in optimal time slots
    /// 2. Sequence GA optimizes task execution order within each day
    ///
    /// The result includes `taskSequenceByDay` on each scenario, indicating
    /// the recommended execution order for tasks grouped on the same day.
    func planDayWithSequencing(
        tasks: [OptimizableEvent],
        fixedEvents: [CalendarEvent],
        workingHours: ClosedRange<Int> = 9...18,
        sequenceWeights: PomodoroSequenceEvaluator.Weights = .default
    ) async -> OptimizerResult {
        // Phase 1: place tasks in time slots
        var result = await planDay(
            tasks: tasks,
            fixedEvents: fixedEvents,
            workingHours: workingHours
        )

        // Phase 2: optimize task order within each day per scenario
        let taskMap = Dictionary(uniqueKeysWithValues: tasks.map { ($0.id, $0) })
        let cal = Calendar.current
        let capturedPrefs = preferences
        let capturedWeights = sequenceWeights

        // Build all sequence optimization work items across all scenarios
        struct SequenceJob: Sendable {
            let scenarioIndex: Int
            let day: Date
            let tasks: [OptimizableEvent]
            let sessionStart: Date
        }

        var jobs: [SequenceJob] = []
        var trivialSequences: [(scenarioIndex: Int, day: Date, eventIds: [String])] = []

        for (scenarioIndex, scenario) in result.scenarios.enumerated() {
            var genesByDay: [Date: [ScheduleGene]] = [:]
            for gene in scenario.genes {
                let day = cal.startOfDay(for: gene.startTime)
                genesByDay[day, default: []].append(gene)
            }

            for (day, dayGenes) in genesByDay {
                let dayTasks = dayGenes.compactMap { taskMap[$0.eventId] }
                if dayTasks.count > 1 {
                    let sessionStart = dayGenes.map(\.startTime).min() ?? day
                    jobs.append(SequenceJob(
                        scenarioIndex: scenarioIndex,
                        day: day,
                        tasks: dayTasks,
                        sessionStart: sessionStart
                    ))
                } else {
                    trivialSequences.append((scenarioIndex, day, dayGenes.map(\.eventId)))
                }
            }
        }

        // Spawn all sequence optimizations in parallel
        let parallelTasks = jobs.map { job in
            (job, Task.detached(priority: .userInitiated) {
                PomodoroSequenceOptimizer.optimize(
                    tasks: job.tasks,
                    sessionStart: job.sessionStart,
                    preferences: capturedPrefs,
                    config: .quick,
                    weights: capturedWeights
                )
            })
        }

        // Collect results
        var sequencesByScenario: [Int: [Date: [String]]] = [:]
        for (scenarioIndex, day, eventIds) in trivialSequences {
            sequencesByScenario[scenarioIndex, default: [:]][day] = eventIds
        }

        // Await all parallel tasks
        for (job, task) in parallelTasks {
            let ordered = await task.value
            sequencesByScenario[job.scenarioIndex, default: [:]][job.day] = ordered.map(\.id)
        }

        // Build enhanced scenarios
        let enhancedScenarios = result.scenarios.enumerated().map { (idx, scenario) -> ScheduleScenario in
            var enhanced = scenario
            enhanced.taskSequenceByDay = sequencesByScenario[idx]
            return enhanced
        }

        result = OptimizerResult(
            scenarios: enhancedScenarios,
            metadata: result.metadata
        )
        lastResult = result
        return result
    }

    // MARK: - Meeting Clustering

    /// Optimize meeting placement to cluster meetings together,
    /// maximizing continuous focus blocks during the rest of the day.
    func clusterMeetings(
        meetings: [OptimizableEvent],
        fixedEvents: [CalendarEvent],
        workingHours: ClosedRange<Int> = 9...18
    ) async -> OptimizerResult {
        // Boost clustering weight for this specific optimization
        var prefs = preferences
        prefs.meetingClusteringWeight = max(prefs.meetingClusteringWeight, 2.0)
        prefs.focusBlockWeight = max(prefs.focusBlockWeight, 1.5)

        let cal = Calendar.current
        let todayStart = cal.startOfDay(for: Date())
        let todayEnd = cal.date(byAdding: .day, value: 1, to: todayStart)!

        let context = OptimizerContext(
            fixedEvents: fixedEvents.filter { $0.startDate >= todayStart && $0.startDate < todayEnd },
            movableEvents: meetings,
            workingHours: workingHours,
            planningHorizon: DateInterval(start: max(Date(), todayStart), end: todayEnd),
            preferences: prefs
        )

        return await optimize(context: context, overrideConfig: .quick, overrideIslandConfig: .quick)
    }

    // MARK: - Week Balancing (#9)

    func balanceWeek(
        movableEvents: [OptimizableEvent],
        fixedEvents: [CalendarEvent],
        workingHours: ClosedRange<Int> = 9...18
    ) async -> OptimizerResult {
        await optimizeWeek(
            fixedEvents: fixedEvents,
            movableEvents: movableEvents,
            workingHours: workingHours
        )
    }

    // MARK: - Reset

    func reset() {
        preferenceLearner.reset()
        currentSchedule = []
        lastResult = nil
        preferences = OptimizerPreferences()
        lastOptimizationContext = nil
    }
}
