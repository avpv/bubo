import Foundation

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
// Visibility is `internal` (default) so the sibling
// `IslandModelGA+Migration.swift` extension can name `Island<C>` in
// signatures of `migrate(islands:migrationSize:)` and friends. The
// class is still effectively private to the island-model
// implementation — no public surface escapes.
public final class Island<C: Chromosome> {
    public var population: Population<C>
    public let ga: GeneticAlgorithm<C>
    public let context: OptimizerContext
    public var bestEver: C?

    public init(population: Population<C>, ga: GeneticAlgorithm<C>, context: OptimizerContext) {
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
public final class IslandModelGA<C: Chromosome>: @unchecked Sendable {
    public let islandConfig: IslandConfiguration
    public let baseConfig: GAConfiguration
    public let context: OptimizerContext
    private let evaluate: (inout C) -> Void
    private var onProgress: ((IslandModelProgress) -> Void)?
    private let multiObjective: MultiObjectiveContext<C>?

    /// Generic hook bundle forwarded to every per-island `GeneticAlgorithm`.
    /// Schedule-specific concerns (QD archive feeding, gradient
    /// refinement) are wired here by the host without leaking schedule
    /// types into the engine.
    public let hooks: EvolutionHooks<C>

    /// Externally-supplied warm-start chromosomes (temporal replay,
    /// GNN-driven greedy, …). Distributed round-robin across islands
    /// during initial population construction, replacing the same
    /// number of random individuals so total population size is
    /// preserved. Empty by default — the legacy seed mix is unchanged.
    public let extraSeeds: [C]

    /// CP-SAT construction anchor. When set, every island starts with
    /// a cloud of near-copies built by `anchorReplicationFraction` of
    /// the population — each copy is the anchor with a light mutation
    /// applied — plus the usual mix of greedy / random for diversity.
    /// `BuboOptimizer.optimize` populates this after calling
    /// `ScheduleChromosome.cpSeeded`; passing `nil` preserves the
    /// pre-anchor behaviour where greedy + random fill every slot.
    public let anchorSeed: C?

    /// Fraction of each island's initial population that is seeded
    /// as a mutated copy of `anchorSeed` when present. Above this
    /// the island would converge to identical copies of the anchor
    /// and lose soft-tier exploration; below it the anchor's
    /// near-optimum doesn't get enough local sampling to matter.
    /// Only consulted when `anchorSeed != nil`.
    public let anchorReplicationFraction: Double

    /// Optional batch evaluator propagated into every per-island
    /// `GeneticAlgorithm`. Enables the multi-fidelity funnel path
    /// where a surrogate ranks the offspring array and only the top
    /// fraction gets a real evaluation. nil = each inner GA evaluates
    /// offspring one-by-one using its per-chromosome `evaluate`.
    public let batchEvaluate: ((inout [C]) -> Void)?

    private(set) var bestEver: C?
    private(set) var convergenceGeneration: Int = 0

    public init(
        islandConfig: IslandConfiguration = .default,
        baseConfig: GAConfiguration = .thorough,
        context: OptimizerContext,
        evaluate: @escaping (inout C) -> Void,
        onProgress: ((IslandModelProgress) -> Void)? = nil,
        multiObjective: MultiObjectiveContext<C>? = nil,
        hooks: EvolutionHooks<C> = .noop,
        extraSeeds: [C] = [],
        anchorSeed: C? = nil,
        anchorReplicationFraction: Double = 0.4,
        batchEvaluate: ((inout [C]) -> Void)? = nil
    ) {
        self.islandConfig = islandConfig
        self.baseConfig = baseConfig
        self.context = context
        self.evaluate = evaluate
        self.onProgress = onProgress
        self.multiObjective = multiObjective
        self.hooks = hooks
        self.extraSeeds = extraSeeds
        self.anchorSeed = anchorSeed
        self.anchorReplicationFraction = max(0, min(0.8, anchorReplicationFraction))
        self.batchEvaluate = batchEvaluate
    }

    // MARK: - Run

    /// Run the island model GA and return the combined final population (sorted by fitness).
    public func run() throws -> [C] {
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
        // Distribute extraSeeds round-robin across islands. Each
        // island's allotted seed slice replaces the same number of
        // random individuals so total population size is preserved.
        let seedsPerIsland: [[C]] = {
            guard !extraSeeds.isEmpty else {
                return Array(repeating: [], count: islandConfigs.count)
            }
            var buckets: [[C]] = Array(repeating: [], count: islandConfigs.count)
            for (i, seed) in extraSeeds.enumerated() {
                buckets[i % buckets.count].append(seed)
            }
            return buckets
        }()
        let islands = islandConfigs.enumerated().map { (idx, config) -> Island<C> in
            let islandContext = makeIslandContext(islandIndex: idx)
            let warmSeedSlice = seedsPerIsland[idx]

            // Anchor-replication: when CP-SAT has delivered an
            // anchor, reserve a slice of the population for
            // mutated copies of it. This is the "polish" basin —
            // every copy starts at the lex-optimum and the low-rate
            // mutation samples its immediate soft-tier neighbourhood.
            // Remaining slots split across greedy variants + random
            // for exploration, same as before.
            let anchorCount: Int
            if anchorSeed != nil {
                anchorCount = max(0, Int(Double(config.populationSize) * anchorReplicationFraction))
            } else {
                anchorCount = 0
            }
            // Budget after anchor takes its share. Greedy and random
            // fractions apply to the remainder.
            let postAnchorBudget = max(0, config.populationSize - anchorCount)
            let greedyCount = max(0, Int(Double(postAnchorBudget) * config.greedySeedFraction))
            let warmCount = min(warmSeedSlice.count, max(0, postAnchorBudget - greedyCount))
            let randomCount = max(0, postAnchorBudget - greedyCount - warmCount)

            var individuals: [C] = []
            // First: the anchor itself (unmutated) and its mutated
            // copies. The first entry is the untouched anchor so the
            // GA's elitism can't lose the lex-optimum to a bad
            // crossover on the very first generation.
            if let anchor = anchorSeed, anchorCount > 0 {
                individuals.append(anchor)
                for i in 1..<anchorCount {
                    var copy = anchor
                    // Gentle perturbation so the initial cloud
                    // samples a tight neighbourhood — rate scales
                    // very slowly with i so the tail is still close
                    // to the anchor rather than becoming random.
                    let rate = 0.04 + Double(i) * 0.01
                    copy.mutate(rate: min(0.25, rate), context: islandContext)
                    individuals.append(copy)
                }
            }
            individuals.append(contentsOf: warmSeedSlice.prefix(warmCount))
            for i in 0..<greedyCount {
                // Island index folds into the variant key so every
                // island starts with its own rotation of greedy
                // strategies (priority-first, deadline-first,
                // short-first, long-first). Previously every greedy
                // seed was the default sort, so the 30-50% "greedy"
                // share of each population was really 1 unique
                // individual × N copies. Now the seeds genuinely
                // span multiple basins.
                let variantKey = idx * 7 + i
                var ind = C.greedy(context: islandContext, variantIndex: variantKey)
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
                hooks: hooks,
                batchEvaluate: batchEvaluate
            )
            return Island(population: pop, ga: ga, context: islandContext)
        }

        return try evolveIslands(islands)
    }

    /// Build a fresh `OptimizerContext` for a single island, sharing everything
    /// except the random-number generator with the parent. `split()` is called
    /// on the parent RNG in the order islands are created, so the sequence is
    /// deterministic — island 0 gets the first split, island 1 the second, etc.
    ///
    /// Build a per-island `OptimizerContext`. RNG is split for
    /// thread-safe parallel evolution; reproducible under a fixed
    /// top-level seed because `split()` advances deterministically in
    /// island-creation order.
    ///
    /// Every island shares `context.mutationBandit` — the federated
    /// variant was retired when the persistent-feedback path proved
    /// to work better on realistic workloads than per-island merges.
    private func makeIslandContext(islandIndex: Int) -> OptimizerContext {
        let bandit = context.mutationBandit

        // Per-island objective-weight biasing. When
        // `islandConfig.objectiveWeightBiases` carries an entry for
        // this island, clone the baseline preferences and multiply
        // each named objective's weight by the supplied factor.
        // Missing names leave the baseline weight untouched, so the
        // bias dict can be sparse (e.g. `["Conflict": 1.5]`).
        // Islands without a bias entry get the un-touched baseline.
        let preferences = biasedPreferences(for: islandIndex)

        // Give each island its own CPSATRepairer. The repairer's
        // `solve()` resets shared `noGoods` / `variableActivity` /
        // `runNodes` at the start of every call and `depthFirst` /
        // `orderVariables` read those same dictionaries from inside
        // the DFS without holding the repairer's lock — concurrent
        // solves from `evolveIslands`'s `concurrentPerform` therefore
        // race on a Dictionary's COW buffer and crash with
        // EXC_BAD_ACCESS inside `Collection.map`. The state machine
        // is per-solve anyway (no learning is preserved across calls),
        // so each island can own a fresh instance with no behavioural
        // difference vs. the sharing it replaces.
        let perIslandRepairer = context.cpSATRepairer.map {
            CPSATRepairer(config: $0.config)
        }

        return OptimizerContext(
            fixedEvents: context.fixedEvents,
            movableEvents: context.movableEvents,
            workingHours: context.workingHours,
            planningHorizon: context.planningHorizon,
            preferences: preferences,
            participantAvailability: context.participantAvailability,
            calendar: context.calendar,
            rng: context.rng.split(),
            mutationBandit: bandit,
            // Share one strategy bandit across islands so ALNS weight
            // updates accumulate globally — same sharing pattern as the
            // non-federated mutationBandit path.
            lnsStrategyBandit: context.lnsStrategyBandit,
            lnsRepairBandit: context.lnsRepairBandit,
            contextualCrossoverHead: context.contextualCrossoverHead,
            conflictGraphHolder: context.conflictGraphHolder,
            tabuMemory: context.tabuMemory,
            cpSATRepairer: perIslandRepairer,
            cpSATWindowThreshold: context.cpSATWindowThreshold,
            slotRegistryHolder: context.slotRegistryHolder,
            slotDomainsHolder: context.slotDomainsHolder
        )
    }

    /// Compute the preferences for one island — baseline + any per-
    /// island multiplicative bias on objective weights configured in
    /// `islandConfig.objectiveWeightBiases`. Missing / empty biases
    /// reduce to `context.preferences` unchanged.
    ///
    /// Objectives whose names appear in the bias dict are scaled
    /// multiplicatively; unknown names are silently ignored (keeps
    /// the dict tolerant of string-level typos without breaking the
    /// run). Weights are clamped to `>= 0` so a negative bias can't
    /// accidentally turn an objective adversarial.
    private func biasedPreferences(for islandIndex: Int) -> OptimizerPreferences {
        guard let biasMap = islandConfig.objectiveWeightBiases?[islandIndex],
              !biasMap.isEmpty else {
            return context.preferences
        }
        var prefs = context.preferences
        for (name, factor) in biasMap {
            let clampedFactor = max(0, factor)
            switch name {
            case "FocusBlock":         prefs.focusBlockWeight *= clampedFactor
            case "PomodoroFit":        prefs.pomodoroFitWeight *= clampedFactor
            case "Conflict":           prefs.conflictWeight *= clampedFactor
            case "TaskPlacement":      prefs.taskPlacementWeight *= clampedFactor
            case "WeekBalance":        prefs.weekBalanceWeight *= clampedFactor
            case "EnergyBalance":      prefs.energyCurveWeight *= clampedFactor
            case "MultiPerson":        prefs.multiPersonWeight *= clampedFactor
            case "BreakPlacement":     prefs.breakWeight *= clampedFactor
            case "Deadline":           prefs.deadlineWeight *= clampedFactor
            case "ContextSwitch":      prefs.contextSwitchWeight *= clampedFactor
            case "Buffer":             prefs.bufferWeight *= clampedFactor
            case "MeetingClustering":  prefs.meetingClusteringWeight *= clampedFactor
            case "TaskInclusion":      prefs.taskInclusionWeight *= clampedFactor
            case "BacklogOrder":
                let base = prefs.backlogOrderWeight ?? OptimizerPreferences.defaultBacklogOrderWeight
                prefs.backlogOrderWeight = base * clampedFactor
            case "DayCompactness":
                let base = prefs.dayCompactnessWeight ?? OptimizerPreferences.defaultDayCompactnessWeight
                prefs.dayCompactnessWeight = base * clampedFactor
            default:
                // Unknown name — ignore silently so the bias dict can
                // evolve independently of the objective list.
                break
            }
        }
        return prefs
    }

    // MARK: - Run Seeded

    /// Run the island model GA seeded with existing individuals (for warm-start re-optimization).
    /// Seeds are distributed across islands round-robin so every island gets warm-start
    /// material. Remaining slots per island are filled with random individuals.
    public func runSeeded(with seed: [C]) throws -> [C] {
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
            let islandContext = makeIslandContext(islandIndex: idx)
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
                hooks: hooks,
                batchEvaluate: batchEvaluate
            )
            return Island(population: pop, ga: ga, context: islandContext)
        }

        return try evolveIslands(islands)
    }

    // MARK: - Core Evolution Loop

    /// Shared evolution loop for both `run()` and `runSeeded(with:)`.
    private func evolveIslands(_ islands: [Island<C>]) throws -> [C] {
        bestEver = islands.compactMap(\.bestEver).max(by: { $0.rawFitness < $1.rawFitness })

        let totalGenerations = baseConfig.maxGenerations
        var globalStaleGenerations = 0
        var lastGlobalBestFitness = bestEver?.rawFitness ?? 0
        var totalMigrations = 0
        // Global plateau detector — see GeneticAlgorithm.evolve for
        // rationale. Window is half `convergencePatience +
        // migrationInterval` so migrations still have a chance to
        // revive islands before termination fires, but the detector
        // exits ~2× faster than the counter alone once every island
        // has genuinely stagnated.
        var globalPlateauDetector = FitnessPlateauDetector(
            capacity: max(3, (baseConfig.convergencePatience + islandConfig.migrationInterval) / 2)
        )
        globalPlateauDetector.push(lastGlobalBestFitness)

        // Adaptive migration state
        var effectiveInterval = islandConfig.migrationInterval
        var effectiveSize = islandConfig.migrationSize
        var lastCrossDiversity: CrossIslandDiversity?
        let wallclockStart = Date()

        for generation in 0..<totalGenerations {
            // Cooperative cancellation — UI can stop a long `.thorough`
            // run between generations. `bestEver` is already kept up to
            // date so callers catching `CancellationError` get whatever
            // was found before interruption.
            try Task.checkCancellation()

            // Wallclock ceiling — soft deadline. Checked between
            // generations, after the previous one fully committed
            // (islands evolved + migration applied + bestEver updated),
            // so breaking here never leaves a migration round in-flight
            // or island populations mid-update. The post-loop hill
            // climb scales its effort to remaining budget.
            if baseConfig.wallclockTimeout > 0 &&
                Date().timeIntervalSince(wallclockStart) >= baseConfig.wallclockTimeout {
                convergenceGeneration = generation
                break
            }

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
            globalPlateauDetector.push(currentGlobalBest)

            // Primary termination: plateau detector. See
            // GeneticAlgorithm.evolve for why this sees through the
            // cache-driven jitter that kept globalStaleGenerations
            // from triggering on genuinely stagnant runs.
            if globalPlateauDetector.isPlateau {
                convergenceGeneration = generation - globalPlateauDetector.capacity + 1
                break
            }

            // Fallback: legacy counter-based termination, kept so
            // pathological cases (fitness oscillating just above the
            // relative threshold every other generation) still exit.
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
        //
        // Step count is budget-aware: when the evolution loop exited
        // via the wallclock break, we still climb but with fewer steps
        // so the total wall time stays bounded. Mirrors the logic in
        // `GeneticAlgorithm.evolve`.
        combined.sort { $0.rawFitness > $1.rawFitness }
        let refineCount = min(baseConfig.eliteCount * 2, combined.count)
        let refiner = islands[0].ga
        let climbSteps: Int = {
            guard baseConfig.wallclockTimeout > 0 else { return 20 }
            let remaining = baseConfig.wallclockTimeout - Date().timeIntervalSince(wallclockStart)
            let budgetRatio = remaining / baseConfig.wallclockTimeout
            if budgetRatio >= 0.25 { return 20 }
            if budgetRatio >= 0.0 { return 8 }
            return 3
        }()
        for i in 0..<refineCount {
            combined[i] = refiner.hillClimb(combined[i], steps: climbSteps)
        }

        // Update bestEver after hill climbing (by rawFitness).
        if let refined = combined.max(by: { $0.rawFitness < $1.rawFitness }),
           bestEver == nil || refined.rawFitness > bestEver!.rawFitness {
            bestEver = refined
        }

        return combined.sorted { $0.rawFitness > $1.rawFitness }
    }


}
