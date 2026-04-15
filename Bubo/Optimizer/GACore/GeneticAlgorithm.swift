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
        memeticHillClimbSteps: Int = 5
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
        memeticHillClimbSteps: 6
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
        memeticHillClimbSteps: 10
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
    func run() -> [C] {
        var population = createInitialPopulation()
        return evolve(&population)
    }

    /// Run the GA seeded with an existing population (for incremental re-optimization).
    func runSeeded(with seed: [C]) -> [C] {
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

        return evolve(&population)
    }

    // MARK: - Initial Population with Greedy Seeding

    /// Create initial population with a mix of greedy-seeded and random individuals.
    /// Greedy seeds provide feasible starting points; random individuals maintain diversity.
    private func createInitialPopulation() -> Population<C> {
        let greedyCount = max(0, Int(Double(config.populationSize) * config.greedySeedFraction))
        let randomCount = config.populationSize - greedyCount

        var individuals: [C] = []

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

        return Population<C>(individuals: individuals, eliteCount: config.eliteCount)
    }

    // MARK: - Core Evolution Loop

    private func evolve(_ population: inout Population<C>) -> [C] {
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

        for generation in 0..<config.maxGenerations {
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
               generation % config.memeticHillClimbInterval == 0 {
                memeticHillClimbStep(
                    population: &population,
                    candidates: config.memeticHillClimbCandidates,
                    steps: config.memeticHillClimbSteps
                )
            }

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
                convergenceGeneration = generation - config.convergencePatience
                break
            }
        }

        // Local search: refine top individuals with SA-hybrid hill climbing
        var sorted = population.sortedByFitness
        let refineCount = min(config.eliteCount, sorted.count)
        for i in 0..<refineCount {
            sorted[i] = hillClimb(sorted[i], steps: 20)
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
        if config.enableFitnessSharing {
            for i in sorted.indices where sorted[i].rawFitness > 0 {
                sorted[i].fitness = sorted[i].rawFitness
            }
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
        let targetCount = config.populationSize - config.eliteCount

        while offspring.count < targetCount {
            let (idx1, idx2) = Selection.selectPairIndices(
                from: population,
                strategy: config.selectionStrategy,
                rng: context.rng
            )
            let parent1 = population.individuals[idx1]
            let parent2 = population.individuals[idx2]

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
                if config.enableCrowding {
                    parentIndexPairs.append((idx1, idx2))
                    offspringPairs.append((child1, child2))
                }
            } else {
                // Only 1 slot left — append child1 only, skip pair tracking
                // (crowding requires matched pairs, so this child uses generational replacement)
                offspring.append(child1)
            }
        }

        // Fitness evaluation: parallel when running standalone,
        // sequential when called from IslandModelGA (which parallelizes at island level).
        if parallelEvaluation && offspring.count > 1 {
            DispatchQueue.concurrentPerform(iterations: offspring.count) { i in
                self.evaluate(&offspring[i])
            }
        } else {
            for i in offspring.indices {
                evaluate(&offspring[i])
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
