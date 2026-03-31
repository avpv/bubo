import Foundation

// MARK: - Selection Strategy

enum SelectionStrategy {
    case tournament(size: Int)
    case roulette
    case rank
}

// MARK: - Selection

/// Selects individuals from a population for reproduction.
enum Selection {

    /// Select one individual using the given strategy.
    static func select<C: Chromosome>(
        from population: Population<C>,
        strategy: SelectionStrategy = .tournament(size: 3)
    ) -> C {
        switch strategy {
        case .tournament(let size):
            return tournamentSelect(from: population, tournamentSize: size)
        case .roulette:
            return rouletteSelect(from: population)
        case .rank:
            return rankSelect(from: population)
        }
    }

    /// Select a pair of parents.
    static func selectPair<C: Chromosome>(
        from population: Population<C>,
        strategy: SelectionStrategy = .tournament(size: 3)
    ) -> (C, C) {
        let parent1 = select(from: population, strategy: strategy)
        var parent2 = select(from: population, strategy: strategy)
        // Try to avoid selecting the same individual
        var attempts = 0
        while parent2 == parent1 && attempts < 5 {
            parent2 = select(from: population, strategy: strategy)
            attempts += 1
        }
        return (parent1, parent2)
    }

    // MARK: - Tournament Selection

    private static func tournamentSelect<C: Chromosome>(
        from population: Population<C>,
        tournamentSize: Int
    ) -> C {
        let candidates = (0..<tournamentSize).compactMap { _ -> C? in
            population.individuals.randomElement()
        }
        return candidates.max(by: { $0.fitness < $1.fitness }) ?? population.individuals[0]
    }

    // MARK: - Roulette Wheel Selection

    private static func rouletteSelect<C: Chromosome>(from population: Population<C>) -> C {
        let minFitness = population.individuals.map(\.fitness).min() ?? 0
        let shifted = population.individuals.map { $0.fitness - minFitness + 1e-6 }
        let totalFitness = shifted.reduce(0, +)
        guard totalFitness > 0 else {
            return population.individuals.randomElement() ?? population.individuals[0]
        }

        var random = Double.random(in: 0..<totalFitness)
        for (i, fitness) in shifted.enumerated() {
            random -= fitness
            if random <= 0 {
                return population.individuals[i]
            }
        }
        return population.individuals.last ?? population.individuals[0]
    }

    // MARK: - Rank Selection

    private static func rankSelect<C: Chromosome>(from population: Population<C>) -> C {
        let sorted = population.sortedByFitness
        let totalRank = (1...sorted.count).reduce(0, +)
        var random = Int.random(in: 0..<totalRank)

        for (i, individual) in sorted.enumerated() {
            let rank = sorted.count - i
            random -= rank
            if random <= 0 {
                return individual
            }
        }
        return sorted.first ?? population.individuals[0]
    }
}
