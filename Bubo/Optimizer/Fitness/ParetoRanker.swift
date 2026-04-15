import Foundation

// MARK: - Pareto Ranker

/// NSGA-II-style non-dominated sorting and crowding distance assignment for a
/// population of schedule chromosomes.
///
/// Weighted-sum fitness (the default GA path) collapses 13 objectives into a
/// single scalar, so the GA converges on one point in objective space — good
/// when we want "the best plan," but unhelpful when the user wants "show me
/// the trade-offs: more focus vs. more buffer vs. more meetings clustered."
/// ParetoRanker re-scores a converged population by non-dominated fronts:
/// front 0 contains solutions that nothing dominates (Pareto-optimal for
/// this population), front 1 contains those dominated only by front 0, etc.
/// Within a front, crowding distance rewards solutions whose neighbours in
/// objective space are far away — i.e. the diverse, representative ones.
///
/// This is strictly a post-hoc mode. The GA itself still uses scalar fitness
/// for selection pressure (because NSGA-II per-generation would be O(n²) and
/// we'd lose the delta-eval / caching wins we just added). Call
/// `rankByParetoFronts` after `GeneticAlgorithm.run()` finishes to reorder
/// the final population along the Pareto frontier and surface alternatives.
struct ParetoRanker {

    /// Re-score `population` using NSGA-II. Fitness values are rewritten so
    /// that front 0 > front 1 > … and, within a front, higher crowding
    /// distance outranks lower. The GA's stored `rawFitness` is preserved
    /// as a tiebreaker via the input ordering — two solutions on the same
    /// front with equal crowding get their relative rawFitness order back.
    ///
    /// Objectives whose scores are already cached on the chromosome are
    /// read directly; unchanged chromosomes pay nothing. When the cache
    /// is missing (e.g. solutions that came in from outside), the evaluator
    /// recomputes the breakdown.
    static func rankByParetoFronts(
        _ population: inout [ScheduleChromosome],
        evaluator: FitnessEvaluator,
        context: OptimizerContext
    ) {
        guard population.count > 1 else { return }

        // Stable, deterministic objective ordering. Reading objective names
        // from `evaluator.objectives` keeps the vector layout in lock-step
        // with whatever objectives the evaluator is configured for.
        let objectiveNames = evaluator.objectives.map(\.name)

        // Extract one objective-score vector per individual. Prefer the
        // cached breakdown when available; fall back to a fresh evaluation
        // (`objectiveBreakdown`) so this works on populations that haven't
        // been fully evaluated through the normal path.
        let vectors: [[Double]] = population.map { chromosome -> [Double] in
            let cache: [String: Double]
            if let existing = chromosome.objectiveCache, !existing.isEmpty {
                cache = existing
            } else {
                cache = evaluator.objectiveBreakdown(for: chromosome, context: context)
            }
            return objectiveNames.map { cache[$0] ?? 0 }
        }

        let fronts = nonDominatedSort(vectors)

        // Map (front index, crowding distance) back to fitness so callers
        // that sort by `.fitness` descending get Pareto-correct order.
        // Front base spans equal slices of [0.01, 1.0]; within-front
        // crowding distance adds a small bonus so boundary-of-front
        // solutions score higher than crowded-interior ones.
        let frontCount = max(1, fronts.count)
        for (frontIndex, indices) in fronts.enumerated() {
            let frontBase = 1.0 - Double(frontIndex) / Double(frontCount)
            let frontWidth = 1.0 / Double(frontCount)

            let distances = crowdingDistance(indices: indices, vectors: vectors)
            let maxDist = distances.max() ?? 1.0
            let normFactor = (maxDist.isFinite && maxDist > 0) ? maxDist : 1.0

            for (localIdx, popIdx) in indices.enumerated() {
                let raw = distances[localIdx]
                let bonus: Double
                if raw.isFinite {
                    bonus = (raw / normFactor) * frontWidth * 0.9
                } else {
                    // Boundary solutions get the full front width bonus.
                    bonus = frontWidth * 0.9
                }
                // Clamp to [0.01, 1.0] so consumers that assume fitness > 0
                // still see positive values even for the worst front.
                let rescored = max(0.01, min(1.0, frontBase - frontWidth + bonus))
                population[popIdx].fitness = rescored
                population[popIdx].needsEvaluation = false
            }
        }
    }

    /// Partition `vectors` into non-dominated fronts, NSGA-II-style.
    /// Returns `[[index]]` with outer index = front rank, inner array =
    /// positions into the input that belong to that front.
    ///
    /// Complexity O(N² · M) where N = population size and M = objective
    /// count. Fine for post-hoc ranking (one call per run); not cheap
    /// enough to do every generation, which is why this runs after
    /// convergence rather than inside the GA loop.
    static func nonDominatedSort(_ vectors: [[Double]]) -> [[Int]] {
        let n = vectors.count
        guard n > 0 else { return [] }

        var dominationCount = [Int](repeating: 0, count: n)
        var dominated: [[Int]] = Array(repeating: [], count: n)
        var fronts: [[Int]] = []
        var currentFront: [Int] = []

        for i in 0..<n {
            for j in 0..<n where i != j {
                if dominates(vectors[i], vectors[j]) {
                    dominated[i].append(j)
                } else if dominates(vectors[j], vectors[i]) {
                    dominationCount[i] += 1
                }
            }
            if dominationCount[i] == 0 {
                currentFront.append(i)
            }
        }

        while !currentFront.isEmpty {
            fronts.append(currentFront)
            var nextFront: [Int] = []
            for i in currentFront {
                for j in dominated[i] {
                    dominationCount[j] -= 1
                    if dominationCount[j] == 0 {
                        nextFront.append(j)
                    }
                }
            }
            currentFront = nextFront
        }

        return fronts
    }

    /// `a` Pareto-dominates `b` iff `a` is at least as good on every
    /// objective and strictly better on at least one. "Higher is better"
    /// here because every objective is a fitness contribution in [0, 1].
    private static func dominates(_ a: [Double], _ b: [Double]) -> Bool {
        var anyBetter = false
        for (va, vb) in zip(a, b) {
            if va < vb { return false }
            if va > vb { anyBetter = true }
        }
        return anyBetter
    }

    /// Crowding distance for every index in a single front. Boundary
    /// solutions (extremes on any objective) get `.infinity`; interior
    /// solutions get the sum of normalized neighbour gaps across all
    /// objectives. Higher = more isolated in objective space = more worth
    /// preserving for diversity.
    static func crowdingDistance(
        indices: [Int],
        vectors: [[Double]]
    ) -> [Double] {
        let count = indices.count
        guard count > 2 else {
            return [Double](repeating: .infinity, count: count)
        }

        let objectiveCount = vectors[indices[0]].count
        var distances = [Double](repeating: 0, count: count)

        for m in 0..<objectiveCount {
            // Sort the front by this objective, then accumulate normalized
            // gaps from each point to its two neighbours.
            let ordered = (0..<count).sorted {
                vectors[indices[$0]][m] < vectors[indices[$1]][m]
            }
            distances[ordered[0]] = .infinity
            distances[ordered[count - 1]] = .infinity

            let lo = vectors[indices[ordered[0]]][m]
            let hi = vectors[indices[ordered[count - 1]]][m]
            let range = hi - lo
            guard range > 0 else { continue }

            for k in 1..<(count - 1) {
                let prev = vectors[indices[ordered[k - 1]]][m]
                let next = vectors[indices[ordered[k + 1]]][m]
                distances[ordered[k]] += (next - prev) / range
            }
        }

        return distances
    }
}
