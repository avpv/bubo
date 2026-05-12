import Foundation
import os

/// Per-run summary log — one line at the end of every `optimize()` call
/// with GA telemetry, cache stats, and top-level constraint counts.
/// Separated from `PlanWeek` (which is verbose multi-line diagnostics
/// gated on `.info` and lives in `BuboOptimizer+Diagnostics.swift`) so
/// these stats remain on in release without dragging kilobytes of
/// per-run narrative with them.
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
public final class BuboOptimizer {

    // MARK: - Components

    public let preferenceLearner = PreferenceLearner()
    public let reoptimizer = IncrementalReoptimizer()

    /// Number of scenarios to return per optimization.
    public var scenarioCount: Int = 3

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
    public final class WorkloadLearners {
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

    // Visibility is `internal` (default) so the `BuboOptimizer+Feedback`
    // extension in a sibling file can route feedback rewards by signature.
    // Mutation still goes through `learners(for:)` to keep the LRU policy
    // in one place; external callers should treat these as read-only.
    public var learnersBySignature: [TaskSignature: WorkloadLearners] = [:]
    public var learnerLRU: [TaskSignature] = []

    /// Maximum number of distinct task signatures whose learner
    /// bundles are kept in memory. Older bundles evict on overflow.
    /// Default 8 covers most users (2-3 active calendars + a few
    /// experimental ones); raise for power users juggling many
    /// distinct task pools.
    public var maxCachedLearnerBundles: Int = 8

    /// Signature of the most recent optimize() invocation. Used by
    /// feedback methods to find the learner bundle to update.
    private(set) var lastRunSignature: TaskSignature?

    /// Look up (or create) the learner bundle for `context`'s task
    /// signature. Refreshes LRU position. Evicts oldest on overflow.
    public func learners(for context: OptimizerContext) -> WorkloadLearners {
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

    public let intentGraphCache = IntentGraphSalsaCache()
    public let conflictGraphCache = ScheduleConflictGraphSalsaCache()

    // MARK: - State
    //
    // Setters are `internal` (no `private(set)`) so the sibling extension
    // files (`BuboOptimizer+SpecializedPlanning`, `BuboOptimizer+Feedback`)
    // can stamp results without routing every write through a delegating
    // method. External consumers should still treat these as read-only.

    public var isOptimizing = false
    public var lastResult: OptimizerResult?

    /// The current schedule genes (movable events placement).
    public var currentSchedule: [ScheduleGene] = []

    /// Captured from the most recent `optimize()` call — used by adaptive
    /// feedback methods to record accepted/rejected outcomes into the
    /// temporal warm-start store and buffer fit. Cleared by `reset()`.
    private(set) var lastOptimizationContext: OptimizerContext?

    // MARK: - Configuration

    public var gaConfig: GAConfiguration = .default
    public var islandConfig: IslandConfiguration = .default
    public var preferences: OptimizerPreferences = OptimizerPreferences()

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
    public func optimize(
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

    // MARK: - Adaptive Soft-Objective Weights

    /// Pure boost factor for a given workload difficulty.
    ///
    /// Interpolates linearly from 1 at a near-empty day (difficulty ≈
    /// `workloadDifficultyFloor`, the floor returned by
    /// `workloadDifficulty`) to 0 at `trivialWorkloadDifficulty` and
    /// stays 0 above. Pulled out as a static so tests can pin the
    /// curve shape without spinning up a full optimizer.
    public static func adaptiveWorkloadBoost(difficulty: Double) -> Double {
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
    public static func applyAdaptiveWorkloadWeights(
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



    // MARK: - Reset

    public func reset() {
        preferenceLearner.reset()
        currentSchedule = []
        lastResult = nil
        preferences = OptimizerPreferences()
        lastOptimizationContext = nil
    }
}
