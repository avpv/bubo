import Foundation

// MARK: - Adaptive Scheduling Feature Toggles (integration layer)
//
// A single source of truth for which adaptive / learning-backed
// additions are active in the current `BuboOptimizer` run. Defaults
// enable the subset that is safe, low-risk, and strictly additive
// (temporal warm-start, DPO, chance-constrained buffers, symmetry
// breaker, multi-fidelity funnel). Heavier changes (MOEA/D-AWA
// survivor selector, CP-SAT repair, migration bandit, CMA-ME QD
// emitter) default off — enable per workload when ready.
//
// This file extends `BuboOptimizer` with the orchestration methods
// that call those adaptive subsystems and owns the per-workload
// learner fields needed to drive them. `optimize(context:)` remains
// the stable entry point; new capabilities ride on top via the
// existing EvolutionHooks API and BuboOptimizer's feedback surface,
// keeping the patch focused.

public struct SchedulingFeatureToggles: Sendable {

    public init(
        useLexicographicRanking: Bool = true,
        useSymmetryBreaking: Bool = true,
        useTabuMemory: Bool = true,
        useTemporalWarmStart: Bool = true,
        useMultiFidelityFunnel: Bool = true,
        useObjectiveClustering: Bool = true,
        usePathRelinking: Bool = true,
        cpSATWindowThreshold: Int = 20,
        useCPSATSeed: Bool = true,
        useDPOWeightLearning: Bool = true,
        useActiveLearningPair: Bool = true,
        useChanceConstrainedBuffers: Bool = true,
        useGNNWarmStart: Bool = true,
        useCalendarEmbedding: Bool = true,
        useDiffusionPolish: Bool = true,
        useProactiveReactive: Bool = true
    ) {
        self.useLexicographicRanking = useLexicographicRanking
        self.useSymmetryBreaking = useSymmetryBreaking
        self.useTabuMemory = useTabuMemory
        self.useTemporalWarmStart = useTemporalWarmStart
        self.useMultiFidelityFunnel = useMultiFidelityFunnel
        self.useObjectiveClustering = useObjectiveClustering
        self.usePathRelinking = usePathRelinking
        self.cpSATWindowThreshold = cpSATWindowThreshold
        self.useCPSATSeed = useCPSATSeed
        self.useDPOWeightLearning = useDPOWeightLearning
        self.useActiveLearningPair = useActiveLearningPair
        self.useChanceConstrainedBuffers = useChanceConstrainedBuffers
        self.useGNNWarmStart = useGNNWarmStart
        self.useCalendarEmbedding = useCalendarEmbedding
        self.useDiffusionPolish = useDiffusionPolish
        self.useProactiveReactive = useProactiveReactive
    }

    /// Wave 1: lex-fitness hierarchy used when ranking scenarios for
    /// the user. Precedence / Conflict dominate soft objectives.
    public var useLexicographicRanking: Bool = true

    /// Wave 1: canonicalise gene order after mutation to boost cache
    /// hit rate and determinism. Runs inside repair hook.
    public var useSymmetryBreaking: Bool = true

    /// Wave 1: tabu list + long-term frequency diversification on
    /// LNS move selection. Tracked per-workload.
    public var useTabuMemory: Bool = true

    /// Wave 1: reuse prior accepted solution as a warm-start seed.
    public var useTemporalWarmStart: Bool = true

    /// Wave 1: tier-1 surrogate funnel over batch evaluations.
    public var useMultiFidelityFunnel: Bool = true

    /// Wave 2: online objective correlation clustering, exposed via
    /// telemetry and optionally used by MOEA/D-AWA.
    public var useObjectiveClustering: Bool = true

    /// Wave 2: post-GA path relinking across the final scenarios.
    public var usePathRelinking: Bool = true

    /// Shared window threshold retained for the extended learner
    /// bundle's public API surface and referenced by
    /// `ScheduleChromosome.cpSeeded` to decide when the CP-SAT
    /// construction seeder fires at all.
    public var cpSATWindowThreshold: Int = 20

    /// When on, inject a `CPSATRepairer` into the optimizer context
    /// so the construction seeder (`ScheduleChromosome.cpSeeded`)
    /// can produce one feasibility-optimal individual per run.
    /// Distinct from the retired `useCPSATRepair` — that flag routed
    /// LNS destroy windows through the same solver and was dropped
    /// because the handwritten branch-and-bound matched it on the
    /// realistic workloads we measured. As a *seeder* the solver
    /// buys something different: a guaranteed-feasible start that
    /// already optimises the hard + mid lex tiers (inclusion,
    /// deadline, backlog-order), so the GA only has to polish the
    /// soft tier. On timeout or infeasibility `cpSeeded` returns
    /// nil and the warm-start collector skips it.
    public var useCPSATSeed: Bool = true

    // MARK: - Removed flags
    //
    // The following toggles previously gated experimental subsystems
    // that stayed off-by-default in production and never graduated:
    //
    //   • `useMOEADAWASurvivor` — alternative NSGA-III replacement.
    //   • `useCMAMEEmitter` — covariance-adapted Gaussian emitter
    //     on top of the MAP-Elites archive.
    //   • `useCPSATRepair` — routed LNS destroy windows ≥ threshold
    //     through the CDCL-lite solver. The baseline branch-and-bound
    //     consistently matched or beat it on realistic workloads as
    //     a *repair* engine; the solver itself still lives under
    //     `CPSATRepair.swift` and is now reused as the construction
    //     seeder backend via `useCPSATSeed`.
    //   • `useLearnedBranching` — LinUCB bandit over CP-SAT variable
    //     ordering. Dormant; the seeder path uses the solver's
    //     built-in VSIDS-like ordering.
    //   • `useMigrationBandit` — UCB bandit over island migration
    //     pairs. The adaptive migration interval plus fixed ring
    //     topology delivered the same win without the extra state.
    //
    // Underlying types remain in the codebase so the solver can be
    // reached by new entry points (as with CPSATRepair above) and so
    // existing tests keep compiling. Remove the file entries entirely
    // once nothing external imports them.

    /// Wave 4: online DPO weight learning from user feedback.
    public var useDPOWeightLearning: Bool = true

    /// Wave 4: surface the most informative scenario pair via
    /// uncertainty sampling after each optimize().
    public var useActiveLearningPair: Bool = true

    /// Wave 4: chance-constrained buffers from historical durations.
    public var useChanceConstrainedBuffers: Bool = true

    /// Wave 5: GNN-driven greedy seed in the initial population.
    public var useGNNWarmStart: Bool = true

    /// Wave 5: per-chromosome calendar embedding used as an extra
    /// signal in learner routing.
    public var useCalendarEmbedding: Bool = true

    /// Wave 5: denoising diffusion polish of the top N scenarios.
    public var useDiffusionPolish: Bool = true

    /// Wave 5: ProactiveReactivePolicy invoked on
    /// `BuboOptimizer.reactToDisturbance`.
    public var useProactiveReactive: Bool = true
}

// MARK: - Extended learner bundle

public extension BuboOptimizer {
    /// Adaptive learners bundled per workload signature. Wired
    /// into `optimize()` via `obtainLearnerSuite(for:)`. Held separately
    /// from the legacy `WorkloadLearners` to keep blast radius small
    /// until integration has settled.
    final class AdaptiveLearnerSuite: @unchecked Sendable {
        public let tabu: TabuMemory
        public let dpo: DPOWeightLearner
        public let embedder: CalendarEmbedder
        public let warmStart: TemporalWarmStart
        public let bufferStore: ChanceConstrainedBufferStore
        public let objectiveClusterer: ObjectiveCorrelationClusterer
        public let gnnTrainer: GNNWarmStartTrainer

        public init(islandCount: Int = 4) {
            _ = islandCount // retained for API symmetry with earlier
                            // variants that sized per-island state.
            self.tabu = TabuMemory()
            self.dpo = DPOWeightLearner(
                priorWeights: PreferenceLearner.defaultWeights
            )
            self.embedder = CalendarEmbedder()
            self.warmStart = TemporalWarmStart()
            self.bufferStore = ChanceConstrainedBufferStore()
            self.objectiveClusterer = ObjectiveCorrelationClusterer()
            self.gnnTrainer = GNNWarmStartTrainer()
        }
    }
}

// MARK: - State accessors (kept off the @Observable surface)

/// Learner-state container that shouldn't notify SwiftUI subscribers on every
/// update. Held in a detached class so it survives across
/// `@Observable` instance replacements without triggering re-renders.
public final class OptimizerLearningState: @unchecked Sendable {
    public var bundlesBySignature: [TaskSignature: BuboOptimizer.AdaptiveLearnerSuite] = [:]
    public var bundleLRU: [TaskSignature] = []
    public var flags: SchedulingFeatureToggles = SchedulingFeatureToggles()
    /// Last active learning pair surfaced after `optimize()`. The host
    /// UI can read this to display "help the model: which do you
    /// prefer?" prompts.
    public var lastActiveLearningPair: (ScheduleScenario, ScheduleScenario)? = nil
    /// Proactive-reactive policy is process-global; one instance
    /// suffices.
    public let proactiveReactive = ProactiveReactivePolicy()
}

/// File-scoped Learner-state container store. Swift disallows stored properties
/// in extensions, so we keep the per-optimizer state keyed by
/// `ObjectIdentifier` at module scope.
fileprivate let learningStateRegistry = OptimizerLearningStateRegistry()

public extension BuboOptimizer {

    /// Scheduling feature toggles. Mutations take effect on the next
    /// `optimize()` call.
    var schedulingFeatures: SchedulingFeatureToggles {
        get { learningStateRegistry.load(key: ObjectIdentifier(self)).flags }
        set {
            let state = learningStateRegistry.load(key: ObjectIdentifier(self))
            state.flags = newValue
        }
    }

    /// Public read-only accessor for the last active-learning pair.
    var lastActiveLearningPair: (ScheduleScenario, ScheduleScenario)? {
        learningStateRegistry.load(key: ObjectIdentifier(self)).lastActiveLearningPair
    }

    // MARK: - Learner-suite routing

    func obtainLearnerSuite(for context: OptimizerContext) -> AdaptiveLearnerSuite {
        let signature = TaskSignature(context: context)
        let state = learningStateRegistry.load(key: ObjectIdentifier(self))
        if let existing = state.bundlesBySignature[signature] {
            state.bundleLRU.removeAll { $0 == signature }
            state.bundleLRU.append(signature)
            return existing
        }
        let fresh = AdaptiveLearnerSuite()
        state.bundlesBySignature[signature] = fresh
        state.bundleLRU.append(signature)
        while state.bundleLRU.count > maxCachedLearnerBundles {
            let evicted = state.bundleLRU.removeFirst()
            state.bundlesBySignature.removeValue(forKey: evicted)
        }
        return fresh
    }

    func lookupLearnerSuite(for scenario: ScheduleScenario) -> AdaptiveLearnerSuite? {
        guard let key = scenario.sourceSignature ?? lastRunSignature else { return nil }
        return learningStateRegistry.load(key: ObjectIdentifier(self))
            .bundlesBySignature[key]
    }

    var proactiveReactivePolicy: ProactiveReactivePolicy {
        learningStateRegistry.load(key: ObjectIdentifier(self)).proactiveReactive
    }

    fileprivate func setLastActiveLearningPair(_ pair: (ScheduleScenario, ScheduleScenario)?) {
        learningStateRegistry.load(key: ObjectIdentifier(self))
            .lastActiveLearningPair = pair
    }

    // MARK: - Feedback fan-out

    /// Extends `acceptScenario` to also route the event through the adaptive
    /// learners. Called in addition to the legacy feedback path.
    func propagateAcceptFeedback(
        accepted: ScheduleScenario,
        runnerUps: [ScheduleScenario],
        context: OptimizerContext?
    ) {
        guard let bundle = lookupLearnerSuite(for: accepted) else { return }
        if schedulingFeatures.useDPOWeightLearning {
            for loser in runnerUps {
                bundle.dpo.observe(pair: DPOPreferencePair(
                    winnerScores: accepted.objectiveBreakdown,
                    loserScores: loser.objectiveBreakdown,
                    confidence: 1.0
                ))
            }
        }
        if schedulingFeatures.useTemporalWarmStart, let context {
            bundle.warmStart.record(genes: accepted.genes, context: context)
        }
        if schedulingFeatures.useCalendarEmbedding, let context {
            // Real triplet loss: anchor = accepted, positive = the
            // closest runner-up by fitness (similar enough to
            // confuse), negative = the worst runner-up (clearly
            // different in appeal). We do one SGD step per loser
            // pair so the embedding learns the user's actual
            // preference manifold, not just a coarse "different"
            // signal.
            let acceptedChromo = ScheduleChromosome(genes: accepted.genes, needsEvaluation: false)
            let rankedRunnerUps = runnerUps.sorted { $0.fitness > $1.fitness }
            if rankedRunnerUps.count >= 2 {
                let positive = ScheduleChromosome(genes: rankedRunnerUps.first!.genes, needsEvaluation: false)
                let negative = ScheduleChromosome(genes: rankedRunnerUps.last!.genes, needsEvaluation: false)
                _ = bundle.embedder.trainTriplet(
                    anchor: acceptedChromo,
                    positive: positive,
                    negative: negative,
                    context: context
                )
            }
        }
        if schedulingFeatures.useGNNWarmStart, let _ = context {
            // Credit the GNN seeder for accepts that beat the
            // population's median runner-up fitness. The trainer's
            // online update rule reinforces or weakens readout
            // weights based on whether the GNN-seeded chromosome
            // produced the accepted outcome.
            let runnersFit = runnerUps.map(\.fitness).sorted()
            let baseline: Double
            if runnersFit.isEmpty {
                baseline = accepted.fitness * 0.95
            } else {
                baseline = runnersFit[runnersFit.count / 2]
            }
            if let context {
                bundle.gnnTrainer.observe(
                    context: context,
                    seedFitness: accepted.fitness,
                    baselineFitness: baseline
                )
            }
        }
    }

    /// Explicit preference pair feedback — used when the UI shows the
    /// active-learning pair and the user picks a side.
    func recordPreferencePair(
        winner: ScheduleScenario,
        loser: ScheduleScenario,
        context: OptimizerContext? = nil
    ) {
        guard let bundle = lookupLearnerSuite(for: winner) else { return }
        if schedulingFeatures.useDPOWeightLearning {
            bundle.dpo.observe(pair: DPOPreferencePair(
                winnerScores: winner.objectiveBreakdown,
                loserScores: loser.objectiveBreakdown,
                confidence: 1.0
            ))
        }
    }

    /// Record an (actual, scheduled) duration pair for buffer fitting.
    /// Wire into the host app's event-finish handler.
    func recordEventDurationSample(
        title: String,
        context scenarioContext: String?,
        scheduledDuration: TimeInterval,
        actualDuration: TimeInterval,
        workloadContext: OptimizerContext
    ) {
        let bundle = obtainLearnerSuite(for: workloadContext)
        bundle.bufferStore.record(
            title: title,
            context: scenarioContext,
            scheduledDuration: scheduledDuration,
            actualDuration: actualDuration
        )
    }

    // MARK: - Proactive-reactive API

    /// React to a runtime disturbance (delay, cancellation, urgent
    /// insertion, participant unavailable) and return the recovered
    /// schedule. Stable under repeated calls with the same inputs.
    func reactToDisturbance(
        _ disturbance: ScheduleDisturbance,
        context: OptimizerContext
    ) -> [ScheduleGene] {
        guard schedulingFeatures.useProactiveReactive else {
            return currentSchedule
        }
        let recovery = proactiveReactivePolicy.react(
            disturbance: disturbance,
            currentSchedule: currentSchedule,
            context: context
        )
        let updated = recovery.applied(to: currentSchedule, registry: context.ensureSlotRegistry())
        currentSchedule = updated
        return updated
    }

    // MARK: - DPO-driven weight application

    /// Apply DPO-learned weights on top of user preferences, routed
    /// by workload signature. Called by the prelude-aware
    /// `adjustPreferencesFromLearners` below.
    fileprivate func applyDPOLearnedWeights(
        to prefs: inout OptimizerPreferences,
        context: OptimizerContext
    ) {
        guard schedulingFeatures.useDPOWeightLearning else { return }
        let bundle = obtainLearnerSuite(for: context)
        bundle.dpo.applyTo(preferences: &prefs)
    }

    /// Pull a recommended buffer from historical fits and merge into
    /// preferences. Best-effort: falls back silently if samples are
    /// below `minSamples`.
    fileprivate func applyChanceConstrainedBuffers(
        to prefs: inout OptimizerPreferences,
        context: OptimizerContext
    ) {
        guard schedulingFeatures.useChanceConstrainedBuffers else { return }
        let bundle = obtainLearnerSuite(for: context)
        // Use the median event duration across the workload as a
        // representative query — individual per-event buffers would
        // need per-event preferences, which the current schema
        // doesn't carry. One global preferences value is still
        // informative: it moves the buffer toward the workload's
        // typical overrun.
        let events = context.movableEvents
        guard !events.isEmpty else { return }
        var recommendations: [Double] = []
        for e in events {
            if let b = bundle.bufferStore.recommendedBuffer(
                title: e.title, context: e.context,
                scheduledDuration: e.duration
            ) {
                recommendations.append(b)
            }
        }
        guard !recommendations.isEmpty else { return }
        let median = recommendations.sorted()[recommendations.count / 2]
        prefs.defaultBufferMinutes = Int(median.rounded())
    }

    /// Called by `optimize()` before the GA starts to apply the learner-
    /// prelude steps: DPO weights, chance buffers. Safe no-op when
    /// feature flags are off.
    func adjustPreferencesFromLearners(
        prefs: inout OptimizerPreferences,
        context: OptimizerContext
    ) {
        applyDPOLearnedWeights(to: &prefs, context: context)
        applyChanceConstrainedBuffers(to: &prefs, context: context)
    }

    /// Collect warm-start seed chromosomes (temporal replay +
    /// GNN-driven greedy). Called by
    /// optimize() to seed the initial population alongside greedy /
    /// random individuals. The GNN seed uses the current trained
    /// weights so each run benefits from accumulated feedback.
    func collectWarmStartSeeds(context: OptimizerContext) -> [ScheduleChromosome] {
        var seeds: [ScheduleChromosome] = []
        let bundle = obtainLearnerSuite(for: context)
        if schedulingFeatures.useTemporalWarmStart {
            if let warm = bundle.warmStart.seed(context: context) {
                seeds.append(warm)
            }
        }
        if schedulingFeatures.useGNNWarmStart {
            seeds.append(bundle.gnnTrainer.seedChromosome(context: context))
        }
        // NOTE: CP-SAT construction seed is handled separately in
        // `BuboOptimizer.optimize` so its result can drive the
        // GA-config dispatch (polish / refine / search). The anchor
        // reaches the island populations through
        // `IslandModelGA.anchorSeed` rather than this generic
        // warm-start list.

        // Brute-force seeding for tiny backlogs. With N ≤ 4 the full
        // set of greedy-constructed permutations is 24 or fewer —
        // trivially enumerable — and injecting all of them guarantees
        // the GA's initial population contains the globally optimal
        // placement order. The subsequent evolution then only has to
        // fine-tune intra-task timing, not search task ordering.
        //
        // Gated on N to keep the combinatorial explosion bounded.
        // N=5 (120 perms) is borderline; N=6 (720) would start to
        // dominate the GA cost, so we stop at 4.
        let n = context.movableEvents.count
        if n >= 2 && n <= 4 {
            seeds.append(contentsOf: bruteForceGreedySeeds(context: context))
        }
        return seeds
    }

    /// Enumerate all permutations of `context.movableEvents`, build a
    /// greedy schedule from each, and return the resulting chromosomes.
    /// Caller is expected to feed these into the GA as warm-start
    /// seeds — survivor selection handles picking the best.
    ///
    /// Deduplication: two distinct permutations often produce identical
    /// greedy output (tied priorities + a long gap → events land in
    /// input order either way). We skip structural duplicates by hashing
    /// the (eventId, startTime) tuple set.
    private func bruteForceGreedySeeds(context: OptimizerContext) -> [ScheduleChromosome] {
        guard !context.movableEvents.isEmpty else { return [] }
        var seen = Set<Int>()
        var out: [ScheduleChromosome] = []

        var indices = Array(context.movableEvents.indices)
        permute(&indices, k: 0) { perm in
            let ordered = perm.map { context.movableEvents[$0] }
            let chrom = ScheduleChromosome.greedyWithOrder(
                context: context,
                eventsInPlacementOrder: ordered
            )
            var hasher = Hasher()
            for gene in chrom.genes where gene.isIncluded {
                hasher.combine(gene.eventId)
                hasher.combine(gene.startTime.timeIntervalSinceReferenceDate)
            }
            let key = hasher.finalize()
            if seen.insert(key).inserted {
                out.append(chrom)
            }
        }
        return out
    }

    /// Recursive permutation iterator via callback — streams each
    /// permutation into `body` without allocating `N!` copies up front.
    private func permute<T>(
        _ arr: inout [T],
        k: Int,
        body: ([T]) -> Void
    ) {
        if k == arr.count - 1 || k == arr.count {
            body(arr)
            return
        }
        for i in k..<arr.count {
            arr.swapAt(i, k)
            permute(&arr, k: k + 1, body: body)
            arr.swapAt(i, k)
        }
    }

    /// Post-processing on final scenarios: lex ranking, path
    /// relinking, diffusion polish, active-learning pair surfacing.
    func refineAndRankScenarios(
        scenarios: [ScheduleScenario],
        context: OptimizerContext,
        evaluator: FitnessEvaluator
    ) -> [ScheduleScenario] {
        guard !scenarios.isEmpty else { return scenarios }
        var current = scenarios

        // Active learning pair surfacing.
        if schedulingFeatures.useActiveLearningPair {
            let bundle = obtainLearnerSuite(for: context)
            if let pair = ScenarioPairActiveSelector.bestPair(
                scenarios: current, learner: bundle.dpo
            ) {
                setLastActiveLearningPair(pair)
            }
        }

        // Feed the online objective clusterer with per-scenario
        // objective scores so the EMA correlation matrix updates.
        if schedulingFeatures.useObjectiveClustering {
            let bundle = obtainLearnerSuite(for: context)
            let names = evaluator.objectives.map(\.name)
            let rows: [[Double]] = current.map { scenario in
                names.map { scenario.objectiveBreakdown[$0] ?? 0 }
            }
            if rows.count >= 2 {
                bundle.objectiveClusterer.observe(names: names, rows: rows)
            }
        }

        // Lex ranking.
        if schedulingFeatures.useLexicographicRanking {
            let extractor = LexicographicExtractor(evaluator: evaluator)
            let cmp = LexicographicComparator()
            current.sort { a, b in
                let la = extractor.extract(fromCache: a.objectiveBreakdown)
                let lb = extractor.extract(fromCache: b.objectiveBreakdown)
                return cmp.isBetter(la, than: lb)
            }
        }

        // Path Relinking between the top scenarios. Lifted children
        // are inserted only when they strictly improve and stamped
        // with the same signature so feedback routing still works.
        if schedulingFeatures.usePathRelinking, current.count >= 2 {
            let signature = current.first?.sourceSignature
            let evalClosure: (inout ScheduleChromosome) -> Void = { chromo in
                evaluator.evaluateAndAssign(&chromo, context: context)
            }
            let elites = current.prefix(min(4, current.count)).map { scenario in
                ScheduleChromosome(genes: scenario.genes, needsEvaluation: true)
            }
            let result = ArchivePathRelinker.relink(
                elites: elites,
                context: context,
                evaluate: evalClosure,
                maxPairs: 6
            )
            for child in result.improvements.prefix(2) {
                let breakdown = evaluator.objectiveBreakdown(for: child, context: context)
                var scenario = ScheduleScenario(
                    genes: child.genes,
                    fitness: child.rawFitness,
                    objectiveBreakdown: breakdown,
                    constraintViolations: []
                )
                scenario.sourceSignature = signature
                current.append(scenario)
            }
        }

        // Diffusion polish of the #1 scenario.
        if schedulingFeatures.useDiffusionPolish, let top = current.first {
            let evalClosure: (inout ScheduleChromosome) -> Void = { chromo in
                evaluator.evaluateAndAssign(&chromo, context: context)
            }
            var input = ScheduleChromosome(genes: top.genes, needsEvaluation: true)
            evalClosure(&input)
            let refined = DiffusionRefinement.refine(
                input: input,
                context: context,
                evaluate: evalClosure,
                config: .gentle
            )
            if refined.improvedVsInput {
                let breakdown = evaluator.objectiveBreakdown(for: refined.refined, context: context)
                var polished = ScheduleScenario(
                    genes: refined.refined.genes,
                    fitness: refined.refined.rawFitness,
                    objectiveBreakdown: breakdown,
                    constraintViolations: []
                )
                polished.sourceSignature = top.sourceSignature
                current[0] = polished
            }
        }
        return current
    }
}

// MARK: - Private state store

/// Per-BuboOptimizer Learner-state container, keyed by instance identity. Using a
/// dictionary keyed on `ObjectIdentifier` avoids mutating the main
/// `@Observable` class on every Learner-state container change — a naive stored
/// property would trigger UI re-renders for every learner update.
fileprivate final class OptimizerLearningStateRegistry: @unchecked Sendable {
    private var store: [ObjectIdentifier: OptimizerLearningState] = [:]
    private let lock = NSLock()

    public func load(key: ObjectIdentifier) -> OptimizerLearningState {
        lock.lock()
        defer { lock.unlock() }
        if let existing = store[key] { return existing }
        let fresh = OptimizerLearningState()
        store[key] = fresh
        return fresh
    }
}
