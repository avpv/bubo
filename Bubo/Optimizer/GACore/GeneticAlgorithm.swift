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
        immigrationRate: 0.1
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
        immigrationRate: 0.1
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
        immigrationRate: 0.15
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
        var population = Population<C>(
            size: config.populationSize,
            eliteCount: config.eliteCount,
            context: context
        )
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

    // MARK: - Core Evolution Loop

    private func evolve(_ population: inout Population<C>) -> [C] {
        population.evaluateAll(using: evaluate)
        bestEver = population.best

        var staleGenerations = 0
        var lastBestFitness = bestEver?.fitness ?? 0

        for generation in 0..<config.maxGenerations {
            let diversity = population.fitnessDiversity
            let diversityIsLow = diversity < config.diversityThreshold

            // Immigration: inject random individuals when diversity collapses
            if diversityIsLow && config.immigrationRate > 0 {
                let immigrantCount = max(1, Int(Double(config.populationSize) * config.immigrationRate))
                population.injectImmigrants(count: immigrantCount, context: context, evaluate: evaluate)
            }

            var offspring: [C] = []
            let targetCount = config.populationSize - config.eliteCount

            while offspring.count < targetCount {
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

                // Diversity-driven adaptive mutation: boost when population converges,
                // decay with generation progress, but never below 10% of base rate
                let rate: Double
                if config.adaptiveMutation {
                    let generationDecay = max(0.1, 1.0 - Double(generation) / Double(config.maxGenerations))
                    let diversityBoost = diversityIsLow ? 2.5 : 1.0
                    rate = min(1.0, config.mutationRate * generationDecay * diversityBoost)
                } else {
                    rate = config.mutationRate
                }

                child1.mutate(rate: rate, context: context)
                child2.mutate(rate: rate, context: context)

                offspring.append(child1)
                offspring.append(child2)
            }

            // Trim excess offspring (loop appends 2 at a time, may overshoot by 1)
            if offspring.count > targetCount {
                offspring.removeLast(offspring.count - targetCount)
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

            onProgress?(GAProgress(
                generation: generation,
                bestFitness: bestEver?.fitness ?? 0,
                averageFitness: population.averageFitness,
                diversity: diversity
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

        return population.sortedByFitness
    }
}
