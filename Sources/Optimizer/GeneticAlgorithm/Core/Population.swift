import Foundation

// MARK: - Population

/// Manages a population of chromosomes with elitism support.
public struct Population<C: Chromosome> {
    public var individuals: [C]
    public let eliteCount: Int

    public var size: Int { individuals.count }

    public var best: C? { individuals.max(by: { $0.fitness < $1.fitness }) }

    public var averageFitness: Double {
        guard !individuals.isEmpty else { return 0 }
        return individuals.reduce(0.0) { $0 + $1.fitness } / Double(individuals.count)
    }

    public var sortedByFitness: [C] {
        individuals.sorted { $0.fitness > $1.fitness }
    }

    /// The elite individuals (top N by fitness).
    public var elites: [C] {
        Array(sortedByFitness.prefix(eliteCount))
    }

    public init(size: Int, eliteCount: Int = 2, context: OptimizerContext) {
        self.eliteCount = eliteCount
        self.individuals = (0..<size).map { _ in C.random(context: context) }
    }

    public init(individuals: [C], eliteCount: Int = 2) {
        self.eliteCount = eliteCount
        self.individuals = individuals
    }

    /// Replace the population with a new generation, preserving elites.
    /// When `newIndividuals` underfills the population, padding falls back to
    /// duplicating offspring (diversity-neutral but collapses the population
    /// toward clones). Callers that need random refills should inject immigrants
    /// via `injectImmigrants` instead of relying on the padding path.
    public mutating func replaceGeneration(with newIndividuals: [C]) {
        let currentElites = elites
        var next = currentElites
        // Fill remaining slots from new individuals
        let remaining = size - currentElites.count
        next.append(contentsOf: newIndividuals.prefix(remaining))
        // Degenerate path: pad by repeating the best offspring rather than a
        // uniformly-random duplicate (which amplified whatever arrived first).
        // Sorted offspring guarantees determinism and keeps the higher-fitness
        // material around. Immigration is handled separately via
        // `injectImmigrants`; padding here is purely a safety net.
        if next.count < size && !newIndividuals.isEmpty {
            let sortedOffspring = newIndividuals.sorted { $0.fitness > $1.fitness }
            var i = 0
            while next.count < size {
                next.append(sortedOffspring[i % sortedOffspring.count])
                i += 1
            }
        }
        individuals = next
    }

    /// Evaluate all individuals using the given fitness function.
    /// Uses parallel evaluation when the population is large enough to benefit.
    /// Below the threshold, GCD's `concurrentPerform` dispatch cost
    /// exceeds the per-individual evaluation cost, so serial is faster.
    public mutating func evaluateAll(using evaluate: (inout C) -> Void) {
        let parallelThreshold = 32
        if individuals.count >= parallelThreshold {
            // Force the array into uniquely-referenced storage BEFORE
            // fanning out. `evaluate(&individuals[i])` from concurrent
            // threads is only safe when no copy-on-write can trigger:
            // if the buffer is shared (e.g. the caller still holds the
            // array it passed to `init(individuals:)`), every thread
            // that reaches the first mutation races the uniqueness
            // check, each installs its own copy, and each releases the
            // original buffer once — an over-release that malloc
            // reports as "double free" when the last owner deallocates.
            // `withUnsafeMutableBufferPointer` performs the
            // make-unique step exactly once, serially, then hands out
            // a stable base pointer the parallel loop can index
            // without ever touching the array's reference count.
            individuals.withUnsafeMutableBufferPointer { buffer in
                guard let base = buffer.baseAddress else { return }
                DispatchQueue.concurrentPerform(iterations: buffer.count) { i in
                    evaluate(&base[i])
                }
            }
        } else {
            for i in individuals.indices {
                evaluate(&individuals[i])
            }
        }
    }

    // MARK: - Diversity

    /// Measure population diversity as the standard deviation of fitness values.
    public var fitnessDiversity: Double {
        guard individuals.count > 1 else { return 0 }
        let avg = averageFitness
        let variance = individuals.reduce(0.0) { $0 + pow($1.fitness - avg, 2) } / Double(individuals.count - 1)
        return sqrt(variance)
    }

    /// Genotypic diversity: average pairwise distance between a sample of individuals.
    /// Uses the chromosome's `distance(to:)` method for genotype-level comparison.
    /// Sampled to O(sampleSize²) comparisons to avoid O(n²) cost for large populations.
    ///
    /// Pass the caller's `GARandom` so the sample (and therefore the diversity
    /// reading) is reproducible when the top-level seed is fixed. Without this,
    /// two runs with the same seed could diverge the first time diversity is
    /// low enough to trigger adaptive mutation or immigration.
    public func genotypicDiversity(rng: GARandom) -> Double {
        guard individuals.count > 1 else { return 0 }

        // Sample a subset for efficiency (max 20 individuals → 190 pairs)
        let sampleSize = min(20, individuals.count)
        let sample: [C]
        if sampleSize == individuals.count {
            sample = individuals
        } else {
            sample = Array(rng.shuffled(individuals).prefix(sampleSize))
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
    public mutating func injectImmigrants(count: Int, context: OptimizerContext, evaluate: (inout C) -> Void) {
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
