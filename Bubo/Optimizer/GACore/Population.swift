import Foundation

// MARK: - Population

/// Manages a population of chromosomes with elitism support.
struct Population<C: Chromosome> {
    var individuals: [C]
    let eliteCount: Int

    var size: Int { individuals.count }

    var best: C? { individuals.max(by: { $0.fitness < $1.fitness }) }

    var averageFitness: Double {
        guard !individuals.isEmpty else { return 0 }
        return individuals.reduce(0.0) { $0 + $1.fitness } / Double(individuals.count)
    }

    var sortedByFitness: [C] {
        individuals.sorted { $0.fitness > $1.fitness }
    }

    /// The elite individuals (top N by fitness).
    var elites: [C] {
        Array(sortedByFitness.prefix(eliteCount))
    }

    init(size: Int, eliteCount: Int = 2, context: OptimizerContext) {
        self.eliteCount = eliteCount
        self.individuals = (0..<size).map { _ in C.random(context: context) }
    }

    init(individuals: [C], eliteCount: Int = 2) {
        self.eliteCount = eliteCount
        self.individuals = individuals
    }

    /// Replace the population with a new generation, preserving elites.
    mutating func replaceGeneration(with newIndividuals: [C]) {
        let currentElites = elites
        var next = currentElites
        // Fill remaining slots from new individuals
        let remaining = size - currentElites.count
        next.append(contentsOf: newIndividuals.prefix(remaining))
        // If we still don't have enough, pad with random picks from newIndividuals to maintain diversity
        while next.count < size, !newIndividuals.isEmpty {
            next.append(newIndividuals.randomElement()!)
        }
        individuals = next
    }

    /// Evaluate all individuals using the given fitness function.
    mutating func evaluateAll(using evaluate: (inout C) -> Void) {
        for i in individuals.indices {
            evaluate(&individuals[i])
        }
    }

    // MARK: - Diversity

    /// Measure population diversity as the standard deviation of fitness values.
    var fitnessDiversity: Double {
        guard individuals.count > 1 else { return 0 }
        let avg = averageFitness
        let variance = individuals.reduce(0.0) { $0 + pow($1.fitness - avg, 2) } / Double(individuals.count - 1)
        return sqrt(variance)
    }
}
