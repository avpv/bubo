import Foundation

// MARK: - GA Configuration

struct GAConfiguration {
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
        adaptiveMutation: true
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
        adaptiveMutation: false
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
        adaptiveMutation: true
    )
}

// MARK: - GA Progress

struct GAProgress {
    let generation: Int
    let bestFitness: Double
    let averageFitness: Double
    let diversity: Double
}

// MARK: - Genetic Algorithm Engine

/// The core genetic algorithm engine, generic over chromosome type.
final class GeneticAlgorithm<C: Chromosome> {
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
        var population = Population<C>(
            size: config.populationSize,
            eliteCount: config.eliteCount,
            context: context
        )

        // Evaluate initial population
        population.evaluateAll(using: evaluate)
        bestEver = population.best

        var staleGenerations = 0
        var lastBestFitness = bestEver?.fitness ?? 0

        for generation in 0..<config.maxGenerations {
            // Create next generation
            var offspring: [C] = []

            while offspring.count < config.populationSize - config.eliteCount {
                let (parent1, parent2) = Selection.selectPair(
                    from: population,
                    strategy: config.selectionStrategy
                )

                var child1: C
                var child2: C

                if Double.random(in: 0...1) < config.crossoverRate {
                    (child1, child2) = parent1.crossover(with: parent2, context: context)
                } else {
                    child1 = parent1
                    child2 = parent2
                }

                // Mutation
                let rate = config.adaptiveMutation
                    ? config.mutationRate * max(0.1, 1.0 - Double(generation) / Double(config.maxGenerations))
                    : config.mutationRate

                child1.mutate(rate: rate, context: context)
                child2.mutate(rate: rate, context: context)

                offspring.append(child1)
                offspring.append(child2)
            }

            // Evaluate offspring
            for i in offspring.indices {
                evaluate(&offspring[i])
            }

            // Replace generation (elitism handled by Population)
            population.replaceGeneration(with: offspring)

            // Track best
            if let currentBest = population.best {
                if bestEver == nil || currentBest.fitness > bestEver!.fitness {
                    bestEver = currentBest
                }
            }

            // Progress callback
            onProgress?(GAProgress(
                generation: generation,
                bestFitness: bestEver?.fitness ?? 0,
                averageFitness: population.averageFitness,
                diversity: population.fitnessDiversity
            ))

            // Convergence check
            let improvement = abs((bestEver?.fitness ?? 0) - lastBestFitness)
            if improvement < config.convergenceThreshold {
                staleGenerations += 1
            } else {
                staleGenerations = 0
                convergenceGeneration = generation
            }
            lastBestFitness = bestEver?.fitness ?? 0

            if staleGenerations >= config.convergencePatience {
                convergenceGeneration = generation - config.convergencePatience
                break
            }
        }

        return population.sortedByFitness
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

        population.evaluateAll(using: evaluate)
        bestEver = population.best

        var staleGenerations = 0
        var lastBestFitness = bestEver?.fitness ?? 0

        for generation in 0..<config.maxGenerations {
            var offspring: [C] = []

            while offspring.count < config.populationSize - config.eliteCount {
                let (parent1, parent2) = Selection.selectPair(
                    from: population,
                    strategy: config.selectionStrategy
                )

                var child1: C
                var child2: C

                if Double.random(in: 0...1) < config.crossoverRate {
                    (child1, child2) = parent1.crossover(with: parent2, context: context)
                } else {
                    child1 = parent1
                    child2 = parent2
                }

                let rate = config.adaptiveMutation
                    ? config.mutationRate * max(0.1, 1.0 - Double(generation) / Double(config.maxGenerations))
                    : config.mutationRate
                child1.mutate(rate: rate, context: context)
                child2.mutate(rate: rate, context: context)

                offspring.append(child1)
                offspring.append(child2)
            }

            for i in offspring.indices {
                evaluate(&offspring[i])
            }

            population.replaceGeneration(with: offspring)

            if let currentBest = population.best {
                if bestEver == nil || currentBest.fitness > bestEver!.fitness {
                    bestEver = currentBest
                }
            }

            let improvement = abs((bestEver?.fitness ?? 0) - lastBestFitness)
            if improvement < config.convergenceThreshold {
                staleGenerations += 1
            } else {
                staleGenerations = 0
                convergenceGeneration = generation
            }
            lastBestFitness = bestEver?.fitness ?? 0

            if staleGenerations >= config.convergencePatience {
                break
            }
        }

        return population.sortedByFitness
    }
}
