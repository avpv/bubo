import Foundation
import os

/// Diagnostics log for `optimizeWeek` — captures the input workload
/// (working window, busy fixed slots, tasks) and the scenarios the GA
/// produced (placements per day, dropped tasks, fitness breakdown). Read
/// via Console.app → subsystem `com.avpv.Bubo`, category `PlanWeek`.
///
/// We keep both `OSLog` and `Logger` references: `Logger`'s typed
/// interpolation is what we actually emit with, but `OSLog` lets us
/// call `isEnabled(type:)` and skip the (very expensive — 50–200 line
/// multi-line messages) diagnostic body when the level is filtered
/// out. Without the early check, every PlanWeek invocation eagerly
/// builds a multi-kilobyte string even when no one is listening.
private let planWeekOSLog = OSLog(subsystem: "com.avpv.Bubo", category: "PlanWeek")
private let planWeekLogger = Logger(planWeekOSLog)

/// Per-run summary log — one line at the end of every `optimize()` call
/// with GA telemetry, cache stats, and top-level constraint counts.
/// Separated from `PlanWeek` (which is verbose multi-line diagnostics
/// gated on `.info`) so these stats remain on in release without
/// dragging kilobytes of per-run narrative with them.
private let gaStatsLogger = Logger(subsystem: "com.avpv.Bubo", category: "Optimizer/GA")

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
        overrideIslandConfig: IslandConfiguration? = nil,
        rid: String? = nil
    ) async -> OptimizerResult {
        isOptimizing = true
        defer { isOptimizing = false }

        // Correlation id is either supplied by the caller
        // (IntentCompiler mints one at `execute()` entry) or minted
        // here as a fallback so non-IntentCompiler callers — today
        // none, tomorrow maybe — still produce a correlatable trail.
        let runId = rid ?? String(format: "%08x", UInt32.random(in: .min ... .max))

        let planWeekWallStart = Date()
        // Snapshot `cachedCount` before the run so the terminal log
        // can emit *per-run* cold misses (new whole-graph entries
        // added). Captures the common case cleanly; re-validation
        // misses on existing keys aren't counted — they don't change
        // `cachedCount` — but those are the cheap kind anyway.
        let intentCacheSizeBefore = intentGraphCache.cachedGraphCount
        let conflictCacheSizeBefore = conflictGraphCache.cachedGraphCount

        // Apply learned preferences, merging with (not replacing) user preferences
        var prefs = context.preferences
        preferenceLearner.applyToPreferences(&prefs)
        // Learner-driven preference prelude: DPO weight overlay +
        // chance-constrained buffer fit applied on top of user prefs.
        // Both are safe no-ops when their feature flags are off.
        adjustPreferencesFromLearners(prefs: &prefs, context: context)

        // Adaptive workload weights: on sparse days lean into energy-curve
        // placement, on packed days defer to compactness. Sits after the
        // learner pass so the boost compounds the personalised baseline
        // rather than the raw default. The same `difficulty` scalar is
        // reused below for GA-config dispatch — compute it once here.
        let workloadDiff = workloadDifficulty(
            movableEvents: context.movableEvents,
            fixedEvents: context.fixedEvents
        )
        applyAdaptiveWorkloadWeights(prefs: &prefs, difficulty: workloadDiff, runId: runId)

        logPlanWeekInputs(
            fixedEvents: context.fixedEvents,
            movableEvents: context.movableEvents,
            workingHours: context.workingHours,
            horizon: context.planningHorizon,
            prefs: prefs,
            gaCfg: overrideConfig ?? gaConfig,
            islandCfg: overrideIslandConfig ?? islandConfig
        )

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
        // CP-SAT as feasibility-optimal construction seeder. The
        // repair-side use was retired (handwritten B&B matches it on
        // the realistic workloads we measured), but as a *seeder* the
        // solver buys something different: one guaranteed-feasible
        // initial individual that already optimises the hard + mid
        // lex tiers (inclusion, deadline, backlog order) before the
        // GA starts polishing the soft tier. When the flag is off or
        // the solver times out, the warm-start collector silently
        // skips the CP-SAT seed and the population stays
        // greedy + random + GNN.
        let cpSATToInject: CPSATRepairer? = schedulingFeatures.useCPSATSeed
            ? CPSATRepairer()
            : nil
        // One shared slot registry + per-gene domain cache for the
        // whole run. Every island context inherits the same holders,
        // so registry build happens once and each movable event's
        // feasible-slot domain is computed once — every mutation
        // afterwards gets an O(1) read instead of the old per-call
        // `allowedIndices` binary search + fixed-event overlap scan.
        let slotRegistryHolder = SlotRegistryHolder()
        let slotDomainsHolder = SlotDomainsHolder()
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
            cpSATWindowThreshold: schedulingFeatures.cpSATWindowThreshold,
            slotRegistryHolder: slotRegistryHolder,
            slotDomainsHolder: slotDomainsHolder
        )
        // Stash for learner-feedback callbacks (acceptScenario etc).
        lastOptimizationContext = adjustedContext

        let evaluator = FitnessEvaluator.standard(preferences: prefs)
        let capturedScenarioCount = scenarioCount

        // Single-site anchor decision via `AnchorSeeder`: the seeder
        // owns every CP-SAT / greedy branch (flag off, window
        // exceeded, solver timeout, infeasible sub-problem) so both
        // `optimize()` and `reoptimize()` produce attributable
        // anchors through the same code path. The pipeline is
        // unconditionally `anchor → GA polish/refine`; the fallback
        // is always a feasibility-by-construction greedy chromosome
        // so there's never an "anchor-less" branch the GA config
        // has to reason about.
        let seeder = AnchorSeeder(gates: AnchorSeeder.Gates(
            cpsatEnabled: schedulingFeatures.useCPSATSeed,
            windowThreshold: schedulingFeatures.cpSATWindowThreshold
        ))
        let (anchorSeed, anchorProvenance) = seeder.makeAnchor(
            context: adjustedContext,
            mode: .firstRun
        )
        let anchorSource = anchorProvenance.logLabel
        let cpSATDurationMs = anchorProvenance.cpsatDurationMs

        // GA-config dispatch: we now always have an anchor — the GA's
        // job is to polish or refine around it. The choice between
        // presets is driven by the *workload* (how big the search
        // space is), not by whether CP-SAT succeeded:
        //
        //   difficulty < 0.25  → `.polish`
        //   difficulty < 0.6   → `.refine`
        //   difficulty ≥ 0.6   → caller's config (anchor is a hint)
        //
        // An explicit `overrideConfig` always wins so programmatic
        // callers (tests, training pipeline) keep their current
        // behaviour unchanged.
        // `workloadDiff` was computed up front (see prefs adjustments
        // above) so the same scalar drives both adaptive weights and
        // GA-config dispatch.
        let difficulty = workloadDiff
        let dispatchMode: String
        var config: GAConfiguration
        var capturedIslandConfig: IslandConfiguration
        if let override = overrideConfig {
            config = override
            capturedIslandConfig = overrideIslandConfig ?? islandConfig
            dispatchMode = "override"
        } else if difficulty < Self.trivialWorkloadDifficulty {
            config = .polish
            capturedIslandConfig = Self.singleIslandConfig(from: islandConfig)
            dispatchMode = "polish"
        } else if difficulty < Self.mediumWorkloadDifficulty {
            config = .refine
            capturedIslandConfig = Self.singleIslandConfig(from: islandConfig)
            dispatchMode = "refine"
        } else {
            config = gaConfig
            capturedIslandConfig = overrideIslandConfig ?? islandConfig
            dispatchMode = "seeded_full"
        }

        // Difficulty cap for explicit overrides on trivial workloads.
        // Polish / refine / seeded_full presets are already sized
        // against difficulty — only `override` escapes the dispatch
        // and can arrive too heavy for a 4-task week.
        if dispatchMode == "override",
           difficulty < Self.trivialWorkloadDifficulty {
            let capPop = max(20, Int(Double(config.populationSize) * 0.25))
            let capGen = max(20, Int(Double(config.maxGenerations) * 0.15))
            let capWall = max(0.8, config.wallclockTimeout * 0.15)
            let capPatience = max(8, config.convergencePatience / 3)
            let originalPop = config.populationSize
            let originalTimeout = config.wallclockTimeout
            config.populationSize = min(config.populationSize, capPop)
            config.maxGenerations = min(config.maxGenerations, capGen)
            config.wallclockTimeout = min(config.wallclockTimeout, capWall)
            config.convergencePatience = min(config.convergencePatience, capPatience)
            capturedIslandConfig = Self.singleIslandConfig(from: capturedIslandConfig)
            gaStatsLogger.info("workload_downshift rid=\(runId, privacy: .public) difficulty=\(difficulty) pop=\(originalPop)→\(config.populationSize) gen=\(config.maxGenerations) wallclock=\(String(format: "%.1f", originalTimeout))s→\(String(format: "%.1f", config.wallclockTimeout))s")
        }

        gaStatsLogger.info("dispatch rid=\(runId, privacy: .public) mode=\(dispatchMode, privacy: .public) difficulty=\(difficulty) anchor=\(anchorSource, privacy: .public) cpsat_ms=\(cpSATDurationMs) pop=\(config.populationSize) gen=\(config.maxGenerations) wallclock=\(String(format: "%.1f", config.wallclockTimeout))s")

        // Survivor selector: adaptive NSGA-III with HypE-lite
        // tiebreak. The MOEA/D-AWA alternative was retired along
        // with its feature flag — NSGA-III consistently matched it
        // on realistic 14-objective workloads.
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
            hypervolumeSampleCount: hvSamples
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

        let hookComponents: [EvolutionHooks<ScheduleChromosome>] = [
            ScheduleEvolutionHooks.qualityDiversityFeeding(archive: qdArchive),
            ScheduleEvolutionHooks.qualityDiversityEmission(archive: qdArchive, emissionRate: 0.12),
            ScheduleEvolutionHooks.gradientRefinement(
                refiner: gradientRefiner,
                interval: 35,
                candidates: 3,
                evaluate: surrogateAssistedEvaluator
            ),
        ]
        // CMA-ME emitter retired — the uniform MAP-Elites emitter
        // delivered equivalent archive coverage on realistic
        // workloads without the per-generation matrix update cost.
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
        // Collect warm-start seeds from the learner suite so the
        // initial population starts inside the basin of recent
        // accepted solutions and respects GNN-derived priorities.
        let extraSeeds: [ScheduleChromosome] = collectWarmStartSeeds(context: adjustedContext)
        // Migration-topology bandit retired — adaptive migration
        // interval in IslandModelGA already reacts to stagnation.

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

        // Capture the anchor-replication fraction here so the detached
        // task doesn't have to reach back into the @MainActor type.
        let capturedAnchorFraction = Self.anchorReplicationFraction(forMode: dispatchMode)

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
                anchorSeed: anchorSeed,
                anchorReplicationFraction: capturedAnchorFraction,
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
        //     taskSpreadDays / morningShare / lastTaskHour —
        //     movable-placement-driven axes — to pick the *display*
        //     set of scenarios. Different axes serve different consumers,
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
        gaStatsLogger.info("map_elites_archive rid=\(runId, privacy: .public) cells=\(archive.cells.count) capacity=\(archive.capacity) requested=\(capturedScenarioCount)")
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

        let snapshot = evaluator.telemetry.snapshot()
        let wallMs = Int(Date().timeIntervalSince(planWeekWallStart) * 1000)
        let best = scenarios.first
        let violationCount = best?.constraintViolations.count ?? 0
        let droppedCount = best?.droppedCount ?? 0
        let bestFitness = best?.fitness ?? 0
        let intentCacheAdded = intentGraphCache.cachedGraphCount - intentCacheSizeBefore
        let conflictCacheAdded = conflictGraphCache.cachedGraphCount - conflictCacheSizeBefore
        // One-line event keeps OSLog interpolation happy (no literal
        // newlines embedded in the format string) and matches the
        // `event k=v k=v` convention used by the rest of the app.
        // `intent_cache_new` / `conflict_cache_new` are the number of
        // cold misses this run added to each whole-graph cache — a
        // good proxy for "how much of the plan was novel". Zero
        // means every cache lookup hit a warm entry.
        gaStatsLogger.info("ga_run_stats rid=\(runId, privacy: .public) scenarios=\(scenarios.count) generations=\(convergenceGen) best_fitness=\(bestFitness) violations=\(violationCount) dropped=\(droppedCount) full_evals=\(snapshot.fullEvaluations) delta_evals=\(snapshot.deltaEvaluations) eval_cache_hits=\(snapshot.cacheHits) delta_fraction=\(snapshot.deltaFraction) cache_hit_fraction=\(snapshot.cacheHitFraction) constraint_rejections=\(snapshot.constraintRejections) intent_cache_new=\(intentCacheAdded) conflict_cache_new=\(conflictCacheAdded) duration_ms=\(wallMs)")

        logPlanWeekResult(
            result: result,
            movableEvents: context.movableEvents,
            wallDuration: Date().timeIntervalSince(planWeekWallStart),
            context: context,
            telemetry: snapshot
        )
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

        // `workingDays` is a non-optional `Set<Int>` on preferences
        // (default Mon–Fri); pass `preferences` through as-is. Direct
        // callers that don't override `workingDays` in their own
        // `OptimizerPreferences()` get the Mon–Fri default baked into
        // the initializer.
        let context = OptimizerContext(
            fixedEvents: fixedEvents,
            movableEvents: movableEvents,
            workingHours: workingHours,
            planningHorizon: DateInterval(start: now, end: weekEnd),
            preferences: preferences,
            participantAvailability: participantAvailability
        )

        // No `overrideConfig` here — let `optimize()` choose via its
        // own CP-SAT → dispatch pipeline:
        //   difficulty < 0.25  → `.polish`
        //   difficulty < 0.6   → `.refine`
        //   otherwise          → the instance's `gaConfig`
        // The old `configForWorkload` inline-interpolation was
        // duplicating this logic with slightly different constants
        // and bypassing the polish / refine presets by arriving as
        // an override. Removed for a single source of truth.
        return await optimize(context: context)
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

        return max(Self.workloadDifficultyFloor, min(1.0, max(countFactor, densityFactor)))
    }

    // MARK: - Adaptive Soft-Objective Weights

    /// Pure boost factor for a given workload difficulty.
    ///
    /// Interpolates linearly from 1 at a near-empty day (difficulty ≈
    /// `workloadDifficultyFloor`, the floor returned by
    /// `workloadDifficulty`) to 0 at `trivialWorkloadDifficulty` and
    /// stays 0 above. Pulled out as a static so tests can pin the
    /// curve shape without spinning up a full optimizer.
    static func adaptiveWorkloadBoost(difficulty: Double) -> Double {
        let trivial = trivialWorkloadDifficulty
        let floor = workloadDifficultyFloor
        guard difficulty < trivial else { return 0 }
        return max(0.0, min(1.0, (trivial - difficulty) / (trivial - floor)))
    }

    /// Reweight soft objectives in place by `adaptiveWorkloadBoost`.
    ///
    /// On sparse days (`difficulty < trivialWorkloadDifficulty`) there
    /// is slack to chase energy-curve placement: the user's peak hours
    /// are the right anchor and a compact day buys nothing because the
    /// day is already mostly empty. On packed days compactness wins —
    /// fragmenting across the few free pockets costs more than landing
    /// one task an hour off-peak. Multipliers are relative so any
    /// personalised baseline (learner overrides, custom user weights)
    /// scales proportionally. Returns the boost so the caller can log
    /// it; returns 0 when no change was applied.
    @discardableResult
    static func applyAdaptiveWorkloadWeights(
        prefs: inout OptimizerPreferences,
        difficulty: Double
    ) -> Double {
        let boost = adaptiveWorkloadBoost(difficulty: difficulty)
        guard boost > 0 else { return 0 }

        let originalCompactness = prefs.dayCompactnessWeight
            ?? OptimizerPreferences.defaultDayCompactnessWeight

        prefs.energyCurveWeight *= 1.0 + boost * 1.0
        prefs.taskPlacementWeight *= 1.0 + boost * 0.5
        prefs.dayCompactnessWeight = originalCompactness * (1.0 - boost * 0.7)
        return boost
    }

    /// Instance wrapper: applies the adaptive weights and emits a
    /// `weight_adaptation` event on the GA stats channel so before/after
    /// values land alongside the rest of the run telemetry.
    private func applyAdaptiveWorkloadWeights(
        prefs: inout OptimizerPreferences,
        difficulty: Double,
        runId: String
    ) {
        let originalEnergy = prefs.energyCurveWeight
        let originalPlacement = prefs.taskPlacementWeight
        let originalCompactness = prefs.dayCompactnessWeight
            ?? OptimizerPreferences.defaultDayCompactnessWeight

        let boost = Self.applyAdaptiveWorkloadWeights(
            prefs: &prefs,
            difficulty: difficulty
        )
        guard boost > 0 else { return }

        let updatedEnergy = prefs.energyCurveWeight
        let updatedPlacement = prefs.taskPlacementWeight
        let updatedCompactness = prefs.dayCompactnessWeight ?? originalCompactness

        gaStatsLogger.info(
            "weight_adaptation rid=\(runId, privacy: .public) difficulty=\(String(format: "%.3f", difficulty)) boost=\(String(format: "%.2f", boost)) energy=\(String(format: "%.2f", originalEnergy))→\(String(format: "%.2f", updatedEnergy)) placement=\(String(format: "%.2f", originalPlacement))→\(String(format: "%.2f", updatedPlacement)) compactness=\(String(format: "%.2f", originalCompactness))→\(String(format: "%.2f", updatedCompactness))"
        )
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
        prefs: OptimizerPreferences,
        gaCfg: GAConfiguration?,
        islandCfg: IslandConfiguration?
    ) {
        // Skip the whole diagnostic (kilobytes of string formatting) when
        // no one is listening at `.info`. The `GADebugLog.warn` anomaly
        // scan below is cheap and unconditional, so keep it outside the
        // gate.
        guard planWeekOSLog.isEnabled(type: .info) else {
            scanInputAnomalies(
                fixedEvents: fixedEvents.filter { horizon.intersects(DateInterval(start: $0.startDate, end: max($0.endDate, $0.startDate))) },
                movableEvents: movableEvents,
                horizon: horizon,
                workingHours: workingHours
            )
            return
        }

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
        let peakHours = prefs.peakEnergyHours.sorted().map(String.init).joined(separator: ",")
        let curveSource = prefs.personalEnergyCurve != nil ? "personal" : "static"
        lines.append("peak energy: {\(peakHours)} (\(curveSource) curve)")
        let effectiveCompactness = prefs.dayCompactnessWeight ?? OptimizerPreferences.defaultDayCompactnessWeight
        lines.append(String(format: "weights: energy=%.2f placement=%.2f compactness=%.2f",
                            prefs.energyCurveWeight,
                            prefs.taskPlacementWeight,
                            effectiveCompactness))
        lines.append(String(format: "tasks: %d (%.1fh total), fixed: %d (%.1fh), difficulty: %.2f",
                            movableEvents.count, movableHours,
                            fixedInWindow.count, fixedHours,
                            difficulty))

        // Busy slots per day — the "consolidated slots" view: everything
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
            let spStr = ev.storyPoints.map { " sp=\($0)" } ?? ""
            let flagStr = flags.isEmpty ? "" : " [\(flags.joined(separator: ","))]"
            lines.append(String(format: "  %2d. %.1fh p=%.2f e=%.2f%@%@%@%@%@ %@",
                                i + 1,
                                ev.duration / 3600.0,
                                ev.priority,
                                ev.energyCost,
                                spStr,
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

        // Input anomaly scan. Flags things that usually indicate a
        // parsing / ingestion bug upstream — a malformed event that
        // makes it into the GA is going to produce a surprising
        // scenario, and filtering `GADebug` by `--level warning`
        // surfaces every hit alongside the invariant checks.
        scanInputAnomalies(
            fixedEvents: fixedInWindow,
            movableEvents: movableEvents,
            horizon: horizon,
            workingHours: workingHours
        )

        planWeekLogger.info("\(lines.joined(separator: "\n"), privacy: .public)")
    }

    /// Emit `GADebugLog.warn(site: "input", …)` lines for events that
    /// look malformed at ingest time. Non-blocking — the GA still
    /// runs — but every hit is something the caller probably wants
    /// to investigate.
    private func scanInputAnomalies(
        fixedEvents: [CalendarEvent],
        movableEvents: [OptimizableEvent],
        horizon: DateInterval,
        workingHours: ClosedRange<Int>
    ) {
        // Movable-event anomalies.
        var eventIds: [String: Int] = [:]
        for event in movableEvents {
            eventIds[event.id, default: 0] += 1

            // Deadline before horizon start = guaranteed-infeasible
            // event. Either the deadline is wrong (stale task) or
            // the horizon is wrong.
            if let deadline = event.deadline, deadline < horizon.start {
                GADebugLog.warn(
                    site: "input",
                    message: "event deadline precedes horizon start",
                    context: [
                        "event": event.id,
                        "title": event.title,
                        "deadline": ISO8601DateFormatter().string(from: deadline),
                        "horizon_start": ISO8601DateFormatter().string(from: horizon.start)
                    ]
                )
            }

            // Deadline vs duration: if window is smaller than
            // duration, impossible to schedule legally.
            if let deadline = event.deadline,
               let earliest = event.earliestStart,
               deadline.timeIntervalSince(earliest) < event.duration {
                GADebugLog.warn(
                    site: "input",
                    message: "earliestStart..deadline window narrower than duration",
                    context: [
                        "event": event.id,
                        "window_sec": "\(Int(deadline.timeIntervalSince(earliest)))",
                        "duration_sec": "\(Int(event.duration))"
                    ]
                )
            }

            // Duration sanity. Zero / negative = parsing bug.
            // >12h = unusually long, possibly a `30m` parsed as hours.
            if event.duration <= 0 {
                GADebugLog.warn(
                    site: "input",
                    message: "non-positive duration",
                    context: ["event": event.id, "duration_sec": "\(Int(event.duration))"]
                )
            } else if event.duration > 12 * 3600 {
                GADebugLog.warn(
                    site: "input",
                    message: "unusually long duration (>12h) — possible parse error",
                    context: ["event": event.id, "hours": String(format: "%.1f", event.duration / 3600)]
                )
            } else if event.duration < 5 * 60 {
                GADebugLog.warn(
                    site: "input",
                    message: "unusually short duration (<5min) — possible parse error",
                    context: ["event": event.id, "minutes": String(format: "%.1f", event.duration / 60)]
                )
            }

            // Task duration longer than a whole working day — can
            // only fit if spanning the whole day, which fights most
            // soft objectives.
            let workdaySeconds = Double(workingHours.upperBound - workingHours.lowerBound) * 3600
            if event.duration > workdaySeconds {
                GADebugLog.warn(
                    site: "input",
                    message: "duration exceeds single working day",
                    context: [
                        "event": event.id,
                        "duration_h": String(format: "%.1f", event.duration / 3600),
                        "workday_h": String(format: "%.1f", workdaySeconds / 3600)
                    ]
                )
            }
        }

        // Duplicate ids.
        for (id, count) in eventIds where count > 1 {
            GADebugLog.warn(
                site: "input",
                message: "duplicate movable event id",
                context: ["event": id, "count": "\(count)"]
            )
        }

        // Fixed-event anomalies.
        for event in fixedEvents {
            if event.endDate <= event.startDate {
                GADebugLog.warn(
                    site: "input",
                    message: "fixed event has non-positive duration",
                    context: [
                        "event": event.id,
                        "start": ISO8601DateFormatter().string(from: event.startDate),
                        "end": ISO8601DateFormatter().string(from: event.endDate)
                    ]
                )
            }
        }
    }

    /// Log what the GA returned: per-scenario placements grouped by
    /// day, dropped tasks, fitness with top objective breakdown, and
    /// solver metadata (generations, convergence, wall time). Pair
    /// with `logPlanWeekInputs` to see whether the final schedule
    /// lines up with the inputs and constraints.
    private func logPlanWeekResult(
        result: OptimizerResult,
        movableEvents: [OptimizableEvent],
        wallDuration: TimeInterval,
        context: OptimizerContext,
        telemetry: FitnessEvalTelemetry.Snapshot
    ) {
        // Early-exit when `.info` is disabled — the body below formats a
        // multi-kilobyte per-scenario report that's pure wasted work if
        // no one is listening.
        guard planWeekOSLog.isEnabled(type: .info) else { return }

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

            // Weighted-contribution view: raw × weight × (1 - raw)
            // reveals which objectives are *actually* eating the
            // fitness budget, which the raw-score ordering alone
            // can miss — a low-weight objective with score 0.2
            // contributes less than a high-weight objective at
            // score 0.8. Sorted by contribution-to-loss desc so
            // the first line is "this is where your fitness went".
            let weightsByName = weightsByObjectiveName(context.preferences)
            let contributions: [(name: String, raw: Double, weight: Double, lossPct: Double)] =
                scenario.objectiveBreakdown.compactMap { entry in
                    guard let weight = weightsByName[entry.key], weight > 0 else { return nil }
                    return (entry.key, entry.value, weight, weight * (1 - entry.value))
                }
            let totalLoss = contributions.reduce(0.0) { $0 + $1.lossPct }
            if totalLoss > 0 {
                let ranked = contributions
                    .sorted { $0.lossPct > $1.lossPct }
                    .prefix(5)
                let parts = ranked.map { entry -> String in
                    let pct = Int((entry.lossPct / totalLoss * 100).rounded())
                    return "\(entry.name)=\(pct)%"
                }
                lines.append("fitness loss by: \(parts.joined(separator: ", "))")
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
                    let spStr = g.storyPoints.map { " sp=\($0)" } ?? ""
                    lines.append(String(format: "    %@-%@ (%dm) p=%.2f%@ %@",
                                        tf.string(from: g.startTime),
                                        tf.string(from: g.endTime),
                                        mins,
                                        g.priority,
                                        spStr,
                                        title))
                }
            }

            if !dropped.isEmpty {
                let entries = dropped.prefix(8).map { g -> String in
                    let title = titleById[g.eventId] ?? g.title
                    let mins = Int((g.duration / 60).rounded())
                    let spStr = g.storyPoints.map { " sp=\($0)" } ?? ""
                    return String(format: "%@ (p=%.2f%@ %dm)", title, g.priority, spStr, mins)
                }
                let suffix = dropped.count > 8 ? " (+\(dropped.count - 8) more)" : ""
                lines.append("  dropped: \(entries.joined(separator: ", "))\(suffix)")
            }
        }

        // Cross-scenario: which tasks never got placed by any scenario?
        // A task that's always dropped usually means the inputs can't
        // fit it, not that the GA missed an option.
        let everPlaced = Set(result.scenarios.flatMap { $0.activeGenes.map(\.eventId) })
        let neverPlaced = movableEvents.filter { !everPlaced.contains($0.id) }
        if !neverPlaced.isEmpty {
            let entries = neverPlaced.prefix(8).map { ev -> String in
                let mins = Int((ev.duration / 60).rounded())
                let spStr = ev.storyPoints.map { " sp=\($0)" } ?? ""
                return String(format: "%@ (p=%.2f%@ %dm)", ev.title, ev.priority, spStr, mins)
            }
            let suffix = neverPlaced.count > 8 ? " (+\(neverPlaced.count - 8) more)" : ""
            lines.append("never placed across any scenario: \(entries.joined(separator: ", "))\(suffix)")
        }

        // Mutation bandit arm usage: pulls and mean clipped reward per
        // operator. Lets a diagnostician see at a glance whether one
        // arm (usually `shift`) dominated and starved the others, or
        // whether the bandit actually tried every operator.
        let banditSnap = context.mutationBandit.snapshot
        let totalPulls = banditSnap.values.reduce(0) { $0 + $1.pulls }
        if totalPulls > 0 {
            let order: [MutationOperator] = [.shift, .moveDay, .snap, .guided, .lnsDay]
            let parts: [String] = order.compactMap { op in
                guard let t = banditSnap[op], t.pulls > 0 else { return nil }
                let name: String
                switch op {
                case .shift:   name = "shift"
                case .moveDay: name = "moveDay"
                case .snap:    name = "snap"
                case .guided:  name = "guided"
                case .lnsDay:  name = "lnsDay"
                }
                return "\(name)=\(t.pulls)(r=\(String(format: "%.3f", t.meanReward)))"
            }
            if !parts.isEmpty {
                lines.append("mutation bandit: \(parts.joined(separator: ", "))")
            }
        }

        // Working-day set + horizon breakdown so a surprising
        // placement can be root-caused to "the configured working
        // days don't match expectations" or "Monday is a public
        // holiday in the calendar but not to the solver".
        let cal2 = context.calendar
        let prefs = context.preferences
        let workingDays = prefs.workingDays
        let horizonStartDay = cal2.startOfDay(for: context.planningHorizon.start)
        let horizonLastDay = cal2.startOfDay(for: context.planningHorizon.end.addingTimeInterval(-1))
        let horizonDays = max(1, (cal2.dateComponents([.day], from: horizonStartDay, to: horizonLastDay).day ?? 0) + 1)
        var workDays = 0
        for offset in 0..<horizonDays {
            guard let day = cal2.date(byAdding: .day, value: offset, to: horizonStartDay) else { continue }
            if !prefs.isWorkingDay(day, calendar: cal2) { continue }
            workDays += 1
        }
        // Weekday abbreviations in sorted 1→7 order (Sun, Mon, …, Sat).
        let weekdayAbbrev = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
        let daysLabel = workingDays.sorted().compactMap { idx -> String? in
            guard idx >= 1, idx <= 7 else { return nil }
            return weekdayAbbrev[idx - 1]
        }.joined(separator: ",")
        lines.append("flags: workingDays=[\(daysLabel)], workDaysInHorizon=\(workDays)/\(horizonDays)")

        // Slot-registry footprint: total valid slots in the discrete
        // search space the GA operated on. Orders-of-magnitude smaller
        // than the continuous Date range, which is the whole point of
        // the slot-based decoder — see the "Slot-Based Decoder"
        // MARK in Chromosome.swift. Stride is auto-detected by
        // `SlotRegistry.autoDetectStride` — 15-min when the workload
        // is aligned, 5-min when a fixed event / movable duration
        // introduces off-quarter minutes.
        let slotRegistry = context.ensureSlotRegistry()
        let strideMinutes = Int((slotRegistry.stride / 60).rounded())
        lines.append("slots: registry=\(slotRegistry.count), stride=\(strideMinutes)m")

        // Fitness evaluator telemetry — δ-eval hit rate + constraint
        // rejection count. A δ-hit rate below ~50% flags that recent
        // mutations aren't getting the partitioned-objective speedup
        // (usually because mutations affect many days or the mutated
        // hint is missing). A rising `constraintRejections` count
        // means many chromosomes fail `ConstraintEngine.isValid` and
        // are getting the infeasible gradient scaling — fine during
        // early generations, symptomatic late.
        let total = telemetry.total
        if total > 0 {
            let deltaPct = Int((telemetry.deltaFraction * 100).rounded())
            let cachePct = Int((telemetry.cacheHitFraction * 100).rounded())
            lines.append(String(
                format: "fitness evals: total=%d full=%d delta=%d(%d%%) cache=%d(%d%%) rejections=%d",
                total,
                telemetry.fullEvaluations,
                telemetry.deltaEvaluations, deltaPct,
                telemetry.cacheHits, cachePct,
                telemetry.constraintRejections
            ))
        }

        // Slot-binding coverage on the best scenario: how many genes
        // actually carry a registry-bound `slotIndex`. A coverage
        // number below 1.0 flags genes that slipped through a
        // producer that still uses `withStartTime` — useful for
        // spotting reoptimizer/warm-start regressions after the
        // slot-decoder migration.
        if let best = result.scenarios.first {
            let active = best.activeGenes
            if !active.isEmpty {
                let bound = active.filter { $0.slotIndex != nil }.count
                let coverage = Double(bound) / Double(active.count)
                lines.append(String(format: "slots: coverage=%.2f (%d/%d active genes slot-bound)",
                                    coverage, bound, active.count))
            }
        }

        // Constraint breakdown on the best scenario. Lets a
        // diagnostician see at a glance *which* constraint(s) are
        // eating fitness — e.g. a dominant `Buffer` penalty hints at
        // too-tight back-to-back placements, while a dominant
        // `MaxMeetingsPerDay` penalty hints at a cap the user should
        // raise. Prints the top-5 penalising constraints (soft or
        // hard) with their raw penalty magnitude.
        if let best = result.scenarios.first {
            let scenarioChromosome = ScheduleChromosome(
                genes: best.genes,
                needsEvaluation: false
            )
            let engine = ConstraintEngine.standard
            let breakdown = engine.breakdown(for: scenarioChromosome, context: context)
                .filter { $0.penalty > 0 }
                .sorted { $0.penalty > $1.penalty }
                .prefix(5)
            if !breakdown.isEmpty {
                let parts = breakdown.map { entry -> String in
                    let kind = entry.isHard ? "H" : "S"
                    return "\(entry.name)[\(kind)]=\(String(format: "%.1f", entry.penalty))"
                }
                lines.append("constraints: \(parts.joined(separator: ", "))")
            }
        }

        planWeekLogger.info("\(lines.joined(separator: "\n"), privacy: .public)")
    }

    /// Map `FitnessObjective.name` → weight from the current
    /// preferences. Used by the weighted-contribution diagnostic
    /// in the result log. Names must match the `FitnessObjective.name`
    /// strings at each objective's call site in
    /// `Bubo/Optimizer/Fitness/Objectives/`.
    private func weightsByObjectiveName(_ prefs: OptimizerPreferences) -> [String: Double] {
        return [
            "FocusBlock":         prefs.focusBlockWeight,
            "PomodoroFit":        prefs.pomodoroFitWeight,
            "Conflict":           prefs.conflictWeight,
            "TaskPlacement":      prefs.taskPlacementWeight,
            "WeekBalance":        prefs.weekBalanceWeight,
            "EnergyBalance":      prefs.energyCurveWeight,
            "MultiPerson":        prefs.multiPersonWeight,
            "BreakPlacement":     prefs.breakWeight,
            "Deadline":           prefs.deadlineWeight,
            "ContextSwitch":      prefs.contextSwitchWeight,
            "Buffer":             prefs.bufferWeight,
            "MeetingClustering":  prefs.meetingClusteringWeight,
            "TaskInclusion":      prefs.taskInclusionWeight,
            "BacklogOrder":       prefs.backlogOrderWeight ?? OptimizerPreferences.defaultBacklogOrderWeight,
            "DayCompactness":     prefs.dayCompactnessWeight ?? OptimizerPreferences.defaultDayCompactnessWeight
        ]
    }

    /// Workloads below this difficulty scalar get their GA budget
    /// capped in `optimize` even when the caller supplied a heavier
    /// `overrideConfig`. A 4-task week with no conflicts scores
    /// around 0.18 via `workloadDifficulty`; the 0.25 threshold lets
    /// that case and similar-sized backlogs escape the `.thorough`
    /// budget without forcing the downshift on mid-sized weeks that
    /// genuinely benefit from more generations.
    static let trivialWorkloadDifficulty: Double = 0.25

    /// Lower bound returned by `workloadDifficulty` for an
    /// almost-empty schedule. Anchors the high end of the
    /// adaptive-weight boost so a 1-task no-meeting day yields
    /// `boost ≈ 1.0`.
    static let workloadDifficultyFloor: Double = 0.05

    /// Upper bound on difficulty where `.refine` is still the right
    /// GA config when CP-SAT delivered an anchor. Above this the
    /// workload has genuine exploration need even with a good start
    /// — fall through to the caller's configured preset so the
    /// heavier machinery (multi-island, memetic hill climb,
    /// adaptive mutation) gets a chance to fire.
    private static let mediumWorkloadDifficulty: Double = 0.6

    /// Fraction of each island's initial population seeded as
    /// mutated copies of the CP-SAT anchor, chosen by dispatch mode.
    /// Higher in `polish` (tight cloud around the lex-optimum,
    /// minimal exploration) and lower in `seeded_full` (anchor is
    /// one hint among many, GA still needs room to search).
    private static func anchorReplicationFraction(forMode mode: String) -> Double {
        switch mode {
        case "polish":      return 0.6
        case "refine":      return 0.4
        case "seeded_full": return 0.2
        default:            return 0.0
        }
    }

    /// Collapse the supplied island configuration to a single-island
    /// variant, preserving migration and replacement policies so any
    /// downstream code that reads them stays happy. Used by the
    /// polish / refine dispatch because multi-island only pays off
    /// when the populations per island are large enough for
    /// migration to meaningfully diversify — not the case here.
    private static func singleIslandConfig(from source: IslandConfiguration) -> IslandConfiguration {
        guard source.islandCount > 1 else { return source }
        return IslandConfiguration(
            islandCount: 1,
            migrationInterval: source.migrationInterval,
            migrationSize: source.migrationSize,
            topology: source.topology,
            emigrantSelection: source.emigrantSelection,
            immigrantReplacement: source.immigrantReplacement,
            diversifyIslands: false,
            adaptiveMigration: false,
            routeByProductivity: false
        )
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

        // Wire the same CP-SAT infrastructure `optimize()` uses so
        // the reopt path can produce a warm-started CP-SAT anchor
        // via `AnchorSeeder`. Callers of `BuboOptimizer.reoptimize`
        // pass raw contexts that typically don't plumb a repairer
        // themselves; injecting it here keeps the feature-flag
        // decision centralised in this file.
        let reoptContext = makeReoptContext(from: context)

        let result = await Task.detached(priority: .userInitiated) {
            reopt.reoptimize(
                currentSchedule: schedule,
                trigger: trigger,
                context: reoptContext,
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
        let reoptContext = makeReoptContext(from: context)

        let result = await Task.detached(priority: .userInitiated) {
            let reopt = IncrementalReoptimizer()
            reopt.stabilityWeight = 3.0  // prefer stability for preview
            reopt.minimumImprovement = 0.01  // accept smaller improvements

            return reopt.reoptimize(
                currentSchedule: schedule,
                trigger: .periodicRefresh,
                context: reoptContext,
                evaluator: evaluator,
                config: .instant
            )
        }.value

        return result?.scenarios.first?.genes
    }

    /// Produce a reopt-ready copy of a caller-supplied context that
    /// carries the CP-SAT repairer and window threshold currently
    /// configured via `schedulingFeatures`. Returned unchanged when
    /// the caller already supplied a repairer (tests) or when the
    /// feature flag is off.
    private func makeReoptContext(from context: OptimizerContext) -> OptimizerContext {
        if context.cpSATRepairer != nil || !schedulingFeatures.useCPSATSeed {
            return context
        }
        return OptimizerContext(
            fixedEvents: context.fixedEvents,
            movableEvents: context.movableEvents,
            workingHours: context.workingHours,
            planningHorizon: context.planningHorizon,
            preferences: context.preferences,
            participantAvailability: context.participantAvailability,
            calendar: context.calendar,
            rng: context.rng,
            mutationBandit: context.mutationBandit,
            lnsStrategyBandit: context.lnsStrategyBandit,
            lnsRepairBandit: context.lnsRepairBandit,
            contextualCrossoverHead: context.contextualCrossoverHead,
            conflictGraphHolder: context.conflictGraphHolder,
            tabuMemory: context.tabuMemory,
            cpSATRepairer: CPSATRepairer(),
            cpSATWindowThreshold: schedulingFeatures.cpSATWindowThreshold,
            slotRegistryHolder: context.slotRegistryHolder,
            slotDomainsHolder: context.slotDomainsHolder
        )
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
