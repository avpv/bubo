import Foundation

// MARK: - MOEA/D-AWA Survivor Selection (Wave 2 / п.4)
//
// Decomposition-based many-objective survivor selection. NSGA-III's
// reference-point approach works well at ≤8 objectives but degrades
// past that because the unit simplex fills sparsely and niching loses
// discriminative power. 14 objectives is squarely in the degradation
// zone.
//
// MOEA/D (Zhang & Li, 2007) decomposes the multi-objective problem
// into N scalar subproblems, each defined by a weight vector and the
// Tchebycheff scalarisation. AWA (Adaptive Weight Adjustment, Qi et
// al., 2014) periodically reshapes weight vectors: crowded subproblems
// shed weights to under-explored regions, so the search effort follows
// the Pareto front's geometry rather than an a-priori simplex grid.
//
// This file provides a drop-in alternative to the NSGA-III survivor
// path. It can be slotted into the existing `MultiObjectiveContext`
// pipeline by constructing `MOEADContext` instead of
// `MultiObjectiveContext.schedule(…)` and wiring the engine to call
// `select(combined:fromSize:)` on each generation.

/// Scalarisation kernel. Tchebycheff is the default — it produces
/// uniformly-spread Pareto-optimal solutions with weight vectors
/// that cover the simplex, while weighted-sum degenerates on
/// concave fronts. PBI (Penalty-Based Boundary Intersection) is
/// offered as an aggressive alternative when the front is known to
/// be smooth.
enum MOEADScalarisation: Sendable {
    case tchebycheff
    case pbi(theta: Double)
    case weightedSum
}

/// Weight vector plus its current Tchebycheff anchor.
struct MOEADSubproblem: Sendable {
    /// Non-negative vector summing to 1 — the "direction" of this
    /// subproblem in objective space.
    var weights: [Double]

    /// Index of the individual currently solving this subproblem
    /// (i.e. achieving the best scalarised score). `nil` during
    /// initialisation.
    var incumbent: Int?

    /// Scalarised score of the incumbent. Lower is better.
    var incumbentScore: Double
}

/// Full MOEA/D-AWA state. Holds weight vectors, reference (ideal)
/// point, and AWA bookkeeping. One instance per GA run.
final class MOEADState: @unchecked Sendable {
    let dimension: Int
    let neighborhoodSize: Int
    let scalarisation: MOEADScalarisation
    let replacementProbability: Double

    /// AWA cadence: reshape weights every `awaInterval` generations.
    /// 0 disables AWA (plain MOEA/D).
    let awaInterval: Int

    /// Upper bound on the fraction of weights that may be relocated
    /// per AWA pass. Guards against destabilising the decomposition.
    let awaRelocateFraction: Double

    private let lock = NSLock()
    private var subproblems: [MOEADSubproblem]
    private var neighborsOf: [[Int]]  // index → indices of nearest subproblems
    private var idealPoint: [Double]
    /// Nadir estimate used by PBI. `nil` until we've seen ≥2 points.
    private var nadirPoint: [Double]?
    private var generationCount: Int = 0

    init(
        dimension: Int,
        populationSize: Int,
        neighborhoodSize: Int = 20,
        scalarisation: MOEADScalarisation = .tchebycheff,
        replacementProbability: Double = 0.9,
        awaInterval: Int = 25,
        awaRelocateFraction: Double = 0.05
    ) {
        precondition(dimension > 0)
        precondition(populationSize > 0)
        self.dimension = dimension
        self.neighborhoodSize = min(neighborhoodSize, populationSize)
        self.scalarisation = scalarisation
        self.replacementProbability = replacementProbability
        self.awaInterval = awaInterval
        self.awaRelocateFraction = awaRelocateFraction

        // Initial weights: Das–Dennis simplex, reused from NSGA-III.
        // Auto-tune divisions so we generate ~populationSize points;
        // the MOEA/D convention is populationSize = number of weights.
        let rp = ReferencePoints.auto(dimension: dimension, targetCount: populationSize)
        let weights = rp.points.prefix(populationSize).map { $0 }
        self.subproblems = weights.map {
            MOEADSubproblem(weights: $0, incumbent: nil, incumbentScore: .infinity)
        }
        self.idealPoint = [Double](repeating: -.infinity, count: dimension)
        self.neighborsOf = Self.buildNeighbors(weights: weights, size: self.neighborhoodSize)
    }

    /// Update the incumbent for every subproblem given a fresh set
    /// of (index, objectiveVector) pairs. Call once per generation
    /// with the full parent+offspring pool.
    func updateIncumbents(
        candidates: [(index: Int, objectives: [Double])]
    ) {
        lock.lock()
        defer { lock.unlock() }

        // Ideal point maintenance: we maximise, so track the max
        // per axis across every individual seen.
        for (_, obj) in candidates {
            for (i, v) in obj.enumerated() where i < dimension {
                if v > idealPoint[i] { idealPoint[i] = v }
            }
        }
        // Keep nadir as a running min; needed only for PBI.
        if case .pbi = scalarisation {
            if nadirPoint == nil, let first = candidates.first {
                nadirPoint = first.objectives
            }
            if var nadir = nadirPoint {
                for (_, obj) in candidates {
                    for (i, v) in obj.enumerated() where i < dimension {
                        if v < nadir[i] { nadir[i] = v }
                    }
                }
                nadirPoint = nadir
            }
        }

        // Score each candidate against each subproblem and adopt
        // as incumbent when it's strictly better.
        for sub in subproblems.indices {
            var bestIdx = subproblems[sub].incumbent
            var bestScore = subproblems[sub].incumbentScore
            for (idx, obj) in candidates {
                let s = scalarise(objectives: obj, weights: subproblems[sub].weights)
                if s < bestScore {
                    bestScore = s
                    bestIdx = idx
                }
            }
            subproblems[sub].incumbent = bestIdx
            subproblems[sub].incumbentScore = bestScore
        }

        generationCount += 1
        if awaInterval > 0 && generationCount % awaInterval == 0 {
            relocateWeightsAWA()
        }
    }

    /// Selected survivors: incumbents of every subproblem, de-duped.
    /// When two subproblems share an incumbent (common early on),
    /// the duplicates are replaced by the best unclaimed candidates
    /// so the survivor set matches subproblem count.
    func selectedIndices(from candidates: [(index: Int, objectives: [Double])]) -> [Int] {
        lock.lock()
        defer { lock.unlock() }

        var chosen = Set<Int>()
        var result: [Int] = []
        result.reserveCapacity(subproblems.count)
        for sub in subproblems {
            if let inc = sub.incumbent, !chosen.contains(inc) {
                chosen.insert(inc)
                result.append(inc)
            }
        }

        // Backfill with unselected candidates ranked by their best
        // scalarised score across any subproblem. This only fires
        // when duplicates exist.
        if result.count < subproblems.count {
            var remaining = candidates.filter { !chosen.contains($0.index) }
            remaining.sort { a, b in
                minScalarisedScore(objectives: a.objectives)
                    < minScalarisedScore(objectives: b.objectives)
            }
            for cand in remaining {
                if result.count >= subproblems.count { break }
                if chosen.insert(cand.index).inserted {
                    result.append(cand.index)
                }
            }
        }
        return result
    }

    // MARK: - AWA

    /// Relocate a bounded fraction of weights away from crowded
    /// subproblems into sparse regions. Crowdedness is measured by
    /// incumbent score improvement rate over the recent window —
    /// subproblems whose incumbent keeps churning are in a
    /// productive region and stay; stagnant ones get reassigned.
    ///
    /// This is an intentionally conservative AWA: we reshape at
    /// most `awaRelocateFraction · N` weights per pass, so the
    /// neighborhood structure remains largely stable.
    private func relocateWeightsAWA() {
        let relocatable = max(1, Int(Double(subproblems.count) * awaRelocateFraction))
        // Stagnation proxy: subproblems with the worst (highest)
        // incumbent scores have the least promising neighbourhoods.
        let sortedByScore = subproblems.enumerated()
            .sorted { $0.element.incumbentScore > $1.element.incumbentScore }
        let donors = sortedByScore.prefix(relocatable).map(\.offset)

        // Target directions: the sparsest parts of the simplex, which
        // we approximate by the subproblems whose neighbours are
        // furthest away (their nearest neighbour has the largest
        // distance).
        var sparsity: [(idx: Int, dist: Double)] = []
        sparsity.reserveCapacity(subproblems.count)
        for i in subproblems.indices {
            let neighbors = neighborsOf[i]
            let minDist = neighbors.first.map {
                Self.weightDistance(subproblems[i].weights, subproblems[$0].weights)
            } ?? 0
            sparsity.append((i, minDist))
        }
        sparsity.sort { $0.dist > $1.dist }
        let receivers = sparsity.prefix(relocatable).map(\.idx)

        // Morph donor weights toward receivers' neighbourhood centroids.
        for (donorIdx, receiverIdx) in zip(donors, receivers) {
            let target = centroid(of: neighborsOf[receiverIdx], plus: receiverIdx)
            // Interpolate 60% toward target; heavy relocation
            // produces weight-vector collisions otherwise.
            let blend: Double = 0.6
            let mixed = zip(subproblems[donorIdx].weights, target).map { $0 * (1 - blend) + $1 * blend }
            let normalised = MOEADState.normalise(mixed)
            subproblems[donorIdx].weights = normalised
            subproblems[donorIdx].incumbentScore = .infinity
            subproblems[donorIdx].incumbent = nil
        }
        // Rebuild neighborhoods after mutation.
        neighborsOf = Self.buildNeighbors(
            weights: subproblems.map(\.weights),
            size: neighborhoodSize
        )
    }

    private func centroid(of indices: [Int], plus extra: Int) -> [Double] {
        var sum = [Double](repeating: 0, count: dimension)
        let members = Set(indices + [extra])
        for idx in members {
            for (j, v) in subproblems[idx].weights.enumerated() where j < dimension {
                sum[j] += v
            }
        }
        let scale = 1.0 / Double(members.count)
        return sum.map { $0 * scale }
    }

    // MARK: - Introspection

    var weightVectors: [[Double]] {
        lock.lock(); defer { lock.unlock() }
        return subproblems.map(\.weights)
    }

    var currentIdealPoint: [Double] {
        lock.lock(); defer { lock.unlock() }
        return idealPoint
    }

    // MARK: - Internals

    private func scalarise(objectives obj: [Double], weights: [Double]) -> Double {
        // We maximise, Tchebycheff / PBI are minimisers — negate to align.
        switch scalarisation {
        case .tchebycheff:
            var worst = -Double.infinity
            for i in 0..<dimension where i < obj.count && i < weights.count {
                let w = max(weights[i], 1e-6)
                let gap = idealPoint[i] - obj[i]
                let s = gap * w
                if s > worst { worst = s }
            }
            return worst
        case .pbi(let theta):
            // Decompose the gap vector into parallel (d1) + perp (d2)
            // components relative to the weight vector. Score = d1 + θ·d2.
            var norm2 = 0.0
            for w in weights { norm2 += w * w }
            let norm = sqrt(max(norm2, 1e-12))
            var d1Dot = 0.0
            for i in 0..<dimension where i < obj.count {
                let gap = idealPoint[i] - obj[i]
                d1Dot += gap * weights[i]
            }
            let d1 = d1Dot / norm
            var d2sq = 0.0
            for i in 0..<dimension where i < obj.count {
                let gap = idealPoint[i] - obj[i]
                let proj = d1 * weights[i] / norm
                d2sq += (gap - proj) * (gap - proj)
            }
            let d2 = sqrt(max(d2sq, 0))
            return d1 + theta * d2
        case .weightedSum:
            var s = 0.0
            for i in 0..<dimension where i < obj.count && i < weights.count {
                // Invert sign: max-objective framed as min-gap.
                s += weights[i] * (idealPoint[i] - obj[i])
            }
            return s
        }
    }

    private func minScalarisedScore(objectives: [Double]) -> Double {
        var best = Double.infinity
        for sub in subproblems {
            let s = scalarise(objectives: objectives, weights: sub.weights)
            if s < best { best = s }
        }
        return best
    }

    private static func normalise(_ v: [Double]) -> [Double] {
        let s = v.reduce(0, +)
        guard s > 1e-12 else {
            let n = Double(v.count)
            return [Double](repeating: 1.0 / n, count: v.count)
        }
        return v.map { $0 / s }
    }

    private static func weightDistance(_ a: [Double], _ b: [Double]) -> Double {
        var s = 0.0
        for (x, y) in zip(a, b) { s += (x - y) * (x - y) }
        return sqrt(s)
    }

    private static func buildNeighbors(weights: [[Double]], size: Int) -> [[Int]] {
        var result: [[Int]] = []
        result.reserveCapacity(weights.count)
        for i in weights.indices {
            var dists: [(idx: Int, d: Double)] = []
            dists.reserveCapacity(weights.count)
            for j in weights.indices where j != i {
                dists.append((j, weightDistance(weights[i], weights[j])))
            }
            dists.sort { $0.d < $1.d }
            result.append(dists.prefix(size).map(\.idx))
        }
        return result
    }
}

// MARK: - Entry point

enum MOEAD_AWA {
    /// Factory producing a state configured for the standard 14-
    /// objective schedule evaluator and a given population size.
    static func forScheduleEvaluator(
        evaluator: FitnessEvaluator,
        populationSize: Int
    ) -> MOEADState {
        MOEADState(
            dimension: evaluator.objectives.count,
            populationSize: populationSize
        )
    }
}
