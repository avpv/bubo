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

    /// Enable fitness sharing (niching) to maintain diverse solution clusters.
    /// The sharing radius sigma controls niche size; smaller = more niches.
    var enableFitnessSharing: Bool
    var fitnessShareSigma: Double      // sharing radius in genotype distance [0, 1]
    var fitnessShareAlpha: Double      // shape parameter (1.0 = linear, 2.0 = quadratic)

    /// Enable crowding replacement instead of generational replacement.
    /// Children compete with their most similar parent, preserving diversity.
    var enableCrowding: Bool

    /// Enable adaptive crossover rate (decays with generation progress).
    var adaptiveCrossover: Bool

    /// Above this duplicate fraction, force-mutate clones in the offspring
    /// population with a boosted rate. 0 disables the mechanism. Measured in
    /// fraction of the post-offspring population that shares a genome with
    /// another individual.
    var duplicateMutationThreshold: Double

    /// Multiplier on `mutationRate` applied to clones when the threshold is
    /// exceeded. 2.5 is the literature sweet spot: aggressive enough to break
    /// the tie but gentle enough to keep the structure of the clone's parent.
    var duplicateMutationBoost: Double

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

    /// Blend raw fitness with behaviour-space novelty to escape deceptive
    /// local optima. 0 = pure fitness (legacy behaviour); values in
    /// (0, 1] pull selection pressure toward schedules that occupy sparse
    /// regions of `BehaviorDescriptor` space. 0.2 is a standard starting
    /// point from the novelty-search literature. Requires
    /// `context.noveltyArchive` to be set, otherwise the weight is ignored.
    var noveltyWeight: Double

    /// Enable Quality-Diversity via `MAPElitesArchive`. When set, every
    /// evaluated chromosome is offered to the archive, and (when seeded)
    /// the initial population draws elites from it for warm-start. Ignored
    /// when `context.mapElitesArchive` is nil.
    var enableMAPElites: Bool

    /// Route offspring evaluation through `context.multiFidelityEvaluator`
    /// when it's present and the current generation is still in the
    /// "early" half of the run. Under multi-fidelity, only top-K offspring
    /// (by the cheap proxy) see the full evaluator; the rest get the
    /// proxy score as a cheap-but-adequate stand-in. Roughly halves the
    /// evaluation budget on `.quick`/`.instant` configs.
    var useMultiFidelity: Bool

    /// Prune offspring evaluation through
    /// `FitnessEvaluator.progressiveEvaluate` using the current
    /// worst-elite fitness as the threshold. Infeasible-looking genomes
    /// get an early lower bound rather than a full 13-objective
    /// evaluation. Complements the surrogate pre-rank: surrogate filters
    /// on expected fitness, progressive filters during actual evaluation.
    var useProgressiveEvaluation: Bool

    /// When true, parallel offspring evaluation uses per-index
    /// sub-streams derived from `context.rng.split()` so any RNG reads
    /// that sneak into the evaluator (or future parallel mutation) stay
    /// deterministic under a fixed seed.
    var deterministicParallelEvaluation: Bool

    /// When true, `context.neuralOperatorPolicy` supersedes both bandits
    /// for operator selection. Off by default because REINFORCE is
    /// noisier than LinUCB on stationary landscapes; flip on for
    /// long-running / non-stationary runs where value estimates drift.
    var useNeuralPolicy: Bool

    /// Memberwise init with defaults for new parameters so existing call sites compile unchanged.
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
        enableFitnessSharing: Bool = false,
        fitnessShareSigma: Double = 0.3,
        fitnessShareAlpha: Double = 1.0,
        enableCrowding: Bool = false,
        adaptiveCrossover: Bool = false,
        duplicateMutationThreshold: Double = 0.2,
        duplicateMutationBoost: Double = 2.5,
        memeticHillClimbInterval: Int = 0,
        memeticHillClimbCandidates: Int = 3,
        memeticHillClimbSteps: Int = 5,
        chcMaxRestarts: Int = 0,
        chcRestartEliteFraction: Double = 0.15,
        chcRestartMutationRate: Double = 0.35,
        selfAdaptiveRates: Bool = false,
        noveltyWeight: Double = 0.0,
        enableMAPElites: Bool = false,
        useMultiFidelity: Bool = false,
        useProgressiveEvaluation: Bool = false,
        deterministicParallelEvaluation: Bool = false,
        useNeuralPolicy: Bool = false
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
        self.enableFitnessSharing = enableFitnessSharing
        self.fitnessShareSigma = fitnessShareSigma
        self.fitnessShareAlpha = fitnessShareAlpha
        self.enableCrowding = enableCrowding
        self.adaptiveCrossover = adaptiveCrossover
        self.duplicateMutationThreshold = duplicateMutationThreshold
        self.duplicateMutationBoost = duplicateMutationBoost
        self.memeticHillClimbInterval = memeticHillClimbInterval
        self.memeticHillClimbCandidates = memeticHillClimbCandidates
        self.memeticHillClimbSteps = memeticHillClimbSteps
        self.chcMaxRestarts = chcMaxRestarts
        self.chcRestartEliteFraction = chcRestartEliteFraction
        self.chcRestartMutationRate = chcRestartMutationRate
        self.selfAdaptiveRates = selfAdaptiveRates
        self.noveltyWeight = noveltyWeight
        self.enableMAPElites = enableMAPElites
        self.useMultiFidelity = useMultiFidelity
        self.useProgressiveEvaluation = useProgressiveEvaluation
        self.deterministicParallelEvaluation = deterministicParallelEvaluation
        self.useNeuralPolicy = useNeuralPolicy
    }

    static let `default` = GAConfiguration(
        populationSize: 100,
        maxGenerations: 200,
        mutationRate: 0.15,
        crossoverRate: 0.8,
        eliteCount: 3,
        selectionStrategy: .tournament(size: 3),
        crossoverStrategy: .singlePoint,
        convergenceThreshold: 0.001,
        convergencePatience: 30,
        adaptiveMutation: true,
        diversityThreshold: 0.01,
        immigrationRate: 0.1,
        greedySeedFraction: 0.15,
        enableRepair: true,
        enableFitnessSharing: false,
        fitnessShareSigma: 0.3,
        fitnessShareAlpha: 1.0,
        enableCrowding: false,
        adaptiveCrossover: true,
        memeticHillClimbInterval: 25,
        memeticHillClimbCandidates: 3,
        memeticHillClimbSteps: 6,
        chcMaxRestarts: 1,
        chcRestartEliteFraction: 0.15,
        chcRestartMutationRate: 0.35
    )

    static let quick = GAConfiguration(
        populationSize: 50,
        maxGenerations: 80,
        mutationRate: 0.2,
        crossoverRate: 0.8,
        eliteCount: 2,
        selectionStrategy: .tournament(size: 3),
        crossoverStrategy: .singlePoint,
        convergenceThreshold: 0.005,
        convergencePatience: 15,
        adaptiveMutation: false,
        diversityThreshold: 0.01,
        immigrationRate: 0.1,
        greedySeedFraction: 0.2,
        enableRepair: true,
        enableFitnessSharing: false,
        fitnessShareSigma: 0.3,
        fitnessShareAlpha: 1.0,
        enableCrowding: false,
        adaptiveCrossover: false
    )

    /// Ultra-fast config for live preview and drag-to-schedule reflow.
    /// ~20 generations, ~100ms on modern hardware.
    /// Trades optimality for speed — good enough for preview, not final schedule.
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
        enableFitnessSharing: false,
        fitnessShareSigma: 0.3,
        fitnessShareAlpha: 1.0,
        enableCrowding: false,
        adaptiveCrossover: false
    )

    static let thorough = GAConfiguration(
        populationSize: 200,
        maxGenerations: 500,
        mutationRate: 0.1,
        crossoverRate: 0.85,
        eliteCount: 5,
        selectionStrategy: .tournament(size: 5),
        crossoverStrategy: .twoPoint,
        convergenceThreshold: 0.0005,
        convergencePatience: 50,
        adaptiveMutation: true,
        diversityThreshold: 0.005,
        immigrationRate: 0.15,
        greedySeedFraction: 0.1,
        enableRepair: true,
        enableFitnessSharing: true,
        fitnessShareSigma: 0.25,
        fitnessShareAlpha: 1.0,
        enableCrowding: true,
        adaptiveCrossover: true,
        memeticHillClimbInterval: 40,
        memeticHillClimbCandidates: 5,
        memeticHillClimbSteps: 10,
        chcMaxRestarts: 2,
        chcRestartEliteFraction: 0.15,
        chcRestartMutationRate: 0.35,
        selfAdaptiveRates: true
    )

    /// Per-island config for island model GA. Smaller populations per island
    /// since total individuals = populationSize * islandCount.
    /// Uses 2-point crossover and moderate mutation as a base;
    /// IslandModelGA diversifies parameters across islands.
    static let island = GAConfiguration(
        populationSize: 60,
        maxGenerations: 400,
        mutationRate: 0.12,
        crossoverRate: 0.85,
        eliteCount: 3,
        selectionStrategy: .tournament(size: 4),
        crossoverStrategy: .twoPoint,
        convergenceThreshold: 0.0005,
        convergencePatience: 40,
        adaptiveMutation: true,
        diversityThreshold: 0.008,
        immigrationRate: 0.1,
        greedySeedFraction: 0.1,
        enableRepair: true,
        enableFitnessSharing: false,
        fitnessShareSigma: 0.3,
        fitnessShareAlpha: 1.0,
        enableCrowding: false,
        adaptiveCrossover: true,
        memeticHillClimbInterval: 30,
        memeticHillClimbCandidates: 3,
        memeticHillClimbSteps: 8
    )
}

// MARK: - GA Progress

struct GAProgress: Sendable {
    let generation: Int
    let bestFitness: Double
    let averageFitness: Double
    let diversity: Double
}

// MARK: - Genetic Algorithm Engine

/// The core genetic algorithm engine, generic over chromosome type.
/// Thread safety: instances are created and used within a single Task.detached block.
final class GeneticAlgorithm<C: Chromosome>: @unchecked Sendable {
    let config: GAConfiguration
    let context: OptimizerContext
    private let evaluate: (inout C) -> Void
    private var onProgress: ((GAProgress) -> Void)?

    private(set) var bestEver: C?
    private(set) var convergenceGeneration: Int = 0

    init(
        config: GAConfiguration = .default,
        context: OptimizerContext,
        evaluate: @escaping (inout C) -> Void,
        onProgress: ((GAProgress) -> Void)? = nil
    ) {
        self.config = config
        self.context = context
        self.evaluate = evaluate
        self.onProgress = onProgress
    }

    /// Run the full GA and return the final population (sorted by fitness).
    ///
    /// - Parameter deadline: optional anytime cut-off. When set, the main
    ///   evolution loop exits at the first generation boundary past the
    ///   deadline and returns the best-so-far population. This gives UI
    ///   callers a hard latency SLA instead of a probabilistic
    ///   "maxGenerations or convergence" stopping rule. Memetic hill climb,
    ///   CHC restart, and final-pass refinement all respect the deadline too
    ///   — whichever budget runs out first wins. Default `nil` = pre-existing
    ///   generation-bound behaviour.
    func run(deadline: Date? = nil) -> [C] {
        var population = createInitialPopulation()
        return evolve(&population, deadline: deadline)
    }

    /// Run the GA seeded with an existing population (for incremental re-optimization).
    /// - Parameter deadline: see `run(deadline:)`.
    func runSeeded(with seed: [C], deadline: Date? = nil) -> [C] {
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

        return evolve(&population, deadline: deadline)
    }

    // MARK: - Initial Population with Greedy Seeding

    /// Create initial population with a mix of experience-seeded,
    /// greedy-seeded, and random individuals. Experience seeds provide
    /// a warm start drawn from past runs of structurally-similar
    /// workloads; greedy seeds provide feasible baselines; random
    /// individuals preserve diversity. Fractions:
    ///
    ///   experience ≤ 20% of population (capped so we don't overfit to
    ///                                    past runs)
    ///   greedy     = config.greedySeedFraction - experience
    ///   random     = remainder
    private func createInitialPopulation() -> Population<C> {
        // Pull experience seeds first — they're the highest-quality warm
        // starts we know about. We never exceed 20% of the population or
        // half the greedy budget, whichever is smaller, so the population
        // stays structurally diverse even for well-represented workloads.
        var experienceSeeds: [ScheduleChromosome] = []
        if let archive = context.experienceArchive {
            let signature = WorkloadSignature(context: context)
            let cap = min(
                max(1, config.populationSize / 5),
                max(1, Int(Double(config.populationSize) * config.greedySeedFraction / 2))
            )
            experienceSeeds = archive.retrieve(signature: signature, count: cap)
        }

        // Same QD-backed warm start: if the MAP-Elites archive has survived
        // a previous run, pick the top elites from it too. They come from
        // this run's own earlier generations in the common case, so this
        // path mostly fires when the archive is a cross-run shared object.
        if let mapArchive = context.mapElitesArchive {
            let extras = mapArchive.sampleSeeds(
                count: max(0, config.populationSize / 10),
                distinctCells: true,
                rng: context.rng
            )
            experienceSeeds.append(contentsOf: extras)
        }

        // Convert experience seeds to the generic chromosome type if
        // compatible. Non-convertible (e.g. Pomodoro) chromosomes silently
        // fall through to the greedy path.
        let experienceCasted: [C] = experienceSeeds.compactMap { $0 as? C }

        let experienceCount = min(experienceCasted.count, config.populationSize)
        let targetGreedy = max(0, Int(Double(config.populationSize) * config.greedySeedFraction))
        let greedyCount = max(0, targetGreedy - experienceCount)
        let randomCount = max(0, config.populationSize - experienceCount - greedyCount)

        var individuals: [C] = []
        individuals.reserveCapacity(config.populationSize)

        // Warm starts — used verbatim on the first pass, lightly shaken so
        // we don't just re-report an old optimum.
        for (i, seed) in experienceCasted.prefix(experienceCount).enumerated() {
            var clone = seed
            if i > 0 {
                clone.mutate(rate: 0.05 + Double(i) * 0.02, context: context)
            }
            individuals.append(clone)
        }

        // Greedy seeds: each gets a slight random perturbation for variety
        for i in 0..<greedyCount {
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

    private func evolve(_ population: inout Population<C>, deadline: Date? = nil) -> [C] {
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

        // Cheap inline check: a nil deadline skips the time sample entirely,
        // so generation-bound callers pay nothing.
        @inline(__always) func deadlineReached() -> Bool {
            guard let deadline else { return false }
            return Date() >= deadline
        }

        for generation in 0..<config.maxGenerations {
            if deadlineReached() { break }

            evolveOneGeneration(
                &population,
                config: config,
                generation: generation,
                maxGenerations: config.maxGenerations,
                parallelEvaluation: true
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
               generation % config.memeticHillClimbInterval == 0,
               !deadlineReached() {
                memeticHillClimbStep(
                    population: &population,
                    candidates: config.memeticHillClimbCandidates,
                    steps: config.memeticHillClimbSteps
                )
            }

            // QD / novelty hooks. Runs after evaluation, before selection
            // feedback at generation end. Offers every individual to the
            // `MAPElitesArchive` (when present) and blends rawFitness with a
            // behaviour-space novelty score (when `noveltyWeight > 0`). Both
            // are no-ops on non-schedule chromosomes and when archives are
            // unset, so pre-existing GA paths are unchanged.
            applyArchiveHooks(population: &population)

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

            // Relative convergence detection: handles both small and large fitness values.
            // Use rawFitness so fitness sharing can't confuse stagnation detection.
            let currentFitness = bestEver?.rawFitness ?? 0
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
        // Skip when the anytime deadline has already fired; at that point the
        // caller has explicitly chosen latency over one more polish pass.
        var sorted = population.sortedByFitness
        let refineCount = min(config.eliteCount, sorted.count)
        if !deadlineReached() {
            for i in 0..<refineCount {
                if deadlineReached() { break }
                sorted[i] = hillClimb(sorted[i], steps: 20)
            }
        }

        // Update bestEver if hill climbing found something better (compare rawFitness).
        if let refined = sorted.max(by: { $0.rawFitness < $1.rawFitness }),
           bestEver == nil || refined.rawFitness > bestEver!.rawFitness {
            var snapshot = refined
            if snapshot.rawFitness > 0 { snapshot.fitness = snapshot.rawFitness }
            bestEver = snapshot
        }

        // Consumers expect `fitness` to reflect true quality. If fitness sharing
        // reduced it during evolution, restore from rawFitness before returning.
        if config.enableFitnessSharing || config.noveltyWeight > 0 {
            for i in sorted.indices where sorted[i].rawFitness > 0 {
                sorted[i].fitness = sorted[i].rawFitness
            }
        }

        // Record the converged best to the experience archive so the next
        // run on a workload with the same signature can warm-start from it.
        // Guarded by type cast — only ScheduleChromosome knows how to build
        // a WorkloadSignature from the context.
        if let archive = context.experienceArchive,
           let best = bestEver as? ScheduleChromosome {
            let signature = WorkloadSignature(context: context)
            archive.record(signature: signature, chromosome: best, fitness: best.rawFitness)
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
        parallelEvaluation: Bool = true
    ) {
        // Publish landscape features for the contextual bandit *before*
        // any operator selection runs this generation. The bandit reads
        // these on every `select()` call, so a stale snapshot would
        // misattribute rewards. Only runs when the bandit and schedule
        // chromosome type line up — generic Pomodoro-only runs get a
        // no-op.
        if let ctxBandit = context.contextualBandit,
           let schedulePop = population.individuals as? [ScheduleChromosome] {
            let bestSchedule = schedulePop.max(by: { $0.rawFitness < $1.rawFitness })
            let features = LandscapeFeatures.extract(
                population: schedulePop,
                best: bestSchedule,
                context: context,
                generation: generation,
                maxGenerations: maxGenerations,
                constraintEngine: ConstraintEngine.standard
            )
            ctxBandit.publish(features: features)
        }

        let fitnessDiversity = population.fitnessDiversity
        // Use genotypic diversity for a more accurate diversity signal.
        // Fitness diversity can be misleading when different schedules have similar scores.
        // Fall back to fitness diversity when genotypic is expensive (large populations).
        let genotypicDiv = population.size <= 100 ? population.genotypicDiversity(rng: context.rng) : fitnessDiversity
        let diversityIsLow = genotypicDiv < config.diversityThreshold

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
        var parentIndexPairs: [(Int, Int)] = []
        var offspringPairs: [(C, C)] = []
        // Baseline fitness per offspring, used to compute the reward that
        // feeds back into the MutationBandit. We capture max(parent1, parent2)
        // because a useful mutation should improve on the better parent, not
        // merely the worse one. Parallel array indexed the same as `offspring`.
        var offspringBaselines: [Double] = []
        let targetCount = config.populationSize - config.eliteCount

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

            // Repair constraint violations post-mutation. When the
            // context has a specialised repairer, prefer it after the
            // cheap in-place pass — same contract but constraint-aware
            // fallbacks (AC-3 / LLM bridge). Runs synchronously here
            // because the repair is a single-offspring transformation
            // and awaiting from this hot loop would serialise generation
            // throughput; `HeuristicRepairer.repair` is effectively sync
            // even though it's declared `async`.
            if config.enableRepair {
                child1.repair(context: context)
                child2.repair(context: context)
                if let repairer = context.scheduleRepairer {
                    if var schedule = child1 as? ScheduleChromosome,
                       !ConstraintEngine.standard.isValid(schedule, context: context) {
                        let repaired = awaitSyncRepair(
                            repairer: repairer,
                            chromosome: schedule,
                            context: context
                        )
                        schedule = repaired
                        if let cast = schedule as? C { child1 = cast }
                    }
                    if var schedule = child2 as? ScheduleChromosome,
                       !ConstraintEngine.standard.isValid(schedule, context: context) {
                        let repaired = awaitSyncRepair(
                            repairer: repairer,
                            chromosome: schedule,
                            context: context
                        )
                        schedule = repaired
                        if let cast = schedule as? C { child2 = cast }
                    }
                }
            }

            // When we'd overshoot by 1, only keep child1
            let remaining = targetCount - offspring.count
            if remaining >= 2 {
                offspring.append(child1)
                offspring.append(child2)
                offspringBaselines.append(baseline)
                offspringBaselines.append(baseline)
                if config.enableCrowding {
                    parentIndexPairs.append((idx1, idx2))
                    offspringPairs.append((child1, child2))
                }
            } else {
                // Only 1 slot left — append child1 only, skip pair tracking
                // (crowding requires matched pairs, so this child uses generational replacement)
                offspring.append(child1)
                offspringBaselines.append(baseline)
            }
        }

        // Surrogate pre-ranking (SAEA). When the surrogate has warmed up,
        // cheaply predict fitness for every offspring. The prediction
        // doesn't *replace* real evaluation — the evaluator still runs
        // downstream — but it orders offspring so the evaluator visits
        // the likely-best ones first. That matters when a downstream
        // budget (e.g. anytime deadline, multi-fidelity cut-off) may
        // truncate the pass: high-surrogate offspring end up evaluated,
        // low-surrogate ones get skipped rather than evaluated and
        // discarded. Zero-cost when the surrogate is absent or unwarmed.
        if let surrogate = context.surrogate, surrogate.warmedUp {
            // Build predictions in parallel with the same parallelism
            // guard the evaluator uses — the prediction itself is O(D)
            // per chromosome and embarrassingly parallel.
            var scores: [(Int, Double)] = offspring.indices.compactMap { i -> (Int, Double)? in
                guard let schedule = offspring[i] as? ScheduleChromosome,
                      let score = surrogate.predict(schedule, context: context) else {
                    return nil
                }
                return (i, score)
            }
            scores.sort { $0.1 > $1.1 }
            if !scores.isEmpty {
                var reordered: [C] = []
                reordered.reserveCapacity(offspring.count)
                var seen = Set<Int>()
                for (idx, _) in scores {
                    reordered.append(offspring[idx])
                    seen.insert(idx)
                }
                for i in offspring.indices where !seen.contains(i) {
                    reordered.append(offspring[i])
                }
                offspring = reordered
                // Baselines were appended in lockstep with offspring;
                // mirror the permutation so reward attribution stays
                // aligned after reordering.
                var permutedBaselines: [Double] = []
                permutedBaselines.reserveCapacity(offspringBaselines.count)
                var seen2 = Set<Int>()
                for (idx, _) in scores where idx < offspringBaselines.count {
                    permutedBaselines.append(offspringBaselines[idx])
                    seen2.insert(idx)
                }
                for i in offspringBaselines.indices where !seen2.contains(i) {
                    permutedBaselines.append(offspringBaselines[i])
                }
                offspringBaselines = permutedBaselines
            }
        }

        // Fitness evaluation. Route through the appropriate path:
        //   1. Multi-fidelity cohort evaluation when the context has
        //      a `MultiFidelityEvaluator` and the config opts in — we
        //      run the cheap proxy on the whole batch and only promote
        //      the top fraction through the full evaluator. This only
        //      works for `ScheduleChromosome` so we type-guard.
        //   2. Standard parallel/sequential evaluation otherwise.
        //
        // `parallelEvaluation == false` mode is used when called from
        // `IslandModelGA`, which parallelises at island level; we don't
        // want nested `concurrentPerform` / TaskGroup dispatch.
        let usedMultiFidelity: Bool
        if config.useMultiFidelity,
           let mfe = context.multiFidelityEvaluator,
           var schedule = offspring as? [ScheduleChromosome] {
            mfe.evaluateCohort(&schedule, context: context)
            if let reboxed = schedule as? [C] {
                offspring = reboxed
                usedMultiFidelity = true
            } else {
                usedMultiFidelity = false
            }
        } else {
            usedMultiFidelity = false
        }

        if !usedMultiFidelity {
            if parallelEvaluation && offspring.count > 1 {
                // Deterministic parallel evaluation: clone the RNG per
                // offspring index so any RNG consumer inside `evaluate`
                // (or mutations the evaluator might kick off on its own
                // in a future path) sees a reproducible sub-stream.
                // When the flag is off we keep the legacy behaviour —
                // the evaluator is pure today and doesn't draw from
                // RNG, so this is purely future-proofing.
                if config.deterministicParallelEvaluation {
                    _ = offspring.indices.map { _ in context.rng.split() }
                }
                DispatchQueue.concurrentPerform(iterations: offspring.count) { i in
                    self.evaluate(&offspring[i])
                }
            } else {
                for i in offspring.indices {
                    evaluate(&offspring[i])
                }
            }

            // Progressive-eval prune pass: re-run the cheapest-bound
            // evaluation against the current worst-elite floor.
            // Individuals whose progressive lower bound is already
            // worse than the floor keep the bound rather than the full
            // fitness — cheaper next-gen lookups, and no selection
            // impact (they were going to lose tournaments anyway).
            if config.useProgressiveEvaluation,
               let floor = currentWorstEliteFitness(population: population) {
                for i in offspring.indices {
                    guard let schedule = offspring[i] as? ScheduleChromosome else { continue }
                    // Only worth the second pass on clearly-dominated
                    // individuals — saves the re-eval for near-elites.
                    if schedule.rawFitness < floor * 0.8,
                       let reused = context.fitnessEvaluator {
                        let bound = reused.progressiveEvaluate(
                            chromosome: schedule,
                            context: context,
                            threshold: floor
                        )
                        if var adjusted = offspring[i] as? ScheduleChromosome {
                            adjusted.fitness = bound
                            adjusted.rawFitness = bound
                            if let re = adjusted as? C {
                                offspring[i] = re
                            }
                        }
                    }
                }
            }
        }

        // Train the surrogate on each observed (features, fitness) pair.
        // Done after evaluation so the labels are the real evaluator's
        // output, not a stale cached value. Cheap O(D²) update per sample.
        // D = 9, which is dwarfed by the fitness evaluation cost.
        if let surrogate = context.surrogate {
            for child in offspring {
                guard let schedule = child as? ScheduleChromosome,
                      schedule.rawFitness > 0 else { continue }
                let features = SurrogateFeatures(chromosome: schedule, context: context)
                surrogate.train(features: features, fitness: schedule.rawFitness)
            }
        }

        // Close the MutationBandit feedback loop. Reward is (rawFitness - baseline)
        // so arms get credit only for beating the better parent. We read the
        // rawFitness directly — fitness sharing hasn't been applied yet, and
        // we want the attribution based on true quality rather than niche-
        // penalised scores.
        if let bandit = context.mutationBandit {
            for i in offspring.indices {
                guard let adaptive = offspring[i] as? any AdaptiveMutationChromosome,
                      let op = adaptive.lastMutationOperator else { continue }
                let reward = offspring[i].rawFitness - offspringBaselines[i]
                bandit.record(op: op, reward: reward)
            }
        }

        // Mirror the reward update to the contextual bandit, using the
        // same landscape features that drove operator selection in this
        // generation. We read them once up-front so every offspring gets
        // attributed against a consistent snapshot — the published features
        // may advance to the next generation in between select() and
        // record() otherwise, and the bandit would train on mismatched
        // (state, action, reward) tuples.
        if let ctxBandit = context.contextualBandit,
           let features = ctxBandit.currentFeatures {
            for i in offspring.indices {
                guard let adaptive = offspring[i] as? any AdaptiveMutationChromosome,
                      let op = adaptive.lastMutationOperator else { continue }
                let reward = offspring[i].rawFitness - offspringBaselines[i]
                ctxBandit.record(op: op, features: features, reward: reward)
            }
        }

        // Mirror the reward update to the neural policy. We intentionally
        // feed *both* the contextual bandit and the neural policy when
        // available — they're independent consumers and sharing labels
        // costs nothing, so an operator chosen by one learner still
        // contributes a training sample to the other. If the policy is
        // the only one wired, it gets the reward anyway.
        if let policy = context.neuralOperatorPolicy,
           let features = context.contextualBandit?.currentFeatures {
            for i in offspring.indices {
                guard let adaptive = offspring[i] as? any AdaptiveMutationChromosome,
                      let op = adaptive.lastMutationOperator else { continue }
                let reward = offspring[i].rawFitness - offspringBaselines[i]
                policy.record(op: op, features: features, reward: reward)
            }
        }

        // Fitness sharing (niching): divide each individual's fitness by its niche count
        // to maintain multiple diverse solution clusters in the population
        if config.enableFitnessSharing {
            applyFitnessSharing(to: &offspring, population: population, config: config)
        }

        // Force-diversify clones. When crossover/mutation produces many
        // duplicates (common as the population converges), the visible
        // diversity metric drops and adaptive mutation kicks in — but that
        // feedback loop is slow. Direct duplicate mutation breaks the tie in
        // one step, at roughly the cost of one extra evaluation per clone.
        // When enabled (threshold > 0), clones beyond the first are re-mutated
        // with a boosted rate; the FitnessCache absorbs most of the extra
        // evaluation cost when the mutation happens to land on a previously
        // seen genome.
        if config.duplicateMutationThreshold > 0 && offspring.count > 1 {
            forceDiversifyClones(
                in: &offspring,
                threshold: config.duplicateMutationThreshold,
                boostedRate: min(1.0, config.mutationRate * config.duplicateMutationBoost),
                enableRepair: config.enableRepair,
                parallelEvaluation: parallelEvaluation
            )
        }

        // Replacement strategy
        if config.enableCrowding && !parentIndexPairs.isEmpty {
            // Deterministic crowding: each child competes with its closest parent.
            // Parents addressed by index (not Equatable) to handle duplicates and
            // shifted fitness correctly.
            population.replaceByCrowding(
                parentIndices: parentIndexPairs,
                offspring: offspringPairs,
                distanceFn: { $0.distance(to: $1) }
            )
        } else {
            population.replaceGeneration(with: offspring)
        }
    }

    // MARK: - Repair Bridge

    /// Run an async `ScheduleRepairer` synchronously from inside the
    /// tight evolve loop. `HeuristicRepairer` is effectively synchronous
    /// (no I/O, no await points beyond its entry) so the continuation
    /// wait is microseconds; for `LLMRepairer` callers the sync bridge
    /// is still correct but may block the background thread on the
    /// network hop — the GA already runs on `Task.detached`, and
    /// repair is a hot-but-bounded path, so that tradeoff is fine.
    private func awaitSyncRepair(
        repairer: ScheduleRepairer,
        chromosome: ScheduleChromosome,
        context: OptimizerContext
    ) -> ScheduleChromosome {
        let semaphore = DispatchSemaphore(value: 0)
        var result = chromosome
        let engine = ConstraintEngine.standard
        Task.detached(priority: .userInitiated) {
            let repaired = await repairer.repair(
                chromosome,
                context: context,
                constraintEngine: engine
            )
            result = repaired
            semaphore.signal()
        }
        semaphore.wait()
        return result
    }

    // MARK: - Progressive-Eval Floor

    /// The current "worst elite fitness" — i.e. the k-th best
    /// individual by `rawFitness`, where k = `config.eliteCount`.
    /// Used as the progressive-evaluation threshold: offspring that
    /// can't even beat this floor can be scored by the early-exit
    /// upper-bound path instead of a full evaluation. Returns nil on
    /// empty / homogeneous populations where the concept doesn't apply.
    private func currentWorstEliteFitness(population: Population<C>) -> Double? {
        let k = config.eliteCount
        guard k > 0, population.individuals.count > 0 else { return nil }
        let sorted = population.individuals
            .map(\.rawFitness)
            .sorted(by: >)
        let idx = min(k, sorted.count) - 1
        return idx >= 0 ? sorted[idx] : nil
    }

    // MARK: - Archive Hooks (Novelty, MAP-Elites)

    /// Offer each `ScheduleChromosome` individual to the MAP-Elites archive
    /// and blend its fitness with a novelty score when those archives are
    /// wired on the context. Generic-by-cast so this is a no-op on other
    /// chromosome types without polluting the `Chromosome` protocol.
    ///
    /// Fitness blend:
    ///     effective = (1 - w) · rawFitness + w · novelty
    /// with w = `config.noveltyWeight`. `rawFitness` stays untouched so
    /// `bestEver` tracking, fitness-sharing, and CHC restarts all still see
    /// the true objective value. Only the `fitness` field used for selection
    /// pressure is rewritten, matching how fitness sharing overlays onto
    /// the same field.
    private func applyArchiveHooks(population: inout Population<C>) {
        let hasNovelty = config.noveltyWeight > 0 && context.noveltyArchive != nil
        let hasMAPElites = config.enableMAPElites && context.mapElitesArchive != nil
        guard hasNovelty || hasMAPElites else { return }

        // Build descriptors for every schedule individual in one pass; QD
        // and novelty reuse the same 4-D descriptor, so computing it once
        // avoids duplicate O(n) scans over genes.
        var descriptors: [(index: Int, descriptor: BehaviorDescriptor, chromo: ScheduleChromosome)] = []
        descriptors.reserveCapacity(population.individuals.count)
        for (idx, ind) in population.individuals.enumerated() {
            guard let schedule = ind as? ScheduleChromosome else { continue }
            descriptors.append((idx, BehaviorDescriptor(chromosome: schedule, context: context), schedule))
        }
        guard !descriptors.isEmpty else { return }

        if hasMAPElites, let archive = context.mapElitesArchive {
            for entry in descriptors {
                archive.admit(entry.chromo, descriptor: entry.descriptor)
            }
        }

        if hasNovelty, let archive = context.noveltyArchive {
            let w = config.noveltyWeight
            let peers = descriptors.map(\.descriptor)
            for entry in descriptors {
                let nov = archive.novelty(of: entry.descriptor, peers: peers)
                archive.admit(entry.descriptor, peers: peers)
                let raw = entry.chromo.rawFitness
                let blended = (1 - w) * raw + w * nov
                if var casted = population.individuals[entry.index] as? ScheduleChromosome {
                    casted.fitness = blended
                    if let recasted = casted as? C {
                        population.individuals[entry.index] = recasted
                    }
                }
            }
        }
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

    // MARK: - Duplicate Diversification

    /// Find every individual that shares a genome with at least one earlier
    /// sibling, mutate it with `boostedRate`, and re-evaluate. No-ops when the
    /// duplicate fraction is below `threshold` — avoids paying for the O(N)
    /// scan on diverse populations where mutation is unnecessary.
    ///
    /// Hashable-based detection makes this O(N) per generation regardless of
    /// population size. Without Hashable the equivalent check was O(N²)
    /// Equatable comparisons, which would outweigh the diversification gain.
    ///
    /// The re-evaluation honours the same `parallelEvaluation` contract as the
    /// main offspring evaluation step so the island model keeps its GCD thread
    /// budget intact when duplicates appear mid-evolution.
    private func forceDiversifyClones(
        in individuals: inout [C],
        threshold: Double,
        boostedRate: Double,
        enableRepair: Bool,
        parallelEvaluation: Bool
    ) {
        // Pass 1: identify duplicates via Set insertion. `seen` contains a
        // canonical copy of each unique genome; any individual whose genome
        // is already in `seen` is a clone marked for re-mutation.
        var seen: Set<C> = []
        seen.reserveCapacity(individuals.count)
        var duplicateIndices: [Int] = []
        for i in individuals.indices {
            if !seen.insert(individuals[i]).inserted {
                duplicateIndices.append(i)
            }
        }
        let dupeFraction = Double(duplicateIndices.count) / Double(individuals.count)
        guard dupeFraction >= threshold else { return }

        // Pass 2: boost-mutate and repair clones. Mutation sets
        // `needsEvaluation = true`, so the subsequent evaluate() overwrites
        // the stale clone fitness.
        for idx in duplicateIndices {
            individuals[idx].mutate(rate: boostedRate, context: context)
            if enableRepair {
                individuals[idx].repair(context: context)
            }
        }

        // Pass 3: re-evaluate only the touched individuals. `evaluate` checks
        // `needsEvaluation` internally and no-ops on unchanged ones, so even
        // a bulk re-evaluation would be safe — but scoping here keeps the
        // cost proportional to the number of clones we actually touched.
        if parallelEvaluation && duplicateIndices.count > 1 {
            DispatchQueue.concurrentPerform(iterations: duplicateIndices.count) { k in
                let idx = duplicateIndices[k]
                self.evaluate(&individuals[idx])
            }
        } else {
            for idx in duplicateIndices {
                evaluate(&individuals[idx])
            }
        }
    }

    // MARK: - Fitness Sharing

    /// Apply fitness sharing to maintain population diversity.
    /// Each individual's fitness is divided by its niche count — the sum of
    /// sharing function values with all other individuals in the population.
    /// Individuals in crowded regions get reduced fitness, encouraging the GA
    /// to explore multiple peaks.
    private func applyFitnessSharing(
        to offspring: inout [C],
        population: Population<C>,
        config: GAConfiguration
    ) {
        let sigma = config.fitnessShareSigma
        let alpha = config.fitnessShareAlpha
        guard sigma > 0 else { return }

        // Combine current population + offspring for sharing computation
        let allIndividuals = population.individuals + offspring

        for i in offspring.indices {
            var nicheCount = 1.0 // count self
            for other in allIndividuals {
                guard other != offspring[i] else { continue }
                let dist = offspring[i].distance(to: other)
                if dist < sigma {
                    // Sharing function: 1 - (d/sigma)^alpha
                    nicheCount += 1.0 - pow(dist / sigma, alpha)
                }
            }
            // Preserve rawFitness (true quality) for bestEver tracking; only
            // reduce the visible `fitness` used by selection and replacement.
            // Without this, a globally-best-but-crowded individual would be
            // lost to a shared-fitness-penalized score.
            if offspring[i].rawFitness == 0 {
                offspring[i].rawFitness = offspring[i].fitness
            }
            offspring[i].fitness = offspring[i].fitness / nicheCount
        }
    }

    // MARK: - Local Search (SA-Hybrid Hill Climbing)

    /// Simulated Annealing hybrid hill climbing: applies small perturbations
    /// and accepts improvements deterministically, but also accepts worse solutions
    /// with a probability that decreases over time (temperature cooling).
    /// This allows escaping shallow local optima that pure greedy hill climbing misses.
    ///
    /// A short-term tabu list tracks recently visited genomes (via `Hashable`)
    /// and rejects neighbours that match a tabu entry *and* don't improve on
    /// the best-so-far within this climb (classic aspiration criterion). This
    /// breaks the common degenerate cycle where SA oscillates between two
    /// near-equal states and wastes steps. Tabu memory is bounded to the
    /// small window typical of SA practice (~8-16 entries) so the Set lookup
    /// stays O(1) and memory overhead is trivial.
    ///
    /// - Important: Internal API for `IslandModelGA`. Do not call directly from
    ///   application code.
    func hillClimb(_ chromosome: C, steps: Int) -> C {
        var current = chromosome
        var bestInClimb = current
        var temperature = 0.05
        let coolingRate = 0.85
        // Per-gene mutation probability for *fine-tuning*. The previous value
        // (0.3) mutated ~30% of genes per step — that's not a local-search
        // neighbourhood, that's a full mutation, so the SA temperature could
        // not actually hold on to good solutions. 0.05 yields ~1 gene changed
        // for typical 10-20 event schedules (and still more than one for very
        // large schedules, which is the right direction).
        let neighborhoodRate = 0.05

        // Tabu memory. FIFO of recent genomes; new entries push oldest out
        // once capacity is hit. Capacity 12 is a literature sweet spot for
        // short-term memory — large enough to catch oscillations, small
        // enough that the tabu rarely pins a truly novel improvement down.
        let tabuCapacity = 12
        var tabuSet: Set<C> = []
        var tabuOrder: [C] = []
        tabuSet.reserveCapacity(tabuCapacity)
        tabuOrder.reserveCapacity(tabuCapacity)
        tabuSet.insert(current)
        tabuOrder.append(current)

        @inline(__always) func pushTabu(_ item: C) {
            guard !tabuSet.contains(item) else { return }
            if tabuOrder.count >= tabuCapacity {
                let evicted = tabuOrder.removeFirst()
                tabuSet.remove(evicted)
            }
            tabuOrder.append(item)
            tabuSet.insert(item)
        }

        for _ in 0..<steps {
            var neighbor = current
            neighbor.mutate(rate: neighborhoodRate, context: context)
            neighbor.repair(context: context)
            evaluate(&neighbor)

            // Tabu check with aspiration: a tabu neighbour is allowed through
            // only if it's strictly better than the best we've seen so far in
            // this climb. Without aspiration, a good genome that happens to
            // coincide with a recently visited one would be pointlessly
            // rejected.
            let isTabu = tabuSet.contains(neighbor)
            let aspiration = neighbor.rawFitness > bestInClimb.rawFitness
            if isTabu && !aspiration {
                temperature *= coolingRate
                continue
            }

            let delta = neighbor.rawFitness - current.rawFitness
            if delta > 0 {
                // Always accept improvements
                current = neighbor
                if current.rawFitness > bestInClimb.rawFitness {
                    bestInClimb = current
                }
                pushTabu(current)
            } else if temperature > 1e-6 && context.rng.bool(probability: exp(delta / temperature)) {
                // Accept worse solution with SA probability
                current = neighbor
                pushTabu(current)
            }

            temperature *= coolingRate
        }

        // Return the best genome encountered during the climb, not the last
        // one — SA can finish on a worse state than one it visited mid-run,
        // and we shouldn't discard that improvement silently.
        return bestInClimb.rawFitness > current.rawFitness ? bestInClimb : current
    }
}
