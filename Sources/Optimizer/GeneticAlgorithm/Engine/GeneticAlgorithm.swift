import Foundation


// MARK: - Genetic Algorithm Engine

/// The core genetic algorithm engine, generic over chromosome type.
/// Thread safety: instances are created and used within a single Task.detached block.
public final class GeneticAlgorithm<C: Chromosome>: @unchecked Sendable {
    public let config: GAConfiguration
    public let context: OptimizerContext
    // Internal (was `private`) so the evolution-helper extensions in
    // sibling files (`+EvolutionHelpers.swift`) can call the per-
    // chromosome evaluator the host wired up.
    public let evaluate: (inout C) -> Void

    /// Optional batch evaluator. When present, offspring are scored
    /// with this closure in one shot instead of the per-chromosome
    /// loop. Lets the caller install a multi-fidelity funnel
    /// (surrogate tier + promoted tier-2 full evaluation) without
    /// per-individual overhead. When nil the engine falls back to
    /// the per-chromosome `evaluate` closure.
    private let batchEvaluate: ((inout [C]) -> Void)?

    private var onProgress: ((GAProgress) -> Void)?
    // Internal (was `private`) so `objectiveImbalance(in:)` in
    // `GeneticAlgorithm+BanditFeatures.swift` can read the configured
    // multi-objective hook to compute the bandit-context imbalance signal.
    public let multiObjective: MultiObjectiveContext<C>?

    /// Generic hook closures for QD archive feeding, gradient
    /// refinement, telemetry — anything outside the engine's core
    /// evolution logic. Closures are constructed by the caller and
    /// captured by reference to schedule-specific state (archives,
    /// refiners) without leaking those types into the engine.
    public let hooks: EvolutionHooks<C>

    private(set) var bestEver: C?
    private(set) var convergenceGeneration: Int = 0

    public init(
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
    public func run() throws -> [C] {
        var population = createInitialPopulation()
        return try evolve(&population)
    }

    /// Run the GA seeded with an existing population. Same cancellation
    /// semantics as `run()`.
    public func runSeeded(with seed: [C]) throws -> [C] {
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
        // Plateau detector sees through cache-driven fitness jitter
        // that used to reset the `staleGenerations` counter. Window is
        // half the patience so termination fires ~2× earlier than the
        // counter alone once the GA is genuinely done. Minimum 3 so
        // near-instant configs still have meaningful variance
        // measurement.
        var plateauDetector = FitnessPlateauDetector(
            capacity: max(3, config.convergencePatience / 2)
        )
        plateauDetector.push(lastBestFitness)

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
            plateauDetector.push(currentFitness)

            // Termination: the plateau detector decides first. It sees
            // through the cache-driven fitness jitter that keeps the
            // stale-counter bouncing to zero on chromosomes whose
            // fitness is recomputed from cache with microscopic
            // floating-point variance — generations where "nothing
            // really changed" used to reset the counter and let the
            // GA burn through wallclock chasing phantom improvements.
            if plateauDetector.isPlateau {
                // Clamp: the detector's window fills before generation
                // == capacity (one pre-loop push), so an instant
                // plateau would otherwise report generation -1.
                convergenceGeneration = max(0, generation - plateauDetector.capacity + 1)
                break
            }

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
                    // The post-restart population is a new search
                    // basin — let the detector re-fill its window
                    // against the fresh trajectory instead of
                    // immediately re-triggering on the pre-restart
                    // plateau.
                    plateauDetector.reset()
                    // Don't reset convergenceGeneration; the reported value
                    // should still reflect when the bestEver was last
                    // improved, not when we decided to relaunch.
                    continue
                }
                convergenceGeneration = max(0, generation - config.convergencePatience)
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

        var final = sorted.sorted { $0.rawFitness > $1.rawFitness }
        // Guarantee the returned population still contains the best
        // schedule ever found. NSGA-III survivor niching can truncate a
        // crowded front 0 and drop the top-rawFitness individual (the
        // fitnessDrop warning above detects exactly this) — and the
        // consumer builds the user-facing scenario archive from this
        // return value only, so a lost bestEver would silently exclude
        // the best schedule from the offered set. Replace the worst
        // survivor rather than append, keeping the population size the
        // caller expects.
        if let best = bestEver {
            if final.isEmpty {
                final = [best]
            } else if best.rawFitness > final[0].rawFitness + 1e-9 {
                final[final.count - 1] = best
                final.sort { $0.rawFitness > $1.rawFitness }
            }
        }
        return final
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
    public func evolveOneGeneration(
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
        // Kept as a local so the reward `record` below pairs rewards
        // with THIS island's generation context — the shared bandit's
        // internal context may be overwritten by a concurrently
        // evolving island between here and the record call.
        let banditContext = BanditContext(
            diversity: min(1.0, genotypicDiv / max(1e-6, config.diversityThreshold * 4)),
            stagnation: stagnation,
            imbalance: imbalance,
            precedenceViolationRate: graphFeatures.precedenceViolationRate,
            conflictDensity: graphFeatures.conflictDensity,
            maxChainDepth: graphFeatures.maxChainDepth
        )
        context.mutationBandit.updateContext(banditContext)

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
            context.mutationBandit.record(op: op, reward: reward, context: banditContext)

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

            // MOEA/D-AWA survivor alternative was retired — NSGA-III
            // with HypE-lite tiebreak is the sole multi-objective
            // survivor path now.
            do {
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


}
