import Foundation

// MARK: - Selection Strategy

public enum SelectionStrategy: Sendable {
    case tournament(size: Int)
    case roulette
    case rank
    case stochasticUniversalSampling
}

// MARK: - Selection

/// Selects individuals from a population for reproduction.
///
/// Every entry point threads a `GARandom` so that selection pressure is
/// reproducible across runs with the same seed. Call sites that previously
/// used `Double.random`/`Int.random` implicitly now pass `context.rng`.
public enum Selection {

    /// Select one individual using the given strategy.
    public static func select<C: Chromosome>(
        from population: Population<C>,
        strategy: SelectionStrategy = .tournament(size: 3),
        rng: GARandom
    ) -> C {
        population.individuals[selectIndex(from: population, strategy: strategy, rng: rng)]
    }

    /// Select a pair of parents. Avoids returning the same *index* twice so that
    /// genetically-identical but physically-distinct individuals can still mate
    /// (two clones are fine, two pointers to the same slot are not — this also
    /// keeps crowding replacement correct when duplicates exist in the population).
    public static func selectPair<C: Chromosome>(
        from population: Population<C>,
        strategy: SelectionStrategy = .tournament(size: 3),
        rng: GARandom
    ) -> (C, C) {
        let pair = selectPairIndices(from: population, strategy: strategy, rng: rng)
        return (population.individuals[pair.0], population.individuals[pair.1])
    }

    /// Index-based variant: returns distinct indices into `population.individuals`.
    /// Used by crowding replacement where parent identity by index matters (Equatable
    /// lookup is ambiguous when duplicates exist or when fitness was adjusted).
    public static func selectPairIndices<C: Chromosome>(
        from population: Population<C>,
        strategy: SelectionStrategy = .tournament(size: 3),
        rng: GARandom
    ) -> (Int, Int) {
        guard !population.individuals.isEmpty else {
            fatalError("Cannot select from empty population")
        }
        if population.individuals.count == 1 { return (0, 0) }

        let i = selectIndex(from: population, strategy: strategy, rng: rng)
        var j = selectIndex(from: population, strategy: strategy, rng: rng)
        var attempts = 0
        while j == i && attempts < 5 {
            j = selectIndex(from: population, strategy: strategy, rng: rng)
            attempts += 1
        }
        // Final fallback: step to a neighbouring slot if we still collided
        // (e.g. degenerate single-fitness population).
        if j == i {
            j = (i + 1) % population.individuals.count
        }
        return (i, j)
    }

    /// Select one individual and return its index in `population.individuals`.
    public static func selectIndex<C: Chromosome>(
        from population: Population<C>,
        strategy: SelectionStrategy,
        rng: GARandom
    ) -> Int {
        switch strategy {
        case .tournament(let size):
            return tournamentSelectIndex(from: population, tournamentSize: size, rng: rng)
        case .roulette:
            return rouletteSelectIndex(from: population, rng: rng)
        case .rank:
            return rankSelectIndex(from: population, rng: rng)
        case .stochasticUniversalSampling:
            return susSelectIndex(from: population, rng: rng)
        }
    }

    // MARK: - Tournament Selection

    private static func tournamentSelectIndex<C: Chromosome>(
        from population: Population<C>,
        tournamentSize: Int,
        rng: GARandom
    ) -> Int {
        let n = population.individuals.count
        guard n > 0 else { fatalError("Cannot select from empty population") }
        var bestIdx = rng.int(in: 0..<n)
        var bestFit = population.individuals[bestIdx].fitness
        for _ in 1..<max(1, tournamentSize) {
            let idx = rng.int(in: 0..<n)
            let fit = population.individuals[idx].fitness
            if fit > bestFit {
                bestFit = fit
                bestIdx = idx
            }
        }
        return bestIdx
    }

    // MARK: - Roulette Wheel Selection

    private static func rouletteSelectIndex<C: Chromosome>(
        from population: Population<C>,
        rng: GARandom
    ) -> Int {
        let n = population.individuals.count
        guard n > 0 else { fatalError("Cannot select from empty population") }
        let minFitness = population.individuals.map(\.fitness).min() ?? 0
        let shifted = population.individuals.map { $0.fitness - minFitness + 1e-6 }
        let totalFitness = shifted.reduce(0, +)
        guard totalFitness > 0 else { return rng.int(in: 0..<n) }

        var random = rng.double(in: 0..<totalFitness)
        for (i, fitness) in shifted.enumerated() {
            random -= fitness
            if random <= 0 { return i }
        }
        return n - 1
    }

    // MARK: - Rank Selection

    private static func rankSelectIndex<C: Chromosome>(
        from population: Population<C>,
        rng: GARandom
    ) -> Int {
        let n = population.individuals.count
        guard n > 0 else { fatalError("Cannot select from empty population") }

        // Build original-index ordering sorted by fitness descending so that
        // we can return the canonical slot in `population.individuals`.
        let orderedIndices = population.individuals.indices.sorted {
            population.individuals[$0].fitness > population.individuals[$1].fitness
        }
        let totalRank = (1...n).reduce(0, +)
        var random = rng.int(in: 0..<totalRank)

        for (pos, originalIdx) in orderedIndices.enumerated() {
            let rank = n - pos
            random -= rank
            // Strict `<`: the draw is 0-based, so position `pos` owns
            // the half-open bucket of `rank` values. `<= 0` shifted
            // every boundary by one — the top individual absorbed an
            // extra unit of probability and the bottom-ranked one's
            // selection probability was exactly zero (n=2 degenerated
            // to always-pick-best).
            if random < 0 { return originalIdx }
        }
        return orderedIndices.last ?? 0
    }

    // MARK: - Stochastic Universal Sampling

    /// SUS provides more uniform sampling pressure than roulette wheel.
    /// Uses evenly spaced pointers on the fitness-proportional wheel,
    /// reducing selection bias and variance.
    private static func susSelectIndex<C: Chromosome>(
        from population: Population<C>,
        rng: GARandom
    ) -> Int {
        let n = population.individuals.count
        guard n > 0 else { fatalError("Cannot select from empty population") }
        let minFitness = population.individuals.map(\.fitness).min() ?? 0
        let shifted = population.individuals.map { $0.fitness - minFitness + 1e-6 }
        let totalFitness = shifted.reduce(0, +)
        guard totalFitness > 0 else { return rng.int(in: 0..<n) }

        let spacing = totalFitness / Double(n)
        let start = rng.double(in: 0..<spacing)
        let pointerIndex = rng.int(in: 0..<n)
        let pointer = start + spacing * Double(pointerIndex)

        var cumulative = 0.0
        for (i, fitness) in shifted.enumerated() {
            cumulative += fitness
            if cumulative >= pointer { return i }
        }
        return n - 1
    }
}
