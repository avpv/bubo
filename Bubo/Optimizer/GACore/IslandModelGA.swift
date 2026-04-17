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

    /// Whether to adapt migration frequency/size based on global stagnation and
    /// cross-island diversity. When true, migration intensifies when progress stalls
    /// and relaxes when islands are still diverging productively.
    var adaptiveMigration: Bool

    /// Fast configs: 2 islands, frequent migration, no diversification.
    /// Adds modest exploration benefit without significant overhead.
    static let quick = IslandConfiguration(
        islandCount: 2,
        migrationInterval: 10,
        migrationSize: 2,
        topology: .ring,
        emigrantSelection: .best,
        immigrantReplacement: .worst,
        diversifyIslands: false,
        adaptiveMigration: false
    )

    static let `default` = IslandConfiguration(
        islandCount: 4,
        migrationInterval: 20,
        migrationSize: 3,
        topology: .ring,
        emigrantSelection: .best,
        immigrantReplacement: .worst,
        diversifyIslands: true,
        adaptiveMigration: true
    )

    /// Larger island count for deep weekly planning.
    static let thorough = IslandConfiguration(
        islandCount: 6,
        migrationInterval: 25,
        migrationSize: 4,
        topology: .ring,
        emigrantSelection: .best,
        immigrantReplacement: .worst,
        diversifyIslands: true,
        adaptiveMigration: true
    )

    /// Validate configuration, clamping values to safe ranges.
    /// Call this before passing to `IslandModelGA`.
    func validated(populationSize: Int) -> IslandConfiguration {
        var copy = self
        copy.islandCount = max(1, islandCount)
        copy.migrationInterval = max(1, migrationInterval)
        copy.migrationSize = max(1, min(migrationSize, populationSize / 2))
        return copy
    }
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
enum ImmigrantReplacement: Sendable, Equatable {
    /// Replace the worst individuals on the receiving island.
    case worst

    /// Replace random individuals (excluding elites) on the receiving island.
    case random
}

// MARK: - Cross-Island Diversity

/// Measures how different the best solutions across islands are.
/// Used by adaptive migration to decide when to intensify or relax migration.
struct CrossIslandDiversity {
    /// Fraction of island best individuals that are genetically unique (by Equatable).
    /// 0 = all islands converged to same solution, 1 = all islands have different bests.
    let uniqueBestFraction: Double

    /// Range of best fitness values across islands (max - min).
    /// 0 = all islands found equal-quality solutions.
    let fitnessRange: Double

    /// Standard deviation of best fitness values across islands.
    let fitnessStdDev: Double
}

// MARK: - Island Progress

/// Progress information aggregated across all islands.
struct IslandModelProgress: Sendable {
    let generation: Int
    let globalBestFitness: Double
    let islandBestFitnesses: [Double]
    let islandDiversities: [Double]
    let migrationsPerformed: Int
    /// Cross-island diversity: how different island bests are from each other.
    let crossIslandDiversity: Double
    /// Current effective migration interval (may differ from config when adaptive).
    let effectiveMigrationInterval: Int
}

// MARK: - Island (Internal)

/// A single island holding a population, its GA engine, and per-island evolution state.
/// Reference type so that `concurrentPerform` can safely mutate separate instances.
///
/// Each island owns its own `OptimizerContext` with an independently-split
/// `GARandom`. Two motivations:
/// 1. Thread safety: GARandom mutates state on every draw; islands evolve in
///    parallel, so they must not share a generator.
/// 2. Determinism: deriving per-island seeds from the parent via `split()`
///    makes the whole island model run reproducible when the top-level seed
///    is fixed — every island gets the same private stream it would have
///    gotten on any previous run with the same seed, regardless of thread
///    scheduling.
private final class Island<C: Chromosome> {
    var population: Population<C>
    let ga: GeneticAlgorithm<C>
    let context: OptimizerContext
    var bestEver: C?

    init(population: Population<C>, ga: GeneticAlgorithm<C>, context: OptimizerContext) {
        self.population = population
        self.ga = ga
        self.context = context
        self.bestEver = population.best
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
/// Evolution logic is delegated to `GeneticAlgorithm.evolveOneGeneration` so there
/// is a single source of truth for selection, crossover, mutation, and evaluation.
/// Islands evolve in parallel using `concurrentPerform` at island level; per-island
/// fitness evaluation is sequential to avoid GCD thread pool oversubscription.
///
/// Thread safety: like `GeneticAlgorithm`, instances are created fresh within a
/// `Task.detached` block.
final class IslandModelGA<C: Chromosome>: @unchecked Sendable {
    let islandConfig: IslandConfiguration
    let baseConfig: GAConfiguration
    let context: OptimizerContext
    private let evaluate: (inout C) -> Void
    private var onProgress: ((IslandModelProgress) -> Void)?
    private let multiObjective: MultiObjectiveContext<C>?

    /// Shared Quality-Diversity archive across islands. Every island's
    /// evolved offspring are considered for insertion, and every island
    /// may draw emitters from the same global pool.
    let qdArchive: QualityDiversityArchive?

    /// Shared gradient refiner. Wired per-island so every island can
    /// fine-tune its elites on gradient-refine intervals.
    let gradientRefiner: DifferentiableRefiner?

    /// Optional federated mutation bandit. When non-nil, each island's
    /// context gets its *own* per-island `MutationBandit` drawn from the
    /// federation; the island loop triggers periodic merges at
    /// `islandConfig.migrationInterval` boundaries so bandit state stays
    /// shared but not serialized through a single lock.
    let federatedBandit: FederatedMutationBandit?

    private(set) var bestEver: C?
    private(set) var convergenceGeneration: Int = 0

    init(
        islandConfig: IslandConfiguration = .default,
        baseConfig: GAConfiguration = .thorough,
        context: OptimizerContext,
        evaluate: @escaping (inout C) -> Void,
        onProgress: ((IslandModelProgress) -> Void)? = nil,
        multiObjective: MultiObjectiveContext<C>? = nil,
        qdArchive: QualityDiversityArchive? = nil,
        gradientRefiner: DifferentiableRefiner? = nil,
        federatedBandit: FederatedMutationBandit? = nil
    ) {
        self.islandConfig = islandConfig
        self.baseConfig = baseConfig
        self.context = context
        self.evaluate = evaluate
        self.onProgress = onProgress
        self.multiObjective = multiObjective
        self.qdArchive = qdArchive
        self.gradientRefiner = gradientRefiner
        self.federatedBandit = federatedBandit
    }

    // MARK: - Run

    /// Run the island model GA and return the combined final population (sorted by fitness).
    func run() -> [C] {
        precondition(islandConfig.islandCount >= 1, "IslandModelGA requires at least 1 island")
        precondition(islandConfig.migrationInterval >= 1, "migrationInterval must be >= 1")
        precondition(baseConfig.populationSize >= baseConfig.eliteCount + 2,
                     "populationSize must be larger than eliteCount + 1")

        // 1. Create islands with (optionally) diversified configurations.
        //    Each island gets its own GeneticAlgorithm instance for evolveOneGeneration,
        //    and an independently-split RNG so that parallel island evolution is both
        //    thread-safe and deterministic under a fixed top-level seed.
        //    Greedy seeds are distributed per-island based on each island's config.
        let islandConfigs = makeIslandConfigs()
        let islands = islandConfigs.map { config -> Island<C> in
            let islandContext = makeIslandContext()
            let greedyCount = max(0, Int(Double(config.populationSize) * config.greedySeedFraction))
            let randomCount = config.populationSize - greedyCount

            var individuals: [C] = []
            for i in 0..<greedyCount {
                var ind = C.greedy(context: islandContext)
                if i > 0 { ind.mutate(rate: 0.1 + Double(i) * 0.05, context: islandContext) }
                individuals.append(ind)
            }
            for _ in 0..<randomCount {
                individuals.append(C.random(context: islandContext))
            }

            // Repair initial population if enabled
            if config.enableRepair {
                for i in individuals.indices {
                    individuals[i].repair(context: islandContext)
                }
            }

            var pop = Population<C>(individuals: individuals, eliteCount: config.eliteCount)
            pop.evaluateAll(using: evaluate)
            let ga = GeneticAlgorithm<C>(
                config: config,
                context: islandContext,
                evaluate: evaluate,
                multiObjective: multiObjective,
                qdArchive: qdArchive,
                gradientRefiner: gradientRefiner
            )
            return Island(population: pop, ga: ga, context: islandContext)
        }

        return evolveIslands(islands)
    }

    /// Build a fresh `OptimizerContext` for a single island, sharing everything
    /// except the random-number generator with the parent. `split()` is called
    /// on the parent RNG in the order islands are created, so the sequence is
    /// deterministic — island 0 gets the first split, island 1 the second, etc.
    ///
    /// The `MutationBandit` is intentionally *shared* across islands when
    /// present: every pull on every island contributes to the same UCB arm
    /// statistics, which accelerates convergence of the operator allocation.
    /// Islands evolve in parallel, so the bandit's lock is the only concurrency
    /// point; lock contention is negligible (one acquisition per mutate call,
    /// ~microsecond cost versus ms-scale eval cost).
    private func makeIslandContext() -> OptimizerContext {
        OptimizerContext(
            fixedEvents: context.fixedEvents,
            movableEvents: context.movableEvents,
            workingHours: context.workingHours,
            planningHorizon: context.planningHorizon,
            preferences: context.preferences,
            participantAvailability: context.participantAvailability,
            calendar: context.calendar,
            rng: context.rng.split(),
            mutationBandit: context.mutationBandit,
            contextualCrossoverHead: context.contextualCrossoverHead
        )
    }

    // MARK: - Run Seeded

    /// Run the island model GA seeded with existing individuals (for warm-start re-optimization).
    /// Seeds are distributed across islands round-robin so every island gets warm-start
    /// material. Remaining slots per island are filled with random individuals.
    func runSeeded(with seed: [C]) -> [C] {
        precondition(islandConfig.islandCount >= 1, "IslandModelGA requires at least 1 island")
        precondition(islandConfig.migrationInterval >= 1, "migrationInterval must be >= 1")
        precondition(baseConfig.populationSize >= baseConfig.eliteCount + 2,
                     "populationSize must be larger than eliteCount + 1")

        let islandConfigs = makeIslandConfigs()
        let islandCount = islandConfigs.count

        // Distribute seeds across islands round-robin
        var seedBuckets: [[C]] = Array(repeating: [], count: islandCount)
        for (i, individual) in seed.enumerated() {
            seedBuckets[i % islandCount].append(individual)
        }

        let islands = islandConfigs.enumerated().map { (idx, config) -> Island<C> in
            let islandContext = makeIslandContext()
            var individuals = seedBuckets[idx]

            // Evaluate seeds that haven't been evaluated
            for i in individuals.indices {
                evaluate(&individuals[i])
            }

            // Fill remaining slots with random individuals
            while individuals.count < config.populationSize {
                var individual = C.random(context: islandContext)
                evaluate(&individual)
                individuals.append(individual)
            }

            let pop = Population<C>(individuals: individuals, eliteCount: config.eliteCount)
            let ga = GeneticAlgorithm<C>(
                config: config,
                context: islandContext,
                evaluate: evaluate,
                multiObjective: multiObjective,
                qdArchive: qdArchive,
                gradientRefiner: gradientRefiner
            )
            return Island(population: pop, ga: ga, context: islandContext)
        }

        return evolveIslands(islands)
    }

    // MARK: - Core Evolution Loop

    /// Shared evolution loop for both `run()` and `runSeeded(with:)`.
    private func evolveIslands(_ islands: [Island<C>]) -> [C] {
        bestEver = islands.compactMap(\.bestEver).max(by: { $0.rawFitness < $1.rawFitness })

        let totalGenerations = baseConfig.maxGenerations
        var globalStaleGenerations = 0
        var lastGlobalBestFitness = bestEver?.rawFitness ?? 0
        var totalMigrations = 0

        // Adaptive migration state
        var effectiveInterval = islandConfig.migrationInterval
        var effectiveSize = islandConfig.migrationSize
        var lastCrossDiversity: CrossIslandDiversity?

        for generation in 0..<totalGenerations {
            // Evolve each island for one generation in parallel.
            // Each Island is a reference type, so concurrent access to separate
            // instances is safe. parallelEvaluation=false avoids nested concurrentPerform.
            let capturedStale = globalStaleGenerations
            DispatchQueue.concurrentPerform(iterations: islands.count) { i in
                let island = islands[i]
                island.ga.evolveOneGeneration(
                    &island.population,
                    config: island.ga.config,
                    generation: generation,
                    maxGenerations: totalGenerations,
                    parallelEvaluation: false,
                    staleGenerations: capturedStale
                )

                // Track per-island best by rawFitness to avoid fitness-sharing
                // demotion. Store a normalized copy so downstream consumers see
                // true quality on `bestEver.fitness`.
                if let currentBest = island.population.individuals.max(by: { $0.rawFitness < $1.rawFitness }) {
                    if island.bestEver == nil || currentBest.rawFitness > island.bestEver!.rawFitness {
                        var snapshot = currentBest
                        if snapshot.rawFitness > 0 { snapshot.fitness = snapshot.rawFitness }
                        island.bestEver = snapshot
                    }
                }
            }

            // Cross-island diversity: only compute near migration boundaries
            // to avoid O(islands²) Equatable comparison every generation.
            let isMigrationGeneration = generation > 0 && generation % effectiveInterval == 0
            let isPreMigration = generation > 0 && (generation + 1) % effectiveInterval == 0
            let crossDiversity: CrossIslandDiversity
            if isMigrationGeneration || isPreMigration || generation == 0 {
                crossDiversity = measureCrossIslandDiversity(islands)
            } else {
                // Cheap fallback: just fitness spread, no Equatable scan
                let fitnesses = islands.compactMap { $0.bestEver?.rawFitness }
                let range = (fitnesses.max() ?? 0) - (fitnesses.min() ?? 0)
                crossDiversity = CrossIslandDiversity(
                    uniqueBestFraction: lastCrossDiversity?.uniqueBestFraction ?? 1.0,
                    fitnessRange: range,
                    fitnessStdDev: lastCrossDiversity?.fitnessStdDev ?? 0
                )
            }
            lastCrossDiversity = crossDiversity

            // Adaptive migration: adjust interval and size based on stagnation/diversity
            if islandConfig.adaptiveMigration {
                let halfPatience = baseConfig.convergencePatience / 2
                if globalStaleGenerations > halfPatience {
                    // Stagnating: migrate more frequently with more individuals
                    effectiveInterval = max(3, islandConfig.migrationInterval / 2)
                    effectiveSize = min(islandConfig.migrationSize * 2,
                                       baseConfig.populationSize / 3)
                } else if crossDiversity.uniqueBestFraction > 0.8 && crossDiversity.fitnessStdDev > baseConfig.convergenceThreshold * 10 {
                    // High diversity + spread: let islands explore, migrate less
                    effectiveInterval = islandConfig.migrationInterval * 2
                    effectiveSize = max(1, islandConfig.migrationSize / 2)
                } else {
                    // Normal: use configured values
                    effectiveInterval = islandConfig.migrationInterval
                    effectiveSize = islandConfig.migrationSize
                }
            }

            // Periodic migration with effective parameters
            if isMigrationGeneration {
                migrate(islands: islands, migrationSize: effectiveSize)
                totalMigrations += 1

                // Federated bandit merge coincides with migration
                // boundaries: both share the rhythm of "islands have
                // accumulated distinct experience, now exchange and
                // continue." Uniform weighting across islands keeps the
                // default behaviour symmetric; callers can weight by
                // per-island best-fitness via a custom scheme if needed.
                if let federated = federatedBandit {
                    federated.merge()
                }
            }

            // Update global best (by rawFitness — see per-island note above).
            for island in islands {
                if let islandBest = island.bestEver {
                    if bestEver == nil || islandBest.rawFitness > bestEver!.rawFitness {
                        bestEver = islandBest
                    }
                }
            }

            // Progress callback
            onProgress?(IslandModelProgress(
                generation: generation,
                globalBestFitness: bestEver?.rawFitness ?? 0,
                islandBestFitnesses: islands.map { $0.bestEver?.rawFitness ?? 0 },
                islandDiversities: islands.map { $0.population.fitnessDiversity },
                migrationsPerformed: totalMigrations,
                crossIslandDiversity: crossDiversity.uniqueBestFraction,
                effectiveMigrationInterval: effectiveInterval
            ))

            // Global convergence detection
            let currentGlobalBest = bestEver?.rawFitness ?? 0
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

        // Collect top individuals from all islands
        var combined: [C] = []
        for island in islands {
            combined.append(contentsOf: island.population.sortedByFitness.prefix(island.ga.config.eliteCount * 2))
        }

        // Hill climb on top individuals (reuse GA's hill climbing). Sort by
        // rawFitness since some islands may have fitness sharing enabled,
        // which would bias selection of climb candidates toward sparse niches.
        combined.sort { $0.rawFitness > $1.rawFitness }
        let refineCount = min(baseConfig.eliteCount * 2, combined.count)
        let refiner = islands[0].ga
        for i in 0..<refineCount {
            combined[i] = refiner.hillClimb(combined[i], steps: 20)
        }

        // Update bestEver after hill climbing (by rawFitness).
        if let refined = combined.max(by: { $0.rawFitness < $1.rawFitness }),
           bestEver == nil || refined.rawFitness > bestEver!.rawFitness {
            bestEver = refined
        }

        return combined.sorted { $0.rawFitness > $1.rawFitness }
    }

    // MARK: - Cross-Island Diversity

    /// Measure how different the best solutions across islands are.
    /// Uses Equatable conformance to count unique bests and fitness spread.
    private func measureCrossIslandDiversity(_ islands: [Island<C>]) -> CrossIslandDiversity {
        let bests = islands.compactMap(\.bestEver)
        guard bests.count > 1 else {
            return CrossIslandDiversity(uniqueBestFraction: 1.0, fitnessRange: 0, fitnessStdDev: 0)
        }

        // Count unique bests using Equatable
        var uniqueCount = 0
        var seen: [C] = []
        for best in bests {
            if !seen.contains(where: { $0 == best }) {
                seen.append(best)
                uniqueCount += 1
            }
        }
        let uniqueFraction = Double(uniqueCount) / Double(bests.count)

        // Fitness range and std dev across island bests
        let fitnesses = bests.map(\.fitness)
        let minFit = fitnesses.min() ?? 0
        let maxFit = fitnesses.max() ?? 0
        let range = maxFit - minFit

        let avg = fitnesses.reduce(0, +) / Double(fitnesses.count)
        let variance = fitnesses.reduce(0.0) { $0 + pow($1 - avg, 2) } / Double(fitnesses.count - 1)
        let stdDev = sqrt(variance)

        return CrossIslandDiversity(
            uniqueBestFraction: uniqueFraction,
            fitnessRange: range,
            fitnessStdDev: stdDev
        )
    }

    // MARK: - Migration

    /// Transfer individuals between islands according to the configured topology.
    /// Emigrants are copied (not removed) from the source, mirroring standard
    /// island model GA semantics.
    private func migrate(islands: [Island<C>], migrationSize: Int) {
        let n = islands.count
        guard n > 1 else { return }

        let migrationPairs = makeMigrationPairs(islandCount: n)

        // Snapshot emigrants before any replacement to avoid one migration
        // polluting the source for subsequent pairs in the same round.
        let effectiveSize = min(migrationSize, baseConfig.populationSize / 2)
        let emigrantsBySource: [Int: [C]] = Dictionary(
            uniqueKeysWithValues: Set(migrationPairs.map(\.source)).map { sourceIdx in
                (sourceIdx, selectEmigrants(from: islands[sourceIdx], count: effectiveSize))
            }
        )

        for (source, destination) in migrationPairs {
            if let emigrants = emigrantsBySource[source] {
                insertImmigrants(emigrants, into: islands[destination])
            }
        }
    }

    /// Determine which island pairs exchange individuals based on topology.
    private func makeMigrationPairs(islandCount n: Int) -> [(source: Int, destination: Int)] {
        let rng = context.rng
        switch islandConfig.topology {
        case .ring:
            // Unidirectional ring: i -> (i+1) % n
            return (0..<n).map { ($0, ($0 + 1) % n) }

        case .fullyConnected:
            // Each island sends to one randomly chosen neighbor per migration event.
            // This avoids elite flooding: N migrants per island instead of N*(N-1).
            return (0..<n).map { i in
                var j = rng.int(in: 0..<(n - 1))
                if j >= i { j += 1 } // exclude self
                return (i, j)
            }

        case .randomPairs:
            // Shuffle all islands into random pairs; every island participates exactly once.
            var indices = Array(0..<n)
            rng.shuffle(&indices)
            var pairs: [(Int, Int)] = []
            var i = 0
            while i + 1 < n {
                pairs.append((indices[i], indices[i + 1]))
                pairs.append((indices[i + 1], indices[i]))
                i += 2
            }
            // If odd number of islands, the last one exchanges with a random partner.
            if n.isMultiple(of: 2) == false {
                let last = indices[n - 1]
                let partner = indices[rng.int(in: 0..<(n - 1))]
                pairs.append((last, partner))
                pairs.append((partner, last))
            }
            return pairs
        }
    }

    /// Select individuals to emigrate from a source island.
    ///
    /// When multi-objective info is wired, emigrants are drawn from the
    /// source's first non-dominated front with maximum perpendicular
    /// distance to their reference direction — i.e. solutions that are
    /// Pareto-optimal *and* occupy sparse regions of objective space. This
    /// is the variant of migration that actually spreads diversity across
    /// islands; scalar "best by fitness" tends to flood receivers with
    /// near-clones of the global best.
    ///
    /// Without multi-objective info (e.g. permutation chromosomes), we
    /// fall back to the configured scalar strategy: best-K or
    /// tournament-sampled emigrants.
    private func selectEmigrants(from island: Island<C>, count: Int) -> [C] {
        let effectiveCount = min(count, island.population.size)
        guard effectiveCount > 0 else { return [] }

        if let mo = multiObjective {
            return selectParetoEmigrants(from: island, count: effectiveCount, mo: mo)
        }

        switch islandConfig.emigrantSelection {
        case .best:
            return Array(island.population.sortedByFitness.prefix(effectiveCount))

        case .tournament(let tournamentSize):
            var emigrants: [C] = []
            for _ in 0..<effectiveCount {
                let candidate = Selection.select(
                    from: island.population,
                    strategy: .tournament(size: tournamentSize),
                    rng: context.rng
                )
                emigrants.append(candidate)
            }
            return emigrants
        }
    }

    /// Pareto-aware emigrant selection via NSGA-III ranking on the island.
    /// Priority order: (front 0, max perpendicular distance) → (front 0,
    /// next-farthest) → front 1 entries if front 0 is exhausted. The
    /// distance tiebreaker favours diverse solutions over concentrated
    /// ones, so receiving islands get genuine new material.
    private func selectParetoEmigrants(
        from island: Island<C>,
        count: Int,
        mo: MultiObjectiveContext<C>
    ) -> [C] {
        let vectors = island.population.individuals.map(mo.objectiveVectorOf)
        let ranking = mo.activeRanker.rankAll(vectors)

        // Sort candidates by (front ascending, distanceToNiche descending).
        // `.infinity` distances (boundary of the simplex) sort first — those
        // are the most "extreme" solutions which make the best emigrants
        // because they carry objective-space information the receiver
        // probably lacks.
        let ordered = island.population.individuals.indices.sorted { a, b in
            let fa = ranking.frontOf[a] ?? Int.max
            let fb = ranking.frontOf[b] ?? Int.max
            if fa != fb { return fa < fb }
            let da = ranking.distanceToNiche[a] ?? 0
            let db = ranking.distanceToNiche[b] ?? 0
            if da.isInfinite && !db.isInfinite { return true }
            if db.isInfinite && !da.isInfinite { return false }
            return da > db
        }

        return ordered.prefix(count).map { island.population.individuals[$0] }
    }

    /// Insert migrant individuals into a destination island.
    ///
    /// Multi-objective path: replace the worst by dominated-rank —
    /// individuals on the highest (worst) front lose their slots first,
    /// ties broken by lowest perpendicular distance to niche (most-
    /// crowded members on that front). Falls back to scalar worst-replace
    /// when no multi-objective info is available.
    private func insertImmigrants(_ immigrants: [C], into island: Island<C>) {
        guard !immigrants.isEmpty else { return }

        var individuals = island.population.individuals
        let eliteCount = island.population.eliteCount

        if let mo = multiObjective, islandConfig.immigrantReplacement == .worst {
            let vectors = individuals.map(mo.objectiveVectorOf)
            let ranking = mo.activeRanker.rankAll(vectors)

            // Order individuals by dominated-rank descending, breaking ties
            // by crowdedness (smaller distanceToNiche = more crowded =
            // better replacement candidate). Skip elites: the first
            // `eliteCount` best by rawFitness are immune to replacement so
            // an island can't lose all its exploitation in a single
            // migration round.
            let eliteIndices = Set(individuals.indices
                .sorted { individuals[$0].rawFitness > individuals[$1].rawFitness }
                .prefix(eliteCount))
            let replaceable = individuals.indices
                .filter { !eliteIndices.contains($0) }
                .sorted { a, b in
                    let fa = ranking.frontOf[a] ?? 0
                    let fb = ranking.frontOf[b] ?? 0
                    if fa != fb { return fa > fb }  // higher front = worse
                    let da = ranking.distanceToNiche[a] ?? .infinity
                    let db = ranking.distanceToNiche[b] ?? .infinity
                    return da < db  // smaller distance = more crowded
                }
            for (immigrant, idx) in zip(immigrants, replaceable) {
                individuals[idx] = immigrant
            }
        } else {
            switch islandConfig.immigrantReplacement {
            case .worst:
                individuals.sort { $0.fitness > $1.fitness }
                let replaceStart = max(eliteCount, individuals.count - immigrants.count)
                for (i, immigrant) in immigrants.enumerated() {
                    let idx = replaceStart + i
                    guard idx < individuals.count else { break }
                    individuals[idx] = immigrant
                }

            case .random:
                let nonEliteIndices = Array(eliteCount..<individuals.count)
                guard !nonEliteIndices.isEmpty else { return }
                let replaceIndices = context.rng.shuffled(nonEliteIndices).prefix(immigrants.count)
                for (immigrant, idx) in zip(immigrants, replaceIndices) {
                    individuals[idx] = immigrant
                }
            }
        }

        island.population = Population(
            individuals: individuals,
            eliteCount: eliteCount
        )
    }

    // MARK: - Island Configuration Diversification

    /// Create per-island GA configurations. When diversification is enabled,
    /// islands get varied parameters to explore different regions of the
    /// search space. Crowding/sharing knobs were dropped with the NSGA-III
    /// rewrite; diversity is now a first-class property of survivor
    /// selection, so per-island variation focuses on exploration versus
    /// exploitation via mutation rate, selection strategy, and crossover
    /// operator.
    private func makeIslandConfigs() -> [GAConfiguration] {
        guard islandConfig.diversifyIslands else {
            return Array(repeating: baseConfig, count: islandConfig.islandCount)
        }

        var configs: [GAConfiguration] = []

        for i in 0..<islandConfig.islandCount {
            var config = baseConfig
            switch i {
            case 0:
                // Island 0: exploitation — base config, greedy seeds, repair
                config.greedySeedFraction = 0.2
                config.enableRepair = true

            case 1:
                // Island 1: exploration — higher mutation, smaller
                // tournaments to reduce selection pressure so rare
                // mutations survive long enough to get evaluated.
                config.mutationRate = min(0.4, baseConfig.mutationRate * 2.5)
                config.selectionStrategy = .tournament(size: 2)
                config.adaptiveMutation = false
                config.greedySeedFraction = 0.0

            case 2:
                // Island 2: niching via rank selection. NSGA-III gives us
                // niche preservation on the survivor side; rank selection
                // on the parent side flattens fitness pressure so weaker
                // individuals still contribute genes to offspring.
                config.selectionStrategy = .rank
                config.mutationRate = baseConfig.mutationRate * 1.3
                config.greedySeedFraction = 0.1

            case 3:
                // Island 3: day-block crossover — preserves bundled day
                // structures ("morning meeting block") instead of splitting
                // gene-by-gene. Pairs well with adaptive crossover so early
                // generations mix days aggressively and late ones settle.
                config.crossoverStrategy = .dayBlock
                config.crossoverRate = 0.9
                config.adaptiveCrossover = true
                config.greedySeedFraction = 0.15

            default:
                // Additional islands: deterministic parameter variations
                // based on index. Each island gets a unique combination so
                // results are reproducible.
                let variations: [(mutMul: Double, xRate: Double, sel: SelectionStrategy)] = [
                    (1.8, 0.75, .tournament(size: 3)),
                    (0.7, 0.90, .stochasticUniversalSampling),
                    (2.2, 0.80, .tournament(size: 5)),
                    (1.5, 0.70, .rank),
                ]
                let v = variations[(i - 4) % variations.count]
                config.mutationRate = baseConfig.mutationRate * v.mutMul
                config.crossoverRate = v.xRate
                config.selectionStrategy = v.sel
            }
            configs.append(config)
        }

        return configs
    }
}
