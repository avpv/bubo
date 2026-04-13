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
        adaptiveCrossover: Bool = false
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
        adaptiveCrossover: true
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
        adaptiveCrossover: true
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
        adaptiveCrossover: true
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
        bestEver = population.best

        var staleGenerations = 0
        var lastBestFitness = bestEver?.fitness ?? 0

        for generation in 0..<config.maxGenerations {
            evolveOneGeneration(
                &population,
                config: config,
                generation: generation,
                maxGenerations: config.maxGenerations,
                parallelEvaluation: true
            )

            if let currentBest = population.best {
                if bestEver == nil || currentBest.fitness > bestEver!.fitness {
                    bestEver = currentBest
                }
            }

            let fitnessDiversity = population.fitnessDiversity
            onProgress?(GAProgress(
                generation: generation,
                bestFitness: bestEver?.fitness ?? 0,
                averageFitness: population.averageFitness,
                diversity: fitnessDiversity
            ))

            // Relative convergence detection: handles both small and large fitness values
            let currentFitness = bestEver?.fitness ?? 0
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

        // Update bestEver if hill climbing found something better
        if let refined = sorted.first, (bestEver == nil || refined.fitness > bestEver!.fitness) {
            bestEver = refined
        }

        return sorted.sorted { $0.fitness > $1.fitness }
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
        let diversityIsLow = fitnessDiversity < config.diversityThreshold

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
        var parentPairs: [(C, C)] = []
        var offspringPairs: [(C, C)] = []
        let targetCount = config.populationSize - config.eliteCount

        while offspring.count < targetCount {
            let (parent1, parent2) = Selection.selectPair(
                from: population,
                strategy: config.selectionStrategy
            )

            var child1: C
            var child2: C

            if Double.random(in: 0...1) < effectiveCrossoverRate {
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

            offspring.append(child1)
            offspring.append(child2)

            // Track pairs for crowding replacement
            if config.enableCrowding {
                parentPairs.append((parent1, parent2))
                offspringPairs.append((child1, child2))
            }
        }

        // Trim excess offspring (loop appends 2 at a time, may overshoot by 1)
        if offspring.count > targetCount {
            offspring.removeLast(offspring.count - targetCount)
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

        // Replacement strategy
        if config.enableCrowding && !parentPairs.isEmpty {
            // Deterministic crowding: each child competes with its closest parent
            // Re-pair offspring since we may have trimmed
            let validPairCount = min(parentPairs.count, offspringPairs.count)
            let trimmedParentPairs = Array(parentPairs.prefix(validPairCount))
            let trimmedOffspringPairs = Array(offspringPairs.prefix(validPairCount))

            population.replaceByCrowding(
                parents: trimmedParentPairs,
                offspring: trimmedOffspringPairs,
                distanceFn: { $0.distance(to: $1) }
            )
        } else {
            population.replaceGeneration(with: offspring)
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
            // Divide raw fitness by niche count to penalize crowded niches
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

        for _ in 0..<steps {
            var neighbor = current
            // Small mutation rate for fine-tuning
            neighbor.mutate(rate: 0.3, context: context)
            neighbor.repair(context: context)
            evaluate(&neighbor)

            let delta = neighbor.fitness - current.fitness
            if delta > 0 {
                // Always accept improvements
                current = neighbor
            } else if temperature > 1e-6 && Double.random(in: 0...1) < exp(delta / temperature) {
                // Accept worse solution with SA probability
                current = neighbor
            }

            temperature *= coolingRate
        }

        return current
    }
}
