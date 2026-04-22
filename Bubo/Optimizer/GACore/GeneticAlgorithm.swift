import Foundation

// MARK: - GA Configuration

struct GAConfiguration: Sendable {
    var populationSize: Int
    var maxGenerations: Int
    var mutationRate: Double
    var crossoverRate: Double
    var eliteCount: Int
    var selectionStrategy: SelectionStrategy
    var crossoverStrategy: CrossoverStrategy
    var convergenceThreshold: Double   // stop if fitness improvement < this for N generations
    var convergencePatience: Int       // number of stale generations before stopping
    var adaptiveMutation: Bool
    var diversityThreshold: Double     // below this diversity, boost mutation & inject immigrants
    var immigrationRate: Double        // fraction of population replaced by random immigrants on stagnation

    /// Fraction of initial population seeded with greedy heuristic (0 = all random, 0.2 = 20% greedy).
    /// Greedy seeds give the GA feasible starting points, especially useful for fast configs.
    var greedySeedFraction: Double

    /// Enable repair operator after crossover/mutation to fix constraint violations.
    /// Converts infeasible offspring into feasible ones, avoiding wasted evaluations.
    var enableRepair: Bool

    /// Enable adaptive crossover rate (decays with generation progress).
    var adaptiveCrossover: Bool

    /// Run a short SA hill climb on the top individuals every N generations
    /// during evolution, not just once at the end. 0 disables (pure GA).
    /// Memetic intermediate hill climbing typically delivers +5-10% final
    /// fitness for ~2-5% extra cost, because the climbs happen to the top
    /// individuals whose refinements then propagate through selection.
    var memeticHillClimbInterval: Int

    /// Number of individuals to hill-climb on each memetic pass.
    var memeticHillClimbCandidates: Int

    /// Steps per memetic hill climb invocation. Keep modest — the point is
    /// frequent local refinement, not a full deep optimization every cycle.
    var memeticHillClimbSteps: Int

    /// CHC-style restart: when the stagnation patience is exhausted,
    /// instead of giving up, keep the top-K individuals and regenerate the
    /// rest with high-rate mutation. 0 disables and the old "stop on
    /// stagnation" behaviour is preserved. Values > 0 grant the evolution
    /// this many restarts before actually stopping; each restart resets the
    /// stagnation counter and lets the GA attack the landscape from a fresh
    /// direction, which is often enough to escape basins immigration can't.
    var chcMaxRestarts: Int

    /// Fraction of the population kept verbatim at each CHC restart. The
    /// rest are regenerated from those elites via high-rate mutation (0.35
    /// per gene is standard CHC). Typically 0.1-0.2 — large enough to
    /// preserve discovered structure, small enough to leave room for
    /// meaningful renewal.
    var chcRestartEliteFraction: Double

    /// Per-gene mutation rate used when regenerating the non-elite portion
    /// on a CHC restart. CHC's defining trick is this being much higher
    /// than the normal rate so the regenerated portion really does probe a
    /// different neighbourhood.
    var chcRestartMutationRate: Double

    /// When true, initial individuals get `selfAdaptiveMutationRate =
    /// mutationRate`, and every mutation perturbs that value. Chromosomes
    /// whose rates produced better fitness propagate their rates through
    /// crossover, so the population's effective mutation rate drifts
    /// toward whatever is working for the current landscape — no manual
    /// tuning of `mutationRate` per workload.
    var selfAdaptiveRates: Bool

    /// Wallclock ceiling on the evolution loop. When > 0, both
    /// `GeneticAlgorithm.evolve` and `IslandModelGA.evolveIslands`
    /// exit between generations once this many seconds have elapsed
    /// since the loop started, regardless of `maxGenerations` or
    /// `convergencePatience`. Value 0 disables the timeout (legacy
    /// behaviour). Callers driving interactive UIs set this to keep
    /// "plan week" responsive on small backlogs where GA would
    /// otherwise burn its full generation budget on a trivially-
    /// schedulable workload.
    var wallclockTimeout: TimeInterval

    // Schedule-specific tunables (QD emission rate, gradient
    // refinement interval) used to live here. They've moved into the
    // hook closures that the host wires via `EvolutionHooks`, so
    // the engine no longer needs to know about them. Keep this file
    // strictly about the generic GA cycle.

    init(
        populationSize: Int,
        maxGenerations: Int,
        mutationRate: Double,
        crossoverRate: Double,
        eliteCount: Int,
        selectionStrategy: SelectionStrategy,
        crossoverStrategy: CrossoverStrategy,
        convergenceThreshold: Double,
        convergencePatience: Int,
        adaptiveMutation: Bool,
        diversityThreshold: Double,
        immigrationRate: Double,
        greedySeedFraction: Double = 0.0,
        enableRepair: Bool = false,
        adaptiveCrossover: Bool = false,
        memeticHillClimbInterval: Int = 0,
        memeticHillClimbCandidates: Int = 3,
        memeticHillClimbSteps: Int = 5,
        chcMaxRestarts: Int = 0,
        chcRestartEliteFraction: Double = 0.15,
        chcRestartMutationRate: Double = 0.35,
        selfAdaptiveRates: Bool = false,
        wallclockTimeout: TimeInterval = 0
    ) {
        self.populationSize = populationSize
        self.maxGenerations = maxGenerations
        self.mutationRate = mutationRate
        self.crossoverRate = crossoverRate
        self.eliteCount = eliteCount
        self.selectionStrategy = selectionStrategy
        self.crossoverStrategy = crossoverStrategy
        self.convergenceThreshold = convergenceThreshold
        self.convergencePatience = convergencePatience
        self.adaptiveMutation = adaptiveMutation
        self.diversityThreshold = diversityThreshold
        self.immigrationRate = immigrationRate
        self.greedySeedFraction = greedySeedFraction
        self.enableRepair = enableRepair
        self.adaptiveCrossover = adaptiveCrossover
        self.memeticHillClimbInterval = memeticHillClimbInterval
        self.memeticHillClimbCandidates = memeticHillClimbCandidates
        self.memeticHillClimbSteps = memeticHillClimbSteps
        self.chcMaxRestarts = chcMaxRestarts
        self.chcRestartEliteFraction = chcRestartEliteFraction
        self.chcRestartMutationRate = chcRestartMutationRate
        self.selfAdaptiveRates = selfAdaptiveRates
        self.wallclockTimeout = wallclockTimeout
    }

    static let `default` = GAConfiguration(
        populationSize: 100,
        maxGenerations: 200,
        mutationRate: 0.15,
        crossoverRate: 0.8,
        eliteCount: 3,
        selectionStrategy: .tournament(size: 3),
        crossoverStrategy: .contextual(temperature: 0.5),
        convergenceThreshold: 0.001,
        convergencePatience: 30,
        adaptiveMutation: true,
        diversityThreshold: 0.01,
        immigrationRate: 0.1,
        greedySeedFraction: 0.15,
        enableRepair: true,
        adaptiveCrossover: true,
        memeticHillClimbInterval: 25,
        memeticHillClimbCandidates: 3,
        memeticHillClimbSteps: 6,
        chcMaxRestarts: 1,
        chcRestartEliteFraction: 0.15,
        chcRestartMutationRate: 0.35,
        selfAdaptiveRates: true,
        wallclockTimeout: 8.0
    )

    static let quick = GAConfiguration(
        populationSize: 50,
        maxGenerations: 80,
        mutationRate: 0.2,
        crossoverRate: 0.8,
        eliteCount: 2,
        selectionStrategy: .tournament(size: 3),
        crossoverStrategy: .contextual(temperature: 0.7),
        convergenceThreshold: 0.005,
        convergencePatience: 10,
        adaptiveMutation: false,
        diversityThreshold: 0.01,
        immigrationRate: 0.1,
        greedySeedFraction: 0.2,
        enableRepair: true,
        adaptiveCrossover: false,
        wallclockTimeout: 3.0
    )

    /// Ultra-fast config for live preview and drag-to-schedule reflow.
    /// ~20 generations, ~100ms on modern hardware.
    /// Trades optimality for speed — good enough for preview, not final schedule.
    /// Uses single-point crossover to skip attention-scoring overhead.
    static let instant = GAConfiguration(
        populationSize: 20,
        maxGenerations: 20,
        mutationRate: 0.25,
        crossoverRate: 0.7,
        eliteCount: 1,
        selectionStrategy: .tournament(size: 2),
        crossoverStrategy: .singlePoint,
        convergenceThreshold: 0.01,
        convergencePatience: 5,
        adaptiveMutation: false,
        diversityThreshold: 0.05,
        immigrationRate: 0.0,
        greedySeedFraction: 0.3,
        enableRepair: true,
        adaptiveCrossover: false,
        wallclockTimeout: 0.5
    )

    static let thorough = GAConfiguration(
        populationSize: 200,
        maxGenerations: 500,
        mutationRate: 0.1,
        crossoverRate: 0.85,
        eliteCount: 5,
        selectionStrategy: .tournament(size: 5),
        crossoverStrategy: .contextual(temperature: 0.5),
        convergenceThreshold: 0.0005,
        convergencePatience: 50,
        adaptiveMutation: true,
        diversityThreshold: 0.005,
        immigrationRate: 0.15,
        greedySeedFraction: 0.1,
        enableRepair: true,
        adaptiveCrossover: true,
        memeticHillClimbInterval: 40,
        memeticHillClimbCandidates: 5,
        memeticHillClimbSteps: 10,
        chcMaxRestarts: 2,
        chcRestartEliteFraction: 0.15,
        chcRestartMutationRate: 0.35,
        selfAdaptiveRates: true,
        wallclockTimeout: 20.0
    )

    /// Per-island config for island model GA. Smaller populations per island
    /// since total individuals = populationSize * islandCount.
    /// Uses contextual crossover and gradient refinement; IslandModelGA
    /// diversifies strategies across islands.
    static let island = GAConfiguration(
        populationSize: 60,
        maxGenerations: 400,
        mutationRate: 0.12,
        crossoverRate: 0.85,
        eliteCount: 3,
        selectionStrategy: .tournament(size: 4),
        crossoverStrategy: .contextual(temperature: 0.5),
        convergenceThreshold: 0.0005,
        convergencePatience: 40,
        adaptiveMutation: true,
        diversityThreshold: 0.008,
        immigrationRate: 0.1,
        greedySeedFraction: 0.1,
        enableRepair: true,
        adaptiveCrossover: true,
        memeticHillClimbInterval: 30,
        memeticHillClimbCandidates: 3,
        memeticHillClimbSteps: 8,
        selfAdaptiveRates: true,
        wallclockTimeout: 12.0
    )
}

// MARK: - GA Progress

struct GAProgress: Sendable {
    let generation: Int
    let bestFitness: Double
    let averageFitness: Double
    let diversity: Double
}

// MARK: - Multi-Objective Selection Hook

/// Plumbing that lets the generic `GeneticAlgorithm<C>` invoke NSGA-III
/// survivor selection when the chromosome exposes per-objective scores.
/// Chromosomes without a multi-objective breakdown (e.g. permutation
/// genomes used by `PomodoroSequenceChromosome`) pass `nil` and the
/// engine falls back to scalar-fitness generational replacement.
struct MultiObjectiveContext<C: Chromosome>: @unchecked Sendable {
    /// Adaptive NSGA-III ranker. Reference points grow around crowded
    /// niches and prune vacant ones (Jain & Deb, 2014). There is no
    /// static-ranker alternative — the adaptive variant subsumes the
    /// fixed Das–Dennis grid as its initial state.
    let adaptiveRanker: AdaptiveNSGA3

    let objectiveVectorOf: (C) -> [Double]

    /// Hypervolume estimator used for last-front tiebreaking inside
    /// survivor selection.
    let hypervolume: HypervolumeEstimator

    /// Optional MOEA/D-AWA state. When non-nil the engine's survivor
    /// path delegates selection to MOEAD (decomposition-based for
    /// many-objective problems) instead of NSGA-III. The adaptive
    /// weight adjustment fires on its internal cadence. Setting this
    /// is an opt-in for callers that have ≥8 objectives where
    /// NSGA-III's reference-point niching degrades.
    let moeadState: MOEADState?

    /// Ranker snapshot for the current generation. Taken from the
    /// adaptive variant so reference-point evolution is observed by
    /// every selection call.
    var activeRanker: NSGA3 { adaptiveRanker.currentRanker }

    /// Produce the NSGA-III harness for the default 13-objective
    /// ScheduleChromosome evaluator. Reads `objectiveCache` directly so
    /// no extra evaluation runs during survivor selection.
    static func schedule(
        evaluator: FitnessEvaluator,
        populationSize: Int,
        hypervolumeSampleCount: Int = 8_000,
        hypervolumeSeed: UInt64 = 0x5EED_F2_2026,
        moeadState: MOEADState? = nil
    ) -> MultiObjectiveContext<ScheduleChromosome> {
        let names = evaluator.objectives.map(\.name)
        // Combined parent + offspring pool is 2·N, so feed NSGA-III that
        // many reference directions — each individual can be associated
        // with a distinct direction in dense regions of the simplex.
        let base = NSGA3.forPopulation(
            objectiveCount: names.count,
            populationSize: max(2, populationSize * 2)
        )
        let adaptive = AdaptiveNSGA3(base: base)
        let hv = HypervolumeEstimator(
            objectiveCount: names.count,
            sampleCount: hypervolumeSampleCount,
            seed: hypervolumeSeed
        )
        return MultiObjectiveContext<ScheduleChromosome>(
            adaptiveRanker: adaptive,
            objectiveVectorOf: { chromosome in
                if let cache = chromosome.objectiveCache, !cache.isEmpty {
                    return names.map { cache[$0] ?? 0.0 }
                }
                return names.map { _ in 0.0 }
            },
            hypervolume: hv,
            moeadState: moeadState
        )
    }
}

// MARK: - Genetic Algorithm Engine

/// The core genetic algorithm engine, generic over chromosome type.
/// Thread safety: instances are created and used within a single Task.detached block.
final class GeneticAlgorithm<C: Chromosome>: @unchecked Sendable {
    let config: GAConfiguration
    let context: OptimizerContext
    private let evaluate: (inout C) -> Void

    /// Optional batch evaluator. When present, offspring are scored
    /// with this closure in one shot instead of the per-chromosome
    /// loop. Lets the caller install a multi-fidelity funnel
    /// (surrogate tier + promoted tier-2 full evaluation) without
    /// per-individual overhead. When nil the engine falls back to
    /// the per-chromosome `evaluate` closure.
    private let batchEvaluate: ((inout [C]) -> Void)?

    private var onProgress: ((GAProgress) -> Void)?
    private let multiObjective: MultiObjectiveContext<C>?

    /// Generic hook closures for QD archive feeding, gradient
    /// refinement, telemetry — anything outside the engine's core
    /// evolution logic. Closures are constructed by the caller and
    /// captured by reference to schedule-specific state (archives,
    /// refiners) without leaking those types into the engine.
    let hooks: EvolutionHooks<C>

    private(set) var bestEver: C?
    private(set) var convergenceGeneration: Int = 0

    init(
        config: GAConfiguration = .default,
        context: OptimizerContext,
        evaluate: @escaping (inout C) -> Void,
        onProgress: ((GAProgress) -> Void)? = nil,
        multiObjective: MultiObjectiveContext<C>? = nil,
        hooks: EvolutionHooks<C> = .noop,
        batchEvaluate: ((inout [C]) -> Void)? = nil
    ) {
        self.config = config
        self.context = context
        self.evaluate = evaluate
        self.batchEvaluate = batchEvaluate
        self.onProgress = onProgress
        self.multiObjective = multiObjective
        self.hooks = hooks
    }

    /// Run the full GA and return the final population (sorted by fitness).
    /// Throws `CancellationError` when the enclosing `Task` is cancelled —
    /// the caller receives whatever was evolved before cancellation via
    /// `bestEver` / partial population observation.
    func run() throws -> [C] {
        var population = createInitialPopulation()
        return try evolve(&population)
    }

    /// Run the GA seeded with an existing population. Same cancellation
    /// semantics as `run()`.
    func runSeeded(with seed: [C]) throws -> [C] {
        var population = Population<C>(
            individuals: seed,
            eliteCount: config.eliteCount
        )

        // Fill up to population size with random individuals if needed
        while population.individuals.count < config.populationSize {
            var individual = C.random(context: context)
            evaluate(&individual)
            population.individuals.append(individual)
        }

        return try evolve(&population)
    }

    // MARK: - Initial Population with Greedy Seeding

    /// Create initial population with a mix of greedy-seeded and random individuals.
    /// Greedy seeds provide feasible starting points; random individuals maintain diversity.
    private func createInitialPopulation() -> Population<C> {
        let greedyCount = max(0, Int(Double(config.populationSize) * config.greedySeedFraction))
        let randomCount = config.populationSize - greedyCount

        var individuals: [C] = []

        // CP-SAT prophet seed: when the context exposes a
        // `CPSATRepairer`, try once to get a fully feasible placement
        // from the CP solver and slot it in as the first greedy
        // individual. It considers every event jointly (unlike
        // per-event greedy) and respects the precedence DAG at the
        // search level, so on a tight week the CP seed reliably
        // clears the "one priority-first greedy run couldn't fit
        // everything" infeasibility trap. The call is fire-and-forget
        // — a nil return (timeout, empty domain, non-schedule GA)
        // falls back to pure greedy below.
        var cpSeedPlaced = false
        if greedyCount > 0,
           let cpSeed = ScheduleChromosome.cpSeeded(context: context) as? C {
            individuals.append(cpSeed)
            cpSeedPlaced = true
        }

        // Greedy seeds: each gets a slight random perturbation for variety.
        // When a CP seed landed above, the first greedy slot is already
        // filled — start greedy seeding from index 1 so the total
        // population count still matches `greedyCount`.
        let greedyStart = cpSeedPlaced ? 1 : 0
        for i in greedyStart..<greedyCount {
            var individual = C.greedy(context: context)
            // Lightly mutate non-first greedy seeds for diversity
            if i > 0 {
                individual.mutate(rate: 0.1 + Double(i) * 0.05, context: context)
            }
            individuals.append(individual)
        }

        // Random individuals
        for _ in 0..<randomCount {
            individuals.append(C.random(context: context))
        }

        // Bootstrap self-adaptive rates, when enabled, on every AdaptiveMutation
        // chromosome. Starting them at the config's baseline rate means evolution
        // can only improve from there — the initial behaviour matches the old
        // fixed-rate config, and drift into better rates is additive.
        if config.selfAdaptiveRates {
            for i in individuals.indices {
                if var adaptive = individuals[i] as? ScheduleChromosome {
                    adaptive.selfAdaptiveMutationRate = config.mutationRate
                    if let casted = adaptive as? C {
                        individuals[i] = casted
                    }
                }
            }
        }

        return Population<C>(individuals: individuals, eliteCount: config.eliteCount)
    }

    // MARK: - Core Evolution Loop

    private func evolve(_ population: inout Population<C>) throws -> [C] {
        // Repair initial population if enabled
        if config.enableRepair {
            for i in population.individuals.indices {
                population.individuals[i].repair(context: context)
            }
        }

        population.evaluateAll(using: evaluate)
        bestEver = population.individuals.max(by: { $0.rawFitness < $1.rawFitness })

        var staleGenerations = 0
        var lastBestFitness = bestEver?.rawFitness ?? 0
        var restartsPerformed = 0
        let wallclockStart = Date()

        // Soft deadline semantics: the timeout check sits at the top
        // of the loop *after* the previous generation has fully
        // committed (offspring evaluated, bestEver updated, memetic
        // hill climb applied, onGenerationComplete hook run). So when
        // we break, `bestEver` and the population are in a consistent
        // state — never mid-generation. The subsequent post-loop hill
        // climb still runs, but scales its effort to whatever budget
        // is left (see `remainingWallclock` below) so the total wall
        // time stays bounded even on interactive configs.
        for generation in 0..<config.maxGenerations {
            // Cooperative cancellation: UI-triggered task cancellation
            // lands here. `bestEver` is already populated with whatever
            // the current best is, so callers catching CancellationError
            // can still surface a usable result.
            try Task.checkCancellation()

            // Wallclock ceiling: soft cap, consulted only between
            // generations. A generation in flight always gets to
            // finish so the population invariants survive.
            if config.wallclockTimeout > 0 &&
                Date().timeIntervalSince(wallclockStart) >= config.wallclockTimeout {
                convergenceGeneration = generation
                break
            }

            evolveOneGeneration(
                &population,
                config: config,
                generation: generation,
                maxGenerations: config.maxGenerations,
                parallelEvaluation: true,
                staleGenerations: staleGenerations
            )

            // Memetic hill climb on the current top individuals every
            // `memeticHillClimbInterval` generations. Applying SA locally to
            // the elites mid-evolution lets their refinements propagate through
            // subsequent selection rounds, which the final-only hill climb
            // cannot — by then the GA is done and no downstream selection
            // benefits. We write results back into the population so selection
            // in the next generation sees the improved fitness.
            if config.memeticHillClimbInterval > 0,
               generation > 0,
               generation % config.memeticHillClimbInterval == 0 {
                memeticHillClimbStep(
                    population: &population,
                    candidates: config.memeticHillClimbCandidates,
                    steps: config.memeticHillClimbSteps
                )
            }

            // Generation-complete hook. The host wires gradient
            // refinement, QD archive emitter injection, and any other
            // schedule-specific operations here — the engine stays
            // generic over `C`.
            hooks.onGenerationComplete?(generation, &population, context)

            // Use rawFitness so fitness sharing (which deflates `fitness` for
            // crowded niches) can't demote the globally-best individual. Store
            // a normalized copy (fitness == rawFitness) so external inspectors
            // see the true quality, not a shared-fitness snapshot.
            if let currentBest = population.individuals.max(by: { $0.rawFitness < $1.rawFitness }) {
                if bestEver == nil || currentBest.rawFitness > bestEver!.rawFitness {
                    var snapshot = currentBest
                    if snapshot.rawFitness > 0 { snapshot.fitness = snapshot.rawFitness }
                    bestEver = snapshot
                }
            }

            let fitnessDiversity = population.fitnessDiversity
            onProgress?(GAProgress(
                generation: generation,
                bestFitness: bestEver?.rawFitness ?? 0,
                averageFitness: population.averageFitness,
                diversity: fitnessDiversity
            ))

            // Per-generation trace — compiled out of release. One
            // line per generation tells you fitness progression,
            // diversity, and stagnation at a glance; searching for
            // "STAGNATION" / "RESTART" / "DROP" surfaces the
            // three-character events worth looking at first.
            GADebugLog.trace(
                "gen",
                String(
                    format: "%03d fit=%.4f avg=%.4f div=%.3f stale=%d",
                    generation,
                    bestEver?.rawFitness ?? 0,
                    population.averageFitness,
                    fitnessDiversity,
                    staleGenerations
                )
            )

            // Regression detector: with elitism enabled, best-fitness
            // should never decrease generation-over-generation. When
            // it does, something's wrong — usually an
            // accidentally-missed elite copy, or a survivor selection
            // bug that promoted a worse individual. Log loudly.
            let currentFitness = bestEver?.rawFitness ?? 0
            if generation > 0 && currentFitness < lastBestFitness - 1e-6 {
                GADebugLog.warn(
                    site: "fitnessDrop",
                    message: "bestEver regressed — elitism failed to preserve best",
                    context: [
                        "gen": "\(generation)",
                        "prev": String(format: "%.6f", lastBestFitness),
                        "now": String(format: "%.6f", currentFitness),
                        "delta": String(format: "%.6f", lastBestFitness - currentFitness)
                    ]
                )
            }

            // Relative convergence detection: handles both small and large fitness values.
            // Use rawFitness so fitness sharing can't confuse stagnation detection.
            let relativeImprovement = lastBestFitness > 1e-9
                ? abs(currentFitness - lastBestFitness) / lastBestFitness
                : abs(currentFitness - lastBestFitness)

            if relativeImprovement < config.convergenceThreshold {
                staleGenerations += 1
            } else {
                staleGenerations = 0
                convergenceGeneration = generation
            }
            lastBestFitness = currentFitness

            if staleGenerations >= config.convergencePatience {
                // CHC restart: before giving up, try regenerating the
                // non-elite portion from the surviving elites via high-rate
                // mutation. This often escapes deep basins where plain
                // immigration can't — the elites' discovered structure is
                // preserved but the majority of the population is re-seeded
                // in a meaningfully different neighbourhood.
                if restartsPerformed < config.chcMaxRestarts {
                    GADebugLog.trace(
                        "restart",
                        "CHC restart #\(restartsPerformed + 1) at gen \(generation) after \(staleGenerations) stale"
                    )
                    chcRestart(
                        population: &population,
                        config: config
                    )
                    restartsPerformed += 1
                    staleGenerations = 0
                    // Don't reset convergenceGeneration; the reported value
                    // should still reflect when the bestEver was last
                    // improved, not when we decided to relaunch.
                    continue
                }
                convergenceGeneration = generation - config.convergencePatience
                break
            }
        }

        // Local search: refine top individuals with SA-hybrid hill climbing.
        //
        // Budget-aware sizing: when we exited the evolution loop via
        // the wallclock break, the final hill-climb still runs because
        // it often delivers the best gains on the polished elites, but
        // it scales its per-individual step count to whatever budget
        // remains so we don't overshoot the caller's deadline. If
        // nothing is left, one pass of 3 steps still runs — a cheap
        // improvement that's almost always worth the milliseconds.
        var sorted = population.sortedByFitness
        let refineCount = min(config.eliteCount, sorted.count)
        let climbSteps: Int = {
            guard config.wallclockTimeout > 0 else { return 20 }
            let remaining = config.wallclockTimeout - Date().timeIntervalSince(wallclockStart)
            let budgetRatio = remaining / config.wallclockTimeout
            if budgetRatio >= 0.25 { return 20 }
            if budgetRatio >= 0.0 { return 8 }
            return 3
        }()
        for i in 0..<refineCount {
            sorted[i] = hillClimb(sorted[i], steps: climbSteps)
        }

        // Update bestEver if hill climbing found something better (compare rawFitness).
        if let refined = sorted.max(by: { $0.rawFitness < $1.rawFitness }),
           bestEver == nil || refined.rawFitness > bestEver!.rawFitness {
            var snapshot = refined
            if snapshot.rawFitness > 0 { snapshot.fitness = snapshot.rawFitness }
            bestEver = snapshot
        }

        return sorted.sorted { $0.rawFitness > $1.rawFitness }
    }

    // MARK: - Single Generation (shared with IslandModelGA)

    /// Evolve a population for one generation: immigration, selection, crossover,
    /// repair, adaptive mutation, fitness evaluation/sharing, and replacement.
    ///
    /// When `parallelEvaluation` is true, offspring fitness is evaluated using
    /// `DispatchQueue.concurrentPerform`. Set to false when the caller already
    /// runs multiple islands in parallel to avoid GCD thread pool oversubscription.
    ///
    /// - Important: Internal API for `IslandModelGA`. Do not call directly from
    ///   application code — use `run()` or `runSeeded(with:)` instead.
    func evolveOneGeneration(
        _ population: inout Population<C>,
        config: GAConfiguration,
        generation: Int,
        maxGenerations: Int,
        parallelEvaluation: Bool = true,
        staleGenerations: Int = 0
    ) {
        let fitnessDiversity = population.fitnessDiversity
        // Use genotypic diversity for a more accurate diversity signal.
        // Fitness diversity can be misleading when different schedules have similar scores.
        // Fall back to fitness diversity when genotypic is expensive (large populations).
        let genotypicDiv = population.size <= 100 ? population.genotypicDiversity(rng: context.rng) : fitnessDiversity
        let diversityIsLow = genotypicDiv < config.diversityThreshold

        // Refresh the contextual bandit's context vector so the operator
        // chosen during mutation reflects the current GA regime. Imbalance
        // is the std dev across objectives on the best individual — reads
        // the cached breakdown (delta-eval keeps it fresh).
        let imbalance = objectiveImbalance(in: population)
        let stagnation = config.convergencePatience > 0
            ? min(1.0, Double(staleGenerations) / Double(max(1, config.convergencePatience)))
            : 0.0
        // Graph-derived context features. Only meaningful for
        // `ScheduleChromosome` populations whose context exposes a
        // conflict graph; non-schedule GAs (Pomodoro sequencing) just
        // leave the graph fields at zero, preserving their existing
        // bandit behaviour.
        let graphFeatures = Self.graphBanditFeatures(
            in: population,
            context: context
        )
        context.mutationBandit.updateContext(BanditContext(
            diversity: min(1.0, genotypicDiv / max(1e-6, config.diversityThreshold * 4)),
            stagnation: stagnation,
            imbalance: imbalance,
            precedenceViolationRate: graphFeatures.precedenceViolationRate,
            conflictDensity: graphFeatures.conflictDensity,
            maxChainDepth: graphFeatures.maxChainDepth
        ))

        // Immigration: inject random individuals when diversity collapses
        if diversityIsLow && config.immigrationRate > 0 {
            let immigrantCount = max(1, Int(Double(config.populationSize) * config.immigrationRate))
            population.injectImmigrants(count: immigrantCount, context: context, evaluate: evaluate)
        }

        // Adaptive crossover rate: higher early (exploration), lower late (exploitation)
        let effectiveCrossoverRate: Double
        if config.adaptiveCrossover {
            let progress = Double(generation) / Double(maxGenerations)
            effectiveCrossoverRate = config.crossoverRate * max(0.5, 1.0 - 0.3 * progress)
        } else {
            effectiveCrossoverRate = config.crossoverRate
        }

        var offspring: [C] = []
        // Baseline fitness per offspring, used to compute the reward that
        // feeds back into the MutationBandit. We capture max(parent1, parent2)
        // because a useful mutation should improve on the better parent, not
        // merely the worse one. Parallel array indexed the same as `offspring`.
        var offspringBaselines: [Double] = []
        // NSGA-III uses (μ+λ) survivor selection, so we generate a full
        // offspring population of size N and combine it with the current
        // population before ranking. That preserves the "better parent
        // must win" invariant without special-casing elitism — top-ranked
        // parents survive because they land on front 0. The scalar-only
        // fallback (no multiObjective) keeps the generational N − elites
        // target because `replaceGeneration` re-appends elites on its own.
        let targetCount = multiObjective != nil
            ? config.populationSize
            : config.populationSize - config.eliteCount

        while offspring.count < targetCount {
            let (idx1, idx2) = Selection.selectPairIndices(
                from: population,
                strategy: config.selectionStrategy,
                rng: context.rng
            )
            let parent1 = population.individuals[idx1]
            let parent2 = population.individuals[idx2]
            let baseline = max(parent1.rawFitness, parent2.rawFitness)

            var child1: C
            var child2: C

            if context.rng.bool(probability: effectiveCrossoverRate) {
                (child1, child2) = parent1.crossover(with: parent2, strategy: config.crossoverStrategy, context: context)
            } else {
                child1 = parent1
                child2 = parent2
            }

            // Diversity-driven adaptive mutation: boost when population converges,
            // decay with generation progress, but never below 10% of base rate
            let rate: Double
            if config.adaptiveMutation {
                let generationDecay = max(0.1, 1.0 - Double(generation) / Double(maxGenerations))
                let diversityBoost = diversityIsLow ? 2.5 : 1.0
                rate = min(1.0, config.mutationRate * generationDecay * diversityBoost)
            } else {
                rate = config.mutationRate
            }

            child1.mutate(rate: rate, context: context)
            child2.mutate(rate: rate, context: context)

            // Repair constraint violations post-mutation
            if config.enableRepair {
                child1.repair(context: context)
                child2.repair(context: context)
            }

            // When we'd overshoot by 1, only keep child1
            let remaining = targetCount - offspring.count
            if remaining >= 2 {
                offspring.append(child1)
                offspring.append(child2)
                offspringBaselines.append(baseline)
                offspringBaselines.append(baseline)
            } else {
                offspring.append(child1)
                offspringBaselines.append(baseline)
            }
        }

        // Fitness evaluation: prefer the batch path when wired so
        // the multi-fidelity funnel can rank-then-promote across the
        // whole offspring array. Per-chromosome fallback preserves
        // parallelism via concurrentPerform — but only when there's
        // enough work to amortize GCD's per-iteration dispatch cost.
        //
        // Parallelism threshold: below ~32 offspring the GCD
        // concurrentPerform overhead (thread wake-up + work item
        // queuing) swallows the evaluation work itself. Measured on
        // Apple Silicon, a 20-individual `.instant` population
        // evaluates faster serially than in parallel. The threshold
        // can go lower for expensive objectives, but 32 is a safe
        // default across the evaluator stack.
        let parallelThreshold = 32
        if let batchEvaluate {
            batchEvaluate(&offspring)
        } else if parallelEvaluation && offspring.count >= parallelThreshold {
            DispatchQueue.concurrentPerform(iterations: offspring.count) { i in
                self.evaluate(&offspring[i])
            }
        } else {
            for i in offspring.indices {
                evaluate(&offspring[i])
            }
        }

        // Close the MutationBandit feedback loop. Reward is (rawFitness - baseline)
        // so arms get credit only for beating the better parent. LinUCB handles
        // the context attribution internally; we just supply the raw delta.
        for i in offspring.indices {
            guard let adaptive = offspring[i] as? any AdaptiveMutationChromosome,
                  let op = adaptive.lastMutationOperator else { continue }
            let reward = offspring[i].rawFitness - offspringBaselines[i]
            context.mutationBandit.record(op: op, reward: reward)

            // Second feedback channel: when the LNS operator fired, reward
            // both ends of the destroy × repair pair with the same delta.
            // Training both bandits on the same fitness signal is the
            // standard Ropke–Pisinger setup: independent draws, identical
            // reward, so the product of weights converges on the true
            // pair quality without needing 15 explicit pair arms.
            // Only `ScheduleChromosome` exposes the LNS telemetry —
            // guarding on the concrete type avoids polluting
            // `AdaptiveMutationChromosome` with LNS-only properties.
            if op == .lnsDay, let schedule = offspring[i] as? ScheduleChromosome {
                if let destroy = schedule.lastDestroyStrategy {
                    context.lnsStrategyBandit.record(strategy: destroy, reward: reward)
                }
                if let repair = schedule.lastRepairStrategy {
                    context.lnsRepairBandit.record(strategy: repair, reward: reward)
                }
            }
        }

        // Survivor selection: (μ+λ) combine, then delegate to either
        // MOEA/D-AWA (when wired) or adaptive NSGA-III + HypE-lite
        // last-front tiebreak. Scalar generational replacement is
        // the no-multiobjective fallback.
        if let mo = multiObjective {
            let combined = population.individuals + offspring
            let vectors = combined.map(mo.objectiveVectorOf)
            let survivorIndices: [Int]
            var frontOfLocal: [Int: Int] = [:]
            var nicheOfLocal: [Int: Int] = [:]
            var distLocal: [Int: Double] = [:]

            if let moead = mo.moeadState {
                // MOEA/D-AWA survivor path. Tchebycheff scalarisation
                // over Das–Dennis weights; AWA periodically relocates
                // stagnant subproblems. All survivors are treated as
                // front 0 with neutral niche metadata.
                let candidates = vectors.enumerated().map { (idx, v) in
                    (index: idx, objectives: v)
                }
                moead.updateIncumbents(candidates: candidates)
                let chosen = moead.selectedIndices(from: candidates)
                survivorIndices = Array(chosen.prefix(config.populationSize))
                for localIdx in 0..<survivorIndices.count {
                    frontOfLocal[localIdx] = 0
                    nicheOfLocal[localIdx] = 0
                    distLocal[localIdx] = 0
                }
            } else {
                let activeRanker = mo.activeRanker
                // Fold the observed per-axis minimum into the hypervolume
                // estimator's nadir so the Monte Carlo sampling box
                // tracks the achievable region.
                mo.hypervolume.updateNadir(from: vectors)
                let ranked = mo.hypervolume.survivorsWithNSGA3(
                    vectors,
                    keeping: config.populationSize,
                    using: activeRanker
                )
                survivorIndices = ranked
                // Re-select via the ranker so the scalar-fitness rewrite
                // has niche metadata available.
                let result = activeRanker.select(vectors, count: config.populationSize)
                mo.adaptiveRanker.observe(result, updateInterval: 10)
                for (localIdx, combinedIdx) in survivorIndices.enumerated() {
                    frontOfLocal[localIdx] = result.frontOf[combinedIdx] ?? 0
                    nicheOfLocal[localIdx] = result.nicheOf[combinedIdx] ?? 0
                    distLocal[localIdx] = result.distanceToNiche[combinedIdx] ?? 0
                }
            }

            var nextIndividuals = survivorIndices.map { combined[$0] }
            let localResult = NSGA3.SelectionResult(
                selectedIndices: Array(0..<nextIndividuals.count),
                frontOf: frontOfLocal,
                nicheOf: nicheOfLocal,
                distanceToNiche: distLocal
            )
            NSGA3.applyScalarFitness(localResult, to: &nextIndividuals)
            population.individuals = nextIndividuals
        } else {
            population.replaceGeneration(with: offspring)
        }

        // Offspring-evaluated hook — host wires QD archive feeding,
        // surrogate calibration, telemetry. Engine stays generic.
        hooks.onOffspringEvaluated?(generation, offspring, context)
    }

    // MARK: - Graph Bandit Features

    /// Graph-derived bandit context features summarised into a tuple so
    /// the caller can splat them into `BanditContext`. Non-schedule
    /// chromosomes return zeros — the bandit then behaves like the
    /// pre-graph implementation on those workloads.
    fileprivate struct GraphBanditFeatures {
        var precedenceViolationRate: Double = 0
        var conflictDensity: Double = 0
        var maxChainDepth: Double = 0
    }

    /// Compute graph features for the bandit context. Looks up the
    /// best individual (by rawFitness) and, when the chromosome is a
    /// `ScheduleChromosome`, queries the conflict graph for structural
    /// metrics. Static so the schedule-specific branch can be read by
    /// `evolveOneGeneration` without dragging the cast into the hot
    /// method body.
    fileprivate static func graphBanditFeatures(
        in population: Population<C>,
        context: OptimizerContext
    ) -> GraphBanditFeatures {
        guard let best = population.individuals.max(by: { $0.rawFitness < $1.rawFitness }) else {
            return GraphBanditFeatures()
        }
        // The GA is generic over chromosome type, so we dip into the
        // schedule-specific representation only when the cast succeeds.
        // Pomodoro and other chromosome flavours get a neutral feature
        // set — no behavioural change.
        guard let scheduleBest = best as? ScheduleChromosome else {
            return GraphBanditFeatures()
        }
        let graph = context.ensureConflictGraph()
        guard graph.eventIds.count > 0 else { return GraphBanditFeatures() }

        // Precedence violation rate: fraction of direct dependency
        // edges with gap < 0 on the best individual. Zero by
        // construction once repair runs successfully, so this mostly
        // signals "the GA is trying to crack a very tight packing
        // problem" during early generations.
        var geneByEvent: [String: ScheduleGene] = [:]
        for gene in scheduleBest.genes where gene.isIncluded {
            geneByEvent[gene.eventId] = gene
        }
        var violations = 0
        var pairs = 0
        for (prereq, dependents) in graph.directPrecedes {
            guard let prereqGene = geneByEvent[prereq] else { continue }
            for dep in dependents {
                guard let depGene = geneByEvent[dep] else { continue }
                pairs += 1
                if depGene.startTime < prereqGene.endTime {
                    violations += 1
                }
            }
        }
        let precedenceViolationRate = pairs > 0
            ? Double(violations) / Double(pairs)
            : 0

        return GraphBanditFeatures(
            precedenceViolationRate: precedenceViolationRate,
            conflictDensity: graph.conflictDensity,
            maxChainDepth: graph.maxChainDepth
        )
    }

    // MARK: - Objective Imbalance (bandit context feature)

    /// Std dev across objective scores on the population's current best
    /// individual, mapped to [0, 1]. High values mean one objective is
    /// dominating — telling the bandit "switch tactics." Returns 0 when
    /// no multi-objective breakdown is available.
    private func objectiveImbalance(in population: Population<C>) -> Double {
        guard let mo = multiObjective else { return 0 }
        guard let best = population.individuals.max(by: { $0.rawFitness < $1.rawFitness }) else { return 0 }
        let v = mo.objectiveVectorOf(best)
        guard v.count > 1 else { return 0 }
        let mean = v.reduce(0, +) / Double(v.count)
        let variance = v.reduce(0.0) { $0 + ($1 - mean) * ($1 - mean) } / Double(v.count)
        // Max std dev on a [0, 1]-clamped vector is 0.5 (half ones, half zeros),
        // so dividing by 0.5 gives a [0, 1] range.
        return min(1.0, variance.squareRoot() / 0.5)
    }

    // MARK: - CHC Restart

    /// Keep the top-K elites, regenerate the rest from those elites via
    /// high-rate mutation. "K" = `chcRestartEliteFraction * populationSize`,
    /// clamped to at least `eliteCount` so elitism guarantees survive the
    /// restart. Regenerated individuals are parented on a randomly-chosen
    /// elite each, repaired, and re-evaluated before the GA continues.
    ///
    /// This is CHC Eshelman-style: the "cataclysmic mutation" phase the
    /// algorithm is known for. We don't implement the full HUX/restart
    /// machinery — we're only using the restart idea to replace a hard
    /// stop — but the core hypothesis (preserve structure, perturb the
    /// rest heavily) is the same.
    private func chcRestart(
        population: inout Population<C>,
        config: GAConfiguration
    ) {
        let n = population.individuals.count
        guard n > 0 else { return }

        // Elite count: from config, bumped to ensure structure survives
        // and the fraction isn't so small we effectively random-restart.
        let fractionBasedElites = Int(Double(n) * config.chcRestartEliteFraction)
        let elitesToKeep = max(config.eliteCount, max(1, fractionBasedElites))

        // Take elites by rawFitness — consistent with bestEver tracking and
        // immune to fitness sharing that may have deflated `fitness`.
        let sorted = population.individuals.sorted { $0.rawFitness > $1.rawFitness }
        let elites = Array(sorted.prefix(elitesToKeep))

        var regenerated: [C] = elites
        regenerated.reserveCapacity(n)

        // Repopulate by cloning a random elite and hammering it with the
        // CHC-level mutation rate. Repair brings it back into feasibility
        // (working hours, overlap, dependencies). Evaluate closes the loop
        // so the next generation's selection sees true fitness.
        while regenerated.count < n {
            let template = elites[context.rng.int(in: 0..<elites.count)]
            var offspring = template
            offspring.mutate(rate: config.chcRestartMutationRate, context: context)
            if config.enableRepair {
                offspring.repair(context: context)
            }
            evaluate(&offspring)
            regenerated.append(offspring)
        }

        population.individuals = regenerated
    }

    // MARK: - Memetic Hill Climb

    /// Run a short SA hill climb on the top `candidates` individuals and
    /// write the refined versions back into the population. Unlike the
    /// final-phase hill climb, this operates *during* evolution so any
    /// improvements compound through subsequent selection rounds.
    ///
    /// Candidates are addressed by index to keep the update O(1) per slot;
    /// we pick the indices of the top individuals by `rawFitness` so fitness
    /// sharing (which deflates `fitness` for crowded niches) doesn't bias
    /// selection toward sparse but poorly-scored solutions.
    private func memeticHillClimbStep(
        population: inout Population<C>,
        candidates: Int,
        steps: Int
    ) {
        let n = population.individuals.count
        guard n > 0, candidates > 0, steps > 0 else { return }

        // Pick top-K indices by rawFitness. We avoid `sortedByFitness` here
        // because that would rely on the possibly-deflated `fitness` field.
        let topIndices = population.individuals.indices
            .sorted { population.individuals[$0].rawFitness > population.individuals[$1].rawFitness }
            .prefix(min(candidates, n))

        for idx in topIndices {
            let refined = hillClimb(population.individuals[idx], steps: steps)
            // Only accept a strictly better climb. Equal-fitness rewrites
            // are harmless for scoring but could displace a more-diverse
            // twin that the crowding/sharing pressure might prefer.
            if refined.rawFitness > population.individuals[idx].rawFitness {
                population.individuals[idx] = refined
            }
        }
    }

    // MARK: - Local Search (SA-Hybrid Hill Climbing)

    /// Simulated Annealing hybrid hill climbing: applies small perturbations
    /// and accepts improvements deterministically, but also accepts worse solutions
    /// with a probability that decreases over time (temperature cooling).
    /// This allows escaping shallow local optima that pure greedy hill climbing misses.
    ///
    /// - Important: Internal API for `IslandModelGA`. Do not call directly from
    ///   application code.
    func hillClimb(_ chromosome: C, steps: Int) -> C {
        var current = chromosome
        var temperature = 0.05
        let coolingRate = 0.85
        // Per-gene mutation probability for *fine-tuning*. The previous value
        // (0.3) mutated ~30% of genes per step — that's not a local-search
        // neighbourhood, that's a full mutation, so the SA temperature could
        // not actually hold on to good solutions. 0.05 yields ~1 gene changed
        // for typical 10-20 event schedules (and still more than one for very
        // large schedules, which is the right direction).
        let neighborhoodRate = 0.05

        for _ in 0..<steps {
            var neighbor = current
            neighbor.mutate(rate: neighborhoodRate, context: context)
            neighbor.repair(context: context)
            evaluate(&neighbor)

            let delta = neighbor.rawFitness - current.rawFitness
            if delta > 0 {
                // Always accept improvements
                current = neighbor
            } else if temperature > 1e-6 && context.rng.bool(probability: exp(delta / temperature)) {
                // Accept worse solution with SA probability
                current = neighbor
            }

            temperature *= coolingRate
        }

        return current
    }
}
