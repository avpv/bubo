import Foundation

// MARK: - Advanced Optimizer Feature Flags (integration layer)
//
// A single source of truth for which advanced additions are active
// in the current `BuboOptimizer` run. Defaults enable the subset that
// is safe, low-risk, and strictly additive (temporal warm-start,
// DPO, chance-constrained buffers, symmetry breaker, multi-fidelity
// funnel). Heavier changes (MOEA/D-AWA survivor selector, CP-SAT
// repair, migration bandit, CMA-ME QD emitter) default off — enable
// per workload when ready.
//
// This file extends `BuboOptimizer` with advanced-aware orchestration
// methods and the per-workload learner fields needed to drive them.
// `optimize(context:)` remains the stable entry point; new
// capabilities ride on top via the existing EvolutionHooks API and
// BuboOptimizer's feedback surface, keeping the patch focused.

struct AdvancedFeatureFlags: Sendable {
    /// Wave 1: lex-fitness hierarchy used when ranking scenarios for
    /// the user. Precedence / Conflict dominate soft objectives.
    var useLexicographicRanking: Bool = true

    /// Wave 1: canonicalise gene order after mutation to boost cache
    /// hit rate and determinism. Runs inside repair hook.
    var useSymmetryBreaking: Bool = true

    /// Wave 1: tabu list + long-term frequency diversification on
    /// LNS move selection. Tracked per-workload.
    var useTabuMemory: Bool = true

    /// Wave 1: reuse prior accepted solution as a warm-start seed.
    var useTemporalWarmStart: Bool = true

    /// Wave 1: tier-1 surrogate funnel over batch evaluations.
    var useMultiFidelityFunnel: Bool = true

    /// Wave 2: MOEA/D-AWA as alternative survivor selector. Off by
    /// default — keep NSGA-III as the stable baseline.
    var useMOEADAWASurvivor: Bool = false

    /// Wave 2: online objective correlation clustering, exposed via
    /// telemetry and optionally used by MOEA/D-AWA.
    var useObjectiveClustering: Bool = true

    /// Wave 2: post-GA path relinking across the final scenarios.
    var usePathRelinking: Bool = true

    /// Wave 2: replace the MAP-Elites uniform emitter with a CMA-ME
    /// covariance-adapted Gaussian.
    var useCMAMEEmitter: Bool = false

    /// Wave 3: switch LNS repair to the CP-SAT adapter for windows
    /// ≥ `cpSATWindowThreshold`. Expensive — off by default.
    var useCPSATRepair: Bool = false
    var cpSATWindowThreshold: Int = 20

    /// Wave 3: learned branching bandit driving CP-SAT variable
    /// ordering. Only meaningful when CP-SAT is also enabled.
    var useLearnedBranching: Bool = false

    /// Wave 3: UCB bandit over island migration pairs.
    var useMigrationBandit: Bool = false

    /// Wave 4: online DPO weight learning from user feedback.
    var useDPOWeightLearning: Bool = true

    /// Wave 4: surface the most informative scenario pair via
    /// uncertainty sampling after each optimize().
    var useActiveLearningPair: Bool = true

    /// Wave 4: chance-constrained buffers from historical durations.
    var useChanceConstrainedBuffers: Bool = true

    /// Wave 5: GNN-driven greedy seed in the initial population.
    var useGNNWarmStart: Bool = true

    /// Wave 5: per-chromosome calendar embedding used as an extra
    /// signal in learner routing.
    var useCalendarEmbedding: Bool = true

    /// Wave 5: denoising diffusion polish of the top N scenarios.
    var useDiffusionPolish: Bool = true

    /// Wave 5: ProactiveReactivePolicy invoked on
    /// `BuboOptimizer.reactToDisturbance`.
    var useProactiveReactive: Bool = true
}

// MARK: - Extended learner bundle

extension BuboOptimizer {
    /// Advanced extension pack bundled per workload signature. Wired
    /// into `optimize()` via `advancedLearners(for:)`. Held separately
    /// from the legacy `WorkloadLearners` to keep blast radius small
    /// until integration has settled.
    final class AdvancedLearnerBundle: @unchecked Sendable {
        let tabu: TabuMemory
        let dpo: DPOWeightLearner
        let embedder: CalendarEmbedder
        let warmStart: TemporalWarmStart
        let bufferStore: ChanceConstrainedBufferStore
        let branchingBandit: LearnedBranchingBandit
        let objectiveClusterer: ObjectiveCorrelationClusterer

        init() {
            self.tabu = TabuMemory()
            self.dpo = DPOWeightLearner(
                priorWeights: PreferenceLearner.defaultWeights
            )
            self.embedder = CalendarEmbedder()
            self.warmStart = TemporalWarmStart()
            self.bufferStore = ChanceConstrainedBufferStore()
            self.branchingBandit = LearnedBranchingBandit()
            self.objectiveClusterer = ObjectiveCorrelationClusterer()
        }
    }
}

// MARK: - State accessors (kept off the @Observable surface)

/// Advanced optimizer state that shouldn't notify SwiftUI subscribers on every
/// update. Held in a detached class so it survives across
/// `@Observable` instance replacements without triggering re-renders.
final class AdvancedOptimizerState: @unchecked Sendable {
    var bundlesBySignature: [TaskSignature: BuboOptimizer.AdvancedLearnerBundle] = [:]
    var bundleLRU: [TaskSignature] = []
    var flags: AdvancedFeatureFlags = AdvancedFeatureFlags()
    /// Last active learning pair surfaced after `optimize()`. The host
    /// UI can read this to display "help the model: which do you
    /// prefer?" prompts.
    var lastActiveLearningPair: (ScheduleScenario, ScheduleScenario)? = nil
    /// Proactive-reactive policy is process-global; one instance
    /// suffices.
    let proactiveReactive = ProactiveReactivePolicy()
}

/// File-scoped Advanced optimizer state store. Swift disallows stored properties
/// in extensions, so we keep the per-optimizer state keyed by
/// `ObjectIdentifier` at module scope.
fileprivate let advancedStateStore = AdvancedOptimizerStateStore()

extension BuboOptimizer {

    /// Public advanced feature flags. Mutations take effect on the next
    /// `optimize()` call.
    var advancedFeatures: AdvancedFeatureFlags {
        get { advancedStateStore.load(key: ObjectIdentifier(self)).flags }
        set {
            let state = advancedStateStore.load(key: ObjectIdentifier(self))
            state.flags = newValue
        }
    }

    /// Public read-only accessor for the last active-learning pair.
    var lastActiveLearningPair: (ScheduleScenario, ScheduleScenario)? {
        advancedStateStore.load(key: ObjectIdentifier(self)).lastActiveLearningPair
    }

    // MARK: - Advanced learner bundle routing

    func advancedLearners(for context: OptimizerContext) -> AdvancedLearnerBundle {
        let signature = TaskSignature(context: context)
        let state = advancedStateStore.load(key: ObjectIdentifier(self))
        if let existing = state.bundlesBySignature[signature] {
            state.bundleLRU.removeAll { $0 == signature }
            state.bundleLRU.append(signature)
            return existing
        }
        let fresh = AdvancedLearnerBundle()
        state.bundlesBySignature[signature] = fresh
        state.bundleLRU.append(signature)
        while state.bundleLRU.count > maxCachedLearnerBundles {
            let evicted = state.bundleLRU.removeFirst()
            state.bundlesBySignature.removeValue(forKey: evicted)
        }
        return fresh
    }

    func advancedBundle(for scenario: ScheduleScenario) -> AdvancedLearnerBundle? {
        guard let key = scenario.sourceSignature ?? lastRunSignature else { return nil }
        return advancedStateStore.load(key: ObjectIdentifier(self))
            .bundlesBySignature[key]
    }

    var proactiveReactivePolicy: ProactiveReactivePolicy {
        advancedStateStore.load(key: ObjectIdentifier(self)).proactiveReactive
    }

    fileprivate func setLastActiveLearningPair(_ pair: (ScheduleScenario, ScheduleScenario)?) {
        advancedStateStore.load(key: ObjectIdentifier(self))
            .lastActiveLearningPair = pair
    }

    // MARK: - Feedback fan-out

    /// Extends `acceptScenario` to also route the event through the advanced
    /// learners. Called in addition to the legacy feedback path.
    func recordAdvancedAcceptance(
        accepted: ScheduleScenario,
        runnerUps: [ScheduleScenario],
        context: OptimizerContext?
    ) {
        guard let bundle = advancedBundle(for: accepted) else { return }
        if advancedFeatures.useDPOWeightLearning {
            for loser in runnerUps {
                bundle.dpo.observe(pair: DPOPreferencePair(
                    winnerScores: accepted.objectiveBreakdown,
                    loserScores: loser.objectiveBreakdown,
                    confidence: 1.0
                ))
            }
        }
        if advancedFeatures.useTemporalWarmStart, let context {
            bundle.warmStart.record(genes: accepted.genes, context: context)
        }
        if advancedFeatures.useCalendarEmbedding, let context {
            // Push accepted/rejected embeddings apart — a coarse
            // contrastive signal. Accept and the top runner-up
            // implicitly disagree, so we nudge them away.
            let acceptedChromo = ScheduleChromosome(genes: accepted.genes, needsEvaluation: false)
            for loser in runnerUps.prefix(2) {
                let loserChromo = ScheduleChromosome(genes: loser.genes, needsEvaluation: false)
                bundle.embedder.observeDissimilar(
                    acceptedChromo, loserChromo, context: context
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
        guard let bundle = advancedBundle(for: winner) else { return }
        if advancedFeatures.useDPOWeightLearning {
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
        let bundle = advancedLearners(for: workloadContext)
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
        guard advancedFeatures.useProactiveReactive else {
            return currentSchedule
        }
        let recovery = proactiveReactivePolicy.react(
            disturbance: disturbance,
            currentSchedule: currentSchedule,
            context: context
        )
        let updated = recovery.applied(to: currentSchedule)
        currentSchedule = updated
        return updated
    }

    // MARK: - DPO-driven weight application

    /// Apply DPO-learned weights on top of user preferences, routed
    /// by workload signature. Called by the prelude-aware
    /// `applyAdvancedPrelude` below.
    fileprivate func applyDPOLearnedWeights(
        to prefs: inout OptimizerPreferences,
        context: OptimizerContext
    ) {
        guard advancedFeatures.useDPOWeightLearning else { return }
        let bundle = advancedLearners(for: context)
        bundle.dpo.applyTo(preferences: &prefs)
    }

    /// Pull a recommended buffer from historical fits and merge into
    /// preferences. Best-effort: falls back silently if samples are
    /// below `minSamples`.
    fileprivate func applyChanceConstrainedBuffers(
        to prefs: inout OptimizerPreferences,
        context: OptimizerContext
    ) {
        guard advancedFeatures.useChanceConstrainedBuffers else { return }
        let bundle = advancedLearners(for: context)
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

    /// Called by `optimize()` before the GA starts to apply advanced
    /// prelude steps: DPO weights, chance buffers. Safe no-op when
    /// feature flags are off.
    func applyAdvancedPrelude(
        prefs: inout OptimizerPreferences,
        context: OptimizerContext
    ) {
        applyDPOLearnedWeights(to: &prefs, context: context)
        applyChanceConstrainedBuffers(to: &prefs, context: context)
    }

    /// Build extra seed chromosomes from advanced sources. Called by
    /// optimize() to seed the initial population alongside greedy /
    /// random individuals.
    func buildAdvancedSeeds(context: OptimizerContext) -> [ScheduleChromosome] {
        var seeds: [ScheduleChromosome] = []
        if advancedFeatures.useTemporalWarmStart {
            let bundle = advancedLearners(for: context)
            if let warm = bundle.warmStart.seed(context: context) {
                seeds.append(warm)
            }
        }
        if advancedFeatures.useGNNWarmStart {
            seeds.append(GNNWarmStart.seedChromosome(context: context))
        }
        return seeds
    }

    /// Post-processing on final scenarios: lex ranking, path
    /// relinking, diffusion polish, active-learning pair surfacing.
    func postProcessScenarios(
        scenarios: [ScheduleScenario],
        context: OptimizerContext,
        evaluator: FitnessEvaluator
    ) -> [ScheduleScenario] {
        guard !scenarios.isEmpty else { return scenarios }
        var current = scenarios

        // Active learning pair surfacing.
        if advancedFeatures.useActiveLearningPair {
            let bundle = advancedLearners(for: context)
            if let pair = ScenarioPairActiveSelector.bestPair(
                scenarios: current, learner: bundle.dpo
            ) {
                setLastActiveLearningPair(pair)
            }
        }

        // Feed the online objective clusterer with per-scenario
        // objective scores so the EMA correlation matrix updates.
        if advancedFeatures.useObjectiveClustering {
            let bundle = advancedLearners(for: context)
            let names = evaluator.objectives.map(\.name)
            let rows: [[Double]] = current.map { scenario in
                names.map { scenario.objectiveBreakdown[$0] ?? 0 }
            }
            if rows.count >= 2 {
                bundle.objectiveClusterer.observe(names: names, rows: rows)
            }
        }

        // Lex ranking.
        if advancedFeatures.useLexicographicRanking {
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
        if advancedFeatures.usePathRelinking, current.count >= 2 {
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
        if advancedFeatures.useDiffusionPolish, let top = current.first {
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

/// Per-BuboOptimizer Advanced optimizer state, keyed by instance identity. Using a
/// dictionary keyed on `ObjectIdentifier` avoids mutating the main
/// `@Observable` class on every Advanced optimizer state change — a naive stored
/// property would trigger UI re-renders for every learner update.
fileprivate final class AdvancedOptimizerStateStore: @unchecked Sendable {
    private var store: [ObjectIdentifier: AdvancedOptimizerState] = [:]
    private let lock = NSLock()

    func load(key: ObjectIdentifier) -> AdvancedOptimizerState {
        lock.lock()
        defer { lock.unlock() }
        if let existing = store[key] { return existing }
        let fresh = AdvancedOptimizerState()
        store[key] = fresh
        return fresh
    }
}
