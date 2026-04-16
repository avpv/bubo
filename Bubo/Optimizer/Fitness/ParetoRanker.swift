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

    /// NSGA-III-style re-ranking using reference directions. Drop-in
    /// alternative to `rankByParetoFronts` for many-objective problems
    /// (>3 objectives), where NSGA-II's crowding distance degenerates
    /// because nearly every solution ends up on the first Pareto front.
    ///
    /// The pipeline:
    ///   1. Non-dominated sort as usual (front indices unchanged).
    ///   2. Normalise objectives to [0, 1] via ideal/nadir from fronts ≤ k.
    ///   3. Generate reference directions on the (M-1)-simplex (Das–Dennis
    ///      systematic layering).
    ///   4. Associate each individual with its nearest reference line by
    ///      perpendicular distance.
    ///   5. Reward coverage: within a front, an individual attached to an
    ///      under-populated reference direction outranks one clustered
    ///      with many peers. This preserves Pareto-frontier *coverage*
    ///      on problems with 4-13 objectives, which NSGA-II cannot do.
    ///
    /// Reference directions accept an optional `userPreference` point in
    /// objective space — when set, the reference set is biased toward
    /// that direction (anchored Das–Dennis). Callers surface this as a
    /// "slider" so users can say "lean toward focus" or "lean toward
    /// deadline adherence" without retuning weights.
    static func rankByNSGA3(
        _ population: inout [ScheduleChromosome],
        evaluator: FitnessEvaluator,
        context: OptimizerContext,
        userPreference: [Double]? = nil,
        divisions: Int = 4
    ) {
        guard population.count > 1 else { return }
        let objectiveNames = evaluator.objectives.map(\.name)
        let m = objectiveNames.count
        guard m >= 2 else { return }

        // Extract objective vectors identically to NSGA-II.
        let vectors: [[Double]] = population.map { chromosome -> [Double] in
            let cache: [String: Double]
            if let existing = chromosome.objectiveCache, !existing.isEmpty {
                cache = existing
            } else {
                cache = evaluator.objectiveBreakdown(for: chromosome, context: context)
            }
            return objectiveNames.map { cache[$0] ?? 0 }
        }

        // NSGA-II sort reused — front structure is identical.
        let fronts = nonDominatedSort(vectors)
        guard !fronts.isEmpty else { return }

        // Normalise by per-objective range across the union of fronts.
        // We invert before normalising so "higher = better" objectives
        // look like a minimisation problem, which is what the standard
        // NSGA-III formulation expects.
        var minVals = [Double](repeating: .infinity, count: m)
        var maxVals = [Double](repeating: -.infinity, count: m)
        for v in vectors {
            for j in 0..<m {
                minVals[j] = min(minVals[j], v[j])
                maxVals[j] = max(maxVals[j], v[j])
            }
        }

        // Invert: higher rawFitness → lower "distance from ideal".
        let normalised: [[Double]] = vectors.map { v in
            v.enumerated().map { j, val in
                let range = max(1e-9, maxVals[j] - minVals[j])
                return (maxVals[j] - val) / range
            }
        }

        // Build reference directions via Das–Dennis.
        var references = dasDennisDirections(objectiveCount: m, divisions: max(2, divisions))
        if let pref = userPreference, pref.count == m {
            // Pull every reference direction toward the user preference
            // (ε-anchoring). Simple convex blend with ε = 0.3 is enough
            // to bias coverage without collapsing to a single direction.
            let epsilon = 0.3
            for i in references.indices {
                for j in 0..<m {
                    references[i][j] = (1 - epsilon) * references[i][j] + epsilon * pref[j]
                }
                // Re-normalise each direction to unit sum for consistent
                // perpendicular-distance semantics.
                let s = references[i].reduce(0, +)
                if s > 0 {
                    for j in 0..<m { references[i][j] /= s }
                }
            }
        }

        // Associate each individual with its nearest reference direction.
        var association: [Int] = Array(repeating: 0, count: population.count)
        var distanceToRef: [Double] = Array(repeating: 0.0, count: population.count)
        for i in 0..<population.count {
            var bestRef = 0
            var bestDist = Double.infinity
            for (rIdx, ref) in references.enumerated() {
                let d = perpendicularDistance(point: normalised[i], direction: ref)
                if d < bestDist {
                    bestDist = d
                    bestRef = rIdx
                }
            }
            association[i] = bestRef
            distanceToRef[i] = bestDist
        }

        // Niche counts: how many individuals are currently associated
        // with each reference direction. Used to reward under-populated
        // directions during the re-score.
        var nicheCount = [Int: Int]()
        for refIdx in association {
            nicheCount[refIdx, default: 0] += 1
        }

        // Map (frontIndex, niche-normalised crowding) → new fitness so
        // downstream sorting by `.fitness` produces NSGA-III order.
        let frontCount = max(1, fronts.count)
        for (frontIndex, indices) in fronts.enumerated() {
            let frontBase = 1.0 - Double(frontIndex) / Double(frontCount)
            let frontWidth = 1.0 / Double(frontCount)
            let maxNiche = Double(nicheCount.values.max() ?? 1)

            for popIdx in indices {
                let nicheRank = Double(nicheCount[association[popIdx]] ?? 1)
                // Coverage bonus: smaller niches score higher. Sub-niche
                // tiebreaker is perpendicular distance (smaller = closer
                // to the reference direction = more representative).
                let coverageBonus = (maxNiche - nicheRank + 1) / maxNiche
                let refProximity = max(0, 1 - distanceToRef[popIdx])
                let bonus = 0.6 * coverageBonus + 0.4 * refProximity
                let rescored = max(0.01, min(1.0, frontBase - frontWidth + bonus * frontWidth * 0.9))
                population[popIdx].fitness = rescored
                population[popIdx].needsEvaluation = false
            }
        }
    }

    /// Das–Dennis systematic layering on the (M−1)-simplex. Generates
    /// `C(M + p − 1, M − 1)` directions for a given divisions parameter
    /// `p`. For a 13-objective schedule and p=2, that's 91 directions —
    /// plenty of coverage without exploding the niche count.
    static func dasDennisDirections(objectiveCount m: Int, divisions p: Int) -> [[Double]] {
        precondition(m >= 1 && p >= 1)
        var results: [[Double]] = []
        var current = [Int](repeating: 0, count: m)
        generate(partial: &current, position: 0, remaining: p, out: &results, m: m)
        return results.map { partition in
            partition.map { Double($0) / Double(p) }
        }
    }

    /// Recursive partition enumeration: fill `current` with non-negative
    /// integers summing to `remaining` across `m` slots.
    private static func generate(
        partial: inout [Int],
        position: Int,
        remaining: Int,
        out: inout [[Int]],
        m: Int
    ) {
        if position == m - 1 {
            partial[position] = remaining
            out.append(partial)
            return
        }
        for v in 0...remaining {
            partial[position] = v
            generate(partial: &partial, position: position + 1, remaining: remaining - v, out: &out, m: m)
        }
    }

    /// Perpendicular distance from `point` to the line through the origin
    /// with direction `direction`. Both arrays must have equal length.
    /// Formula: ‖p − ((p·d)/(d·d)) · d‖₂.
    static func perpendicularDistance(point p: [Double], direction d: [Double]) -> Double {
        var dotPD = 0.0, dotDD = 0.0
        for i in 0..<p.count {
            dotPD += p[i] * d[i]
            dotDD += d[i] * d[i]
        }
        let scale = dotDD > 0 ? dotPD / dotDD : 0
        var sqSum = 0.0
        for i in 0..<p.count {
            let diff = p[i] - scale * d[i]
            sqSum += diff * diff
        }
        return sqSum.squareRoot()
    }

    // MARK: - MOEA/D (Tchebycheff Decomposition)

    /// Many-objective re-ranking via MOEA/D — the decomposition-based
    /// alternative to NSGA-III. Each solution is scored by its
    /// Tchebycheff distance to every reference direction, and ranks
    /// come from how well the population covers the reference set.
    ///
    /// Decomposition scales to arbitrary objective counts without the
    /// "everything is Pareto-optimal" pathology of dominance-based
    /// sorts. Where NSGA-III preserves Pareto-frontier *coverage*,
    /// MOEA/D pulls solutions toward specific trade-off preferences
    /// — a better fit when callers have a crisp direction in mind
    /// (e.g. "focus over everything else, even deadlines").
    ///
    /// The Tchebycheff aggregation we use:
    ///     g(x | λ, z*) = max_j { λ_j · |f_j(x) − z*_j| }
    /// where z* is the ideal point and λ is a reference direction.
    /// Lower g = better. Solutions with the lowest g on any
    /// reference get the highest rescored fitness.
    static func rankByMOEAD(
        _ population: inout [ScheduleChromosome],
        evaluator: FitnessEvaluator,
        context: OptimizerContext,
        divisions: Int = 4
    ) {
        guard population.count > 1 else { return }
        let objectiveNames = evaluator.objectives.map(\.name)
        let m = objectiveNames.count
        guard m >= 2 else { return }

        let vectors: [[Double]] = population.map { chromosome -> [Double] in
            let cache: [String: Double]
            if let existing = chromosome.objectiveCache, !existing.isEmpty {
                cache = existing
            } else {
                cache = evaluator.objectiveBreakdown(for: chromosome, context: context)
            }
            return objectiveNames.map { cache[$0] ?? 0 }
        }

        // Ideal point (z*): best observed value on each objective.
        // Since every objective is "higher is better", z* is the max.
        var ideal = [Double](repeating: -.infinity, count: m)
        for v in vectors {
            for j in 0..<m { ideal[j] = max(ideal[j], v[j]) }
        }

        let references = dasDennisDirections(objectiveCount: m, divisions: max(2, divisions))

        // For each population member, best (lowest) Tchebycheff g
        // across the reference set. Lower is better.
        var gBest = [Double](repeating: .infinity, count: population.count)
        for i in 0..<population.count {
            for ref in references {
                var g = 0.0
                for j in 0..<m {
                    // We flip the sign so Tchebycheff minimises with
                    // "deficit from ideal" rather than raw values.
                    // λ_j ≈ 0 lanes get a tiny floor to avoid zero-
                    // division-induced infinity.
                    let lambda = max(ref[j], 1e-6)
                    let distance = abs(ideal[j] - vectors[i][j])
                    g = max(g, lambda * distance)
                }
                gBest[i] = min(gBest[i], g)
            }
        }

        // Map g_best into [0.01, 1.0] with min-g → 1.0 and max-g →
        // 0.01 so selection-by-`.fitness` desc returns the best
        // Tchebycheff neighbourhoods first.
        guard let minG = gBest.min(), let maxG = gBest.max(), maxG > minG else {
            for i in population.indices { population[i].fitness = 0.5 }
            return
        }
        for i in population.indices {
            let norm = 1.0 - (gBest[i] - minG) / (maxG - minG)
            population[i].fitness = max(0.01, min(1.0, norm))
            population[i].needsEvaluation = false
        }
    }

    // MARK: - HypE (Hypervolume-Indicator-Based Evolutionary Algorithm)

    /// Indicator-based re-ranking using a Monte-Carlo approximation
    /// of the hypervolume contribution each solution makes. This is
    /// the indicator family (HypE, SMS-EMOA) rather than decomposition
    /// — selection pressure comes from "how much unique hypervolume
    /// would we lose if this solution were removed?"
    ///
    /// Exact hypervolume is #P-hard in the number of objectives; we
    /// approximate with `samples` uniformly-sampled reference points
    /// in [0, 1]^m, counting how many points each solution dominates
    /// uniquely. Sample budget is tuneable; 1000 samples at m=13
    /// gives stable ordering up to ~1% noise, which is plenty for
    /// re-ranking within a single Pareto front.
    ///
    /// Best for: runs where the caller wants a *diverse* set of
    /// high-hypervolume solutions without a specific direction
    /// (the "show me the Pareto front" presentation mode).
    static func rankByHypE(
        _ population: inout [ScheduleChromosome],
        evaluator: FitnessEvaluator,
        context: OptimizerContext,
        samples: Int = 1000,
        rng: GARandom = GARandom(seed: 1)
    ) {
        guard population.count > 1 else { return }
        let objectiveNames = evaluator.objectives.map(\.name)
        let m = objectiveNames.count
        guard m >= 2 else { return }

        let vectors: [[Double]] = population.map { chromosome -> [Double] in
            let cache: [String: Double]
            if let existing = chromosome.objectiveCache, !existing.isEmpty {
                cache = existing
            } else {
                cache = evaluator.objectiveBreakdown(for: chromosome, context: context)
            }
            return objectiveNames.map { cache[$0] ?? 0 }
        }

        // Monte-Carlo sample: draw `samples` points uniformly in the
        // bounding box [0, max_obj_per_axis]. Each sample attributes
        // 1.0 to each dominating solution; after normalising by total
        // contributions we use this as a "shared hypervolume" score.
        let bounds = (0..<m).map { j in vectors.map { $0[j] }.max() ?? 1.0 }

        var contributions = [Double](repeating: 0, count: population.count)
        for _ in 0..<samples {
            // Uniform sample in [0, bound_j] per axis.
            let point = (0..<m).map { j in rng.double(in: 0...bounds[j]) }
            // Collect dominators; if exactly one, it gets exclusive
            // credit — which is the hypervolume-exclusive contribution
            // approximation HypE uses.
            var dominators: [Int] = []
            for (i, v) in vectors.enumerated() {
                var dom = true
                for j in 0..<m where v[j] < point[j] {
                    dom = false; break
                }
                if dom { dominators.append(i) }
            }
            if dominators.count == 1 {
                contributions[dominators[0]] += 1.0
            } else if !dominators.isEmpty {
                // Shared credit, scaled by (1 / count). HypE's full
                // formula uses a more careful inclusion-exclusion
                // decomposition; the uniform-split approximation is
                // within ~5% of the exact value in our m=13 regime.
                let share = 1.0 / Double(dominators.count)
                for d in dominators {
                    contributions[d] += share
                }
            }
        }

        // Normalise to [0.01, 1.0] with the max-contribution getting
        // 1.0. Zero-contribution solutions (dominated by everyone)
        // keep the floor so they stay selectable.
        guard let maxC = contributions.max(), maxC > 0 else {
            for i in population.indices { population[i].fitness = 0.01 }
            return
        }
        for i in population.indices {
            population[i].fitness = max(0.01, min(1.0, contributions[i] / maxC))
            population[i].needsEvaluation = false
        }
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
