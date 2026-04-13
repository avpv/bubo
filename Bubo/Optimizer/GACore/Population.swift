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

    /// Deterministic crowding replacement: each child competes against the most
    /// similar parent rather than replacing a random individual. This naturally
    /// maintains population diversity by preserving distinct niches.
    ///
    /// After crossover (parent1, parent2) -> (child1, child2), each child competes
    /// with the parent closest to it in genotype space. The winner survives.
    mutating func replaceByCrowding(
        parents: [(C, C)],
        offspring: [(C, C)],
        distanceFn: (C, C) -> Double
    ) {
        let currentElites = elites
        var next = individuals

        for (parentPair, childPair) in zip(parents, offspring) {
            let (p1, p2) = parentPair
            let (c1, c2) = childPair

            // Determine pairing: which child is closer to which parent
            let d_c1p1 = distanceFn(c1, p1)
            let d_c1p2 = distanceFn(c1, p2)

            let (matchA, matchB): ((child: C, parent: C), (child: C, parent: C))
            if d_c1p1 + distanceFn(c2, p2) <= d_c1p2 + distanceFn(c2, p1) {
                matchA = (c1, p1)
                matchB = (c2, p2)
            } else {
                matchA = (c1, p2)
                matchB = (c2, p1)
            }

            // Each child competes with its matched parent
            for match in [matchA, matchB] {
                if match.child.fitness >= match.parent.fitness {
                    // Replace the parent in the population with the child
                    if let idx = next.firstIndex(where: { $0 == match.parent }) {
                        next[idx] = match.child
                    }
                }
            }
        }

        // Ensure elites survive regardless
        for elite in currentElites {
            if !next.contains(where: { $0 == elite }) {
                // Elite was replaced — put it back by replacing worst non-elite
                if let worstIdx = next.enumerated()
                    .filter({ !currentElites.contains(where: { e in e == $0.element }) })
                    .min(by: { $0.element.fitness < $1.element.fitness })?.offset {
                    next[worstIdx] = elite
                }
            }
        }

        individuals = next
    }

    /// Evaluate all individuals using the given fitness function.
    /// Uses parallel evaluation when the population is large enough to benefit.
    mutating func evaluateAll(using evaluate: (inout C) -> Void) {
        if individuals.count > 1 {
            DispatchQueue.concurrentPerform(iterations: individuals.count) { i in
                evaluate(&individuals[i])
            }
        } else {
            for i in individuals.indices {
                evaluate(&individuals[i])
            }
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

    /// Genotypic diversity: average pairwise distance between a sample of individuals.
    /// Uses the chromosome's `distance(to:)` method for genotype-level comparison.
    /// Sampled to O(sampleSize²) comparisons to avoid O(n²) cost for large populations.
    var genotypicDiversity: Double {
        guard individuals.count > 1 else { return 0 }

        // Sample a subset for efficiency (max 20 individuals → 190 pairs)
        let sampleSize = min(20, individuals.count)
        let sample: [C]
        if sampleSize == individuals.count {
            sample = individuals
        } else {
            sample = Array(individuals.shuffled().prefix(sampleSize))
        }

        var totalDistance = 0.0
        var pairCount = 0
        for i in 0..<sample.count {
            for j in (i + 1)..<sample.count {
                totalDistance += sample[i].distance(to: sample[j])
                pairCount += 1
            }
        }

        return pairCount > 0 ? totalDistance / Double(pairCount) : 0
    }

    // MARK: - Immigration

    /// Replace the worst individuals with random immigrants to restore diversity.
    /// Preserves elites — only replaces the bottom of the population.
    mutating func injectImmigrants(count: Int, context: OptimizerContext, evaluate: (inout C) -> Void) {
        let sorted = individuals.sorted { $0.fitness > $1.fitness }
        // Keep top individuals, replace worst with immigrants
        let keepCount = max(eliteCount, individuals.count - count)
        var next = Array(sorted.prefix(keepCount))
        let immigrantCount = individuals.count - keepCount
        for _ in 0..<immigrantCount {
            var immigrant = C.random(context: context)
            evaluate(&immigrant)
            next.append(immigrant)
        }
        individuals = next
    }
}
