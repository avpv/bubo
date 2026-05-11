import Foundation

// MARK: - IslandModelGA migration (inter-island gene flow)
//
// At every `migrationInterval` generation, a fixed number of top
// individuals are *copied* (not moved) from each source island to a
// destination island chosen by the configured topology. The mechanism
// is standard island-model GA fare; the variation here is:
//
//   • `routeByProductivity` — re-orient each topology pair so the more-
//     productive island is always the source. Diversity gradient flows
//     downhill instead of uphill.
//   • `selectParetoEmigrants` — when `MultiObjectiveContext` is wired
//     in, the emigrant pool is biased toward the NSGA-III front-0 set
//     so receiving islands see the current Pareto frontier, not just
//     the scalar-fitness elite.
//   • `insertImmigrants` — replacement strategy follows
//     `ImmigrantReplacement`: random, worst-K, or scalar-fitness
//     tournament.
//
// Extracted from `IslandModelGA.swift`; visibility on the entry-point
// `migrate(...)` was relaxed from `private` to `internal` so the Core
// Evolution Loop in the main file can call it. The four helpers
// (`makeMigrationPairs`, `selectEmigrants`, `selectParetoEmigrants`,
// `insertImmigrants`) stay private inside this file — they're called
// only from `migrate` here.

extension IslandModelGA {

    // MARK: - Migration

    /// Transfer individuals between islands according to the configured topology.
    /// Emigrants are copied (not removed) from the source, mirroring standard
    /// island model GA semantics.
    func migrate(islands: [Island<C>], migrationSize: Int) {
        let n = islands.count
        guard n > 1 else { return }

        // Pre-migration best-fitness snapshot per island, used to
        // reward the migration bandit afterwards.
        let preFitness: [Double] = islands.map { $0.bestEver?.rawFitness ?? 0 }

        // Static topology pairing — the UCB migration-bandit was
        // retired when adaptive migration-interval alone matched its
        // wins without the per-generation update cost.
        var migrationPairs: [(source: Int, destination: Int)] = makeMigrationPairs(islandCount: n)
        _ = preFitness

        // Productivity routing: for each pair, ensure the source is the
        // more-productive endpoint so flow runs down the fitness
        // gradient. Topology graph is preserved (the *same* islands
        // exchange); only who sends to whom flips when the pair is
        // oriented against the gradient.
        if islandConfig.routeByProductivity {
            migrationPairs = migrationPairs.map { pair in
                let srcFit = islands[pair.source].bestEver?.rawFitness ?? 0
                let dstFit = islands[pair.destination].bestEver?.rawFitness ?? 0
                if dstFit > srcFit {
                    return (source: pair.destination, destination: pair.source)
                }
                return pair
            }
        }

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

        // Invalidate incoming fitness when islands have biased
        // preferences. An immigrant was evaluated under its sender
        // island's objective weights; on the receiving island those
        // weights may differ, so its cached `fitness` doesn't
        // describe how it ranks here. Clearing `needsEvaluation`
        // forces a full re-eval against the receiver's (biased)
        // preferences on the next generation, and survivor selection
        // stops confusing old-island bestness for new-island
        // bestness. When biases aren't configured every island shares
        // the exact same fitness landscape and the reset is a pure
        // cost — skip it.
        //
        // `needsEvaluation` is a `ScheduleChromosome`-specific flag
        // (not on the Chromosome protocol), so we cast; other
        // chromosome types don't pay any cost here.
        let immigrants: [C] = {
            guard islandConfig.objectiveWeightBiases != nil else { return immigrants }
            return immigrants.map { ind -> C in
                guard var schedule = ind as? ScheduleChromosome else { return ind }
                schedule.needsEvaluation = true
                schedule.isFitnessReal = false
                return (schedule as? C) ?? ind
            }
        }()

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
}
