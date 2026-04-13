import Foundation

// MARK: - Island Model Configuration

/// Configuration for the Island Model genetic algorithm.
/// Multiple populations (islands) evolve in parallel with periodic migration
/// of individuals between islands, enabling better exploration of the solution space.
struct IslandConfiguration: Sendable {
    /// Number of parallel island populations.
    var islandCount: Int

    /// Number of generations between migration events.
    var migrationInterval: Int

    /// Number of individuals migrated per island per event.
    var migrationSize: Int

    /// How islands are connected for migration.
    var topology: MigrationTopology

    /// Strategy for selecting emigrants from a source island.
    var emigrantSelection: EmigrantSelection

    /// Strategy for replacing individuals on the receiving island.
    var immigrantReplacement: ImmigrantReplacement

    /// Whether to diversify GA parameters across islands for heterogeneous search.
    /// When true, islands get varied mutation rates, selection strategies, and crossover
    /// strategies to explore different regions of the search space.
    var diversifyIslands: Bool

    static let `default` = IslandConfiguration(
        islandCount: 4,
        migrationInterval: 20,
        migrationSize: 3,
        topology: .ring,
        emigrantSelection: .best,
        immigrantReplacement: .worst,
        diversifyIslands: true
    )

    /// Larger island count for deep weekly planning.
    static let thorough = IslandConfiguration(
        islandCount: 6,
        migrationInterval: 25,
        migrationSize: 4,
        topology: .ring,
        emigrantSelection: .best,
        immigrantReplacement: .worst,
        diversifyIslands: true
    )
}

// MARK: - Migration Topology

/// Defines the connectivity pattern between islands for migration.
enum MigrationTopology: Sendable {
    /// Unidirectional ring: island i sends to island (i+1) % n.
    /// Low connectivity preserves island diversity longer.
    case ring

    /// Every island sends migrants to every other island.
    /// High connectivity accelerates convergence but reduces diversity.
    case fullyConnected

    /// Random pairs of islands exchange individuals each migration event.
    /// Moderate connectivity with stochastic variety.
    case randomPairs
}

// MARK: - Emigrant Selection

/// How individuals are chosen to migrate from a source island.
enum EmigrantSelection: Sendable {
    /// Select the best individuals from the source island.
    case best

    /// Tournament selection from the source island.
    case tournament(size: Int)
}

// MARK: - Immigrant Replacement

/// How incoming migrants replace individuals on the receiving island.
enum ImmigrantReplacement: Sendable {
    /// Replace the worst individuals on the receiving island.
    case worst

    /// Replace random individuals (excluding elites) on the receiving island.
    case random
}

// MARK: - Island Progress

/// Progress information aggregated across all islands.
struct IslandModelProgress: Sendable {
    let generation: Int
    let globalBestFitness: Double
    let islandBestFitnesses: [Double]
    let islandDiversities: [Double]
    let migrationsPerformed: Int
}

// MARK: - Island (Internal)

/// A single island holding a population and its per-island evolution state.
private final class Island<C: Chromosome> {
    var population: Population<C>
    let config: GAConfiguration
    var bestEver: C?
    var staleGenerations: Int = 0
    var lastBestFitness: Double = 0

    init(population: Population<C>, config: GAConfiguration) {
        self.population = population
        self.config = config
        self.bestEver = population.best
        self.lastBestFitness = bestEver?.fitness ?? 0
    }
}

// MARK: - Island Model GA Engine

/// Island Model genetic algorithm: multiple populations evolve in parallel with
/// periodic migration of individuals between islands.
///
/// Each island can optionally use different GA parameters (mutation rate, selection
/// strategy, crossover strategy) to explore the solution space from different angles.
/// Periodic migration shares good genetic material between islands while maintaining
/// population diversity — the key advantage over a single large population.
///
/// Thread safety: like `GeneticAlgorithm`, instances are created fresh within a
/// `Task.detached` block. Islands evolve in parallel using GCD `concurrentPerform`.
final class IslandModelGA<C: Chromosome>: @unchecked Sendable {
    let islandConfig: IslandConfiguration
    let baseConfig: GAConfiguration
    let context: OptimizerContext
    private let evaluate: (inout C) -> Void
    private var onProgress: ((IslandModelProgress) -> Void)?

    private(set) var bestEver: C?
    private(set) var convergenceGeneration: Int = 0

    init(
        islandConfig: IslandConfiguration = .default,
        baseConfig: GAConfiguration = .thorough,
        context: OptimizerContext,
        evaluate: @escaping (inout C) -> Void,
        onProgress: ((IslandModelProgress) -> Void)? = nil
    ) {
        self.islandConfig = islandConfig
        self.baseConfig = baseConfig
        self.context = context
        self.evaluate = evaluate
        self.onProgress = onProgress
    }

    // MARK: - Run

    /// Run the island model GA and return the combined final population (sorted by fitness).
    func run() -> [C] {
        // 1. Create islands with (optionally) diversified configurations
        let islandConfigs = makeIslandConfigs()
        let islands = islandConfigs.map { config -> Island<C> in
            var pop = Population<C>(
                size: config.populationSize,
                eliteCount: config.eliteCount,
                context: context
            )
            pop.evaluateAll(using: evaluate)
            return Island(population: pop, config: config)
        }

        bestEver = islands.compactMap(\.bestEver).max(by: { $0.fitness < $1.fitness })

        // 2. Evolve with periodic migration
        let totalGenerations = baseConfig.maxGenerations
        var globalStaleGenerations = 0
        var lastGlobalBestFitness = bestEver?.fitness ?? 0
        var totalMigrations = 0

        for generation in 0..<totalGenerations {
            // Evolve each island for one generation in parallel.
            // Each Island is a reference type, so concurrent access to separate
            // instances via index is safe.
            DispatchQueue.concurrentPerform(iterations: islands.count) { i in
                self.evolveOneGeneration(
                    island: islands[i],
                    generation: generation,
                    maxGenerations: totalGenerations
                )
            }

            // Periodic migration
            if generation > 0 && generation % islandConfig.migrationInterval == 0 {
                migrate(islands: islands)
                totalMigrations += 1
            }

            // Update global best
            for island in islands {
                if let islandBest = island.bestEver {
                    if bestEver == nil || islandBest.fitness > bestEver!.fitness {
                        bestEver = islandBest
                    }
                }
            }

            // Progress callback
            onProgress?(IslandModelProgress(
                generation: generation,
                globalBestFitness: bestEver?.fitness ?? 0,
                islandBestFitnesses: islands.map { $0.bestEver?.fitness ?? 0 },
                islandDiversities: islands.map { $0.population.fitnessDiversity },
                migrationsPerformed: totalMigrations
            ))

            // Global convergence detection
            let currentGlobalBest = bestEver?.fitness ?? 0
            let relativeImprovement = lastGlobalBestFitness > 1e-9
                ? abs(currentGlobalBest - lastGlobalBestFitness) / lastGlobalBestFitness
                : abs(currentGlobalBest - lastGlobalBestFitness)

            if relativeImprovement < baseConfig.convergenceThreshold {
                globalStaleGenerations += 1
            } else {
                globalStaleGenerations = 0
                convergenceGeneration = generation
            }
            lastGlobalBestFitness = currentGlobalBest

            // Use higher patience for island model — migration can revive stale islands
            let globalPatience = baseConfig.convergencePatience + islandConfig.migrationInterval
            if globalStaleGenerations >= globalPatience {
                convergenceGeneration = generation - globalPatience
                break
            }
        }

        // 3. Collect top individuals from all islands
        var combined: [C] = []
        for island in islands {
            combined.append(contentsOf: island.population.sortedByFitness.prefix(island.config.eliteCount * 2))
        }

        // 4. Hill climb on top individuals
        let refineCount = min(baseConfig.eliteCount * 2, combined.count)
        combined.sort { $0.fitness > $1.fitness }
        for i in 0..<refineCount {
            combined[i] = hillClimb(combined[i], steps: 20)
        }

        // Update bestEver after hill climbing
        if let refined = combined.first, (bestEver == nil || refined.fitness > bestEver!.fitness) {
            bestEver = refined
        }

        return combined.sorted { $0.fitness > $1.fitness }
    }

    // MARK: - Per-Island Single Generation

    /// Evolve a single island for one generation. This contains the core GA logic:
    /// diversity-driven immigration, selection, crossover, adaptive mutation,
    /// parallel fitness evaluation, and elitist replacement.
    private func evolveOneGeneration(
        island: Island<C>,
        generation: Int,
        maxGenerations: Int
    ) {
        let config = island.config
        let diversity = island.population.fitnessDiversity
        let diversityIsLow = diversity < config.diversityThreshold

        // Immigration: inject random individuals when diversity collapses
        if diversityIsLow && config.immigrationRate > 0 {
            let immigrantCount = max(1, Int(Double(config.populationSize) * config.immigrationRate))
            island.population.injectImmigrants(count: immigrantCount, context: context, evaluate: evaluate)
        }

        // Selection + Crossover + Mutation
        var offspring: [C] = []
        let targetCount = config.populationSize - config.eliteCount

        while offspring.count < targetCount {
            let (parent1, parent2) = Selection.selectPair(
                from: island.population,
                strategy: config.selectionStrategy
            )

            var child1: C
            var child2: C

            if Double.random(in: 0...1) < config.crossoverRate {
                (child1, child2) = parent1.crossover(with: parent2, strategy: config.crossoverStrategy, context: context)
            } else {
                child1 = parent1
                child2 = parent2
            }

            // Adaptive mutation: boost when diversity is low, decay over generations
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

            offspring.append(child1)
            offspring.append(child2)
        }

        // Trim excess offspring (loop appends 2 at a time, may overshoot by 1)
        if offspring.count > targetCount {
            offspring.removeLast(offspring.count - targetCount)
        }

        // Parallel fitness evaluation
        if offspring.count > 1 {
            DispatchQueue.concurrentPerform(iterations: offspring.count) { i in
                self.evaluate(&offspring[i])
            }
        } else {
            for i in offspring.indices {
                evaluate(&offspring[i])
            }
        }

        // Elitist replacement
        island.population.replaceGeneration(with: offspring)

        // Track per-island best
        if let currentBest = island.population.best {
            if island.bestEver == nil || currentBest.fitness > island.bestEver!.fitness {
                island.bestEver = currentBest
            }
        }
    }

    // MARK: - Migration

    /// Transfer individuals between islands according to the configured topology.
    private func migrate(islands: [Island<C>]) {
        let n = islands.count
        guard n > 1 else { return }

        let migrationPairs = makeMigrationPairs(islandCount: n)

        for (source, destination) in migrationPairs {
            let emigrants = selectEmigrants(from: islands[source])
            insertImmigrants(emigrants, into: islands[destination])
        }
    }

    /// Determine which island pairs exchange individuals based on topology.
    private func makeMigrationPairs(islandCount n: Int) -> [(source: Int, destination: Int)] {
        switch islandConfig.topology {
        case .ring:
            // Unidirectional ring: i -> (i+1) % n
            return (0..<n).map { ($0, ($0 + 1) % n) }

        case .fullyConnected:
            // Every island sends to every other island
            var pairs: [(Int, Int)] = []
            for i in 0..<n {
                for j in 0..<n where i != j {
                    pairs.append((i, j))
                }
            }
            return pairs

        case .randomPairs:
            // Shuffle islands into random pairs
            var indices = Array(0..<n)
            indices.shuffle()
            var pairs: [(Int, Int)] = []
            for i in stride(from: 0, to: n - 1, by: 2) {
                pairs.append((indices[i], indices[i + 1]))
                pairs.append((indices[i + 1], indices[i]))
            }
            return pairs
        }
    }

    /// Select individuals to emigrate from a source island.
    private func selectEmigrants(from island: Island<C>) -> [C] {
        let count = min(islandConfig.migrationSize, island.population.size)

        switch islandConfig.emigrantSelection {
        case .best:
            return Array(island.population.sortedByFitness.prefix(count))

        case .tournament(let tournamentSize):
            var emigrants: [C] = []
            for _ in 0..<count {
                let candidate = Selection.select(
                    from: island.population,
                    strategy: .tournament(size: tournamentSize)
                )
                emigrants.append(candidate)
            }
            return emigrants
        }
    }

    /// Insert migrant individuals into a destination island.
    private func insertImmigrants(_ immigrants: [C], into island: Island<C>) {
        guard !immigrants.isEmpty else { return }

        var individuals = island.population.individuals
        let eliteCount = island.population.eliteCount

        switch islandConfig.immigrantReplacement {
        case .worst:
            // Sort by fitness descending, replace the tail
            individuals.sort { $0.fitness > $1.fitness }
            let replaceStart = max(eliteCount, individuals.count - immigrants.count)
            for (i, immigrant) in immigrants.enumerated() {
                let idx = replaceStart + i
                guard idx < individuals.count else { break }
                individuals[idx] = immigrant
            }

        case .random:
            // Replace random non-elite individuals
            let nonEliteIndices = Array(eliteCount..<individuals.count)
            guard !nonEliteIndices.isEmpty else { return }
            let replaceIndices = nonEliteIndices.shuffled().prefix(immigrants.count)
            for (immigrant, idx) in zip(immigrants, replaceIndices) {
                individuals[idx] = immigrant
            }
        }

        island.population = Population(
            individuals: individuals,
            eliteCount: eliteCount
        )
    }

    // MARK: - Island Configuration Diversification

    /// Create per-island GA configurations. When diversification is enabled,
    /// islands get varied parameters to explore different regions of the search space:
    /// - Island 0: base config (exploitation-focused)
    /// - Island 1: high mutation (exploration-focused)
    /// - Island 2: rank selection (less greedy selection pressure)
    /// - Island 3: uniform crossover (more gene mixing)
    /// - Islands 4+: random variations
    private func makeIslandConfigs() -> [GAConfiguration] {
        guard islandConfig.diversifyIslands else {
            return Array(repeating: baseConfig, count: islandConfig.islandCount)
        }

        var configs: [GAConfiguration] = []

        for i in 0..<islandConfig.islandCount {
            var config = baseConfig
            switch i {
            case 0:
                // Island 0: exploitation — base config, lower mutation
                break

            case 1:
                // Island 1: exploration — higher mutation, smaller tournament
                config.mutationRate = min(0.4, baseConfig.mutationRate * 2.5)
                config.selectionStrategy = .tournament(size: 2)
                config.adaptiveMutation = false

            case 2:
                // Island 2: rank selection — less fitness-proportional pressure
                config.selectionStrategy = .rank
                config.mutationRate = baseConfig.mutationRate * 1.3

            case 3:
                // Island 3: uniform crossover — more gene mixing
                config.crossoverStrategy = .uniform(swapProbability: 0.5)
                config.crossoverRate = 0.9

            default:
                // Additional islands: random parameter variations
                config.mutationRate = baseConfig.mutationRate * Double.random(in: 0.5...3.0)
                config.crossoverRate = Double.random(in: 0.6...0.95)
                let strategies: [SelectionStrategy] = [
                    .tournament(size: 3),
                    .tournament(size: 5),
                    .rank,
                    .stochasticUniversalSampling
                ]
                config.selectionStrategy = strategies.randomElement()!
            }
            configs.append(config)
        }

        return configs
    }

    // MARK: - Hill Climbing

    /// Apply small perturbations to a chromosome and keep improvements.
    private func hillClimb(_ chromosome: C, steps: Int) -> C {
        var current = chromosome
        for _ in 0..<steps {
            var neighbor = current
            neighbor.mutate(rate: 0.3, context: context)
            evaluate(&neighbor)
            if neighbor.fitness > current.fitness {
                current = neighbor
            }
        }
        return current
    }
}
