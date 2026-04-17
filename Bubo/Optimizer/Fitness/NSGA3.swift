import Foundation

// MARK: - NSGA-III
//
// Reference-point-based many-objective selection. Replaces the scalar-weighted
// fitness + post-hoc NSGA-II pipeline that the GA used previously:
//
// • Evolutionary selection operates on (front rank, niche) pairs — individuals
//   on lower-numbered fronts beat higher, ties broken by association with
//   under-filled reference directions. This preserves diversity *in objective
//   space* across the whole run, not only at the end.
// • Scalar fitness becomes a post-hoc convenience: after NSGA-III selection
//   we rewrite `fitness` as `1 - frontIndex/totalFronts + nicheBonus` so
//   downstream consumers (UI, scenario generation, tests) that sort by
//   `.fitness` see a Pareto-sensible ordering without caring about fronts.
// • Works directly on objective vectors read from `ScheduleChromosome.
//   objectiveCache`, so delta-evaluation and the FitnessCache remain intact.
//
// Why NSGA-III and not NSGA-II: past 4 objectives, crowding distance loses
// discriminative power because the volume of non-dominated space explodes.
// 13 objectives is squarely in many-objective territory where reference
// directions are the canonical tool. For workloads that naturally collapse
// to fewer objectives (one obvious mode per bin), NSGA-III degenerates
// gracefully to NSGA-II-like behaviour.

// MARK: - Objective Vector Extraction

/// Reads an objective-score vector off a `ScheduleChromosome`, using the
/// evaluator's configured objective ordering. Caches a fresh breakdown when
/// the chromosome hasn't been evaluated through the normal path.
///
/// Importantly, scores are the *raw* objective values in [0, 1], not the
/// weighted-sum contribution — NSGA-III needs to compare candidates on each
/// axis independently, which the weighted scalar obliterates.
enum ObjectiveVector {
    /// Build vectors for every chromosome in `population`. Returns the
    /// ordered objective names so callers can align reference points /
    /// archive cells to the same axis order.
    static func extract(
        _ population: [ScheduleChromosome],
        evaluator: FitnessEvaluator,
        context: OptimizerContext
    ) -> (names: [String], vectors: [[Double]]) {
        let names = evaluator.objectives.map(\.name)
        let vectors = population.map { chromosome -> [Double] in
            let cache: [String: Double]
            if let existing = chromosome.objectiveCache, !existing.isEmpty {
                cache = existing
            } else {
                cache = evaluator.objectiveBreakdown(for: chromosome, context: context)
            }
            return names.map { cache[$0] ?? 0.0 }
        }
        return (names, vectors)
    }
}

// MARK: - Reference Points

/// Das–Dennis reference directions on the unit simplex. Every point is a
/// non-negative vector summing to 1; each acts as a "direction" in objective
/// space against which solutions are associated.
///
/// Single-layer with `p` divisions produces `C(p + m - 1, m - 1)` points in
/// `m` dimensions. For production we use two-layer Das–Dennis (Deb & Jain 2014)
/// when `m >= 8` so the interior of the simplex is sampled even when the
/// single layer only lands on the boundary.
struct ReferencePoints {
    let points: [[Double]]
    let dimension: Int

    /// Standard two-layer construction: coarse boundary layer (`p1`) +
    /// scaled interior layer (`p2`). Matches the canonical NSGA-III recipe
    /// from Deb & Jain, 2014.
    static func dasDennis(dimension m: Int, divisions p: Int) -> ReferencePoints {
        precondition(m > 0, "objective count must be positive")
        precondition(p >= 1, "divisions must be at least 1")
        let pts = enumerate(dimension: m, divisions: p)
        return ReferencePoints(points: pts, dimension: m)
    }

    /// Two-layer for many-objective problems. The interior layer is
    /// centred and scaled so points don't collide with the boundary layer
    /// or the simplex centroid.
    static func twoLayer(
        dimension m: Int,
        outerDivisions p1: Int,
        innerDivisions p2: Int
    ) -> ReferencePoints {
        precondition(m > 0, "objective count must be positive")
        precondition(p1 >= 1 && p2 >= 1, "divisions must be at least 1")
        let boundary = enumerate(dimension: m, divisions: p1)
        let interior = enumerate(dimension: m, divisions: p2).map { row -> [Double] in
            // Shrink toward the centroid by 50% so interior points cover
            // the bulk of the simplex without duplicating boundary directions.
            let centroid = 1.0 / Double(m)
            return row.map { centroid + ($0 - centroid) * 0.5 }
        }
        return ReferencePoints(points: boundary + interior, dimension: m)
    }

    /// Automatic choice: for small `m` use a single layer at the division
    /// count that approximates `targetCount`; for `m >= 8` switch to
    /// two-layer so the simplex interior is actually represented.
    static func auto(dimension m: Int, targetCount: Int) -> ReferencePoints {
        precondition(m > 0, "objective count must be positive")
        if m == 1 {
            return ReferencePoints(points: [[1.0]], dimension: 1)
        }
        if m >= 8 {
            // Two-layer: outer p so that single-layer count ≈ 0.7 · target,
            // inner p1 so interior ≈ 0.3 · target. Clamp to p >= 1.
            let outerTarget = max(1, Int(Double(targetCount) * 0.7))
            let innerTarget = max(1, targetCount - outerTarget)
            let p1 = findDivisions(dimension: m, targetPoints: outerTarget)
            let p2 = findDivisions(dimension: m, targetPoints: innerTarget)
            return twoLayer(dimension: m, outerDivisions: p1, innerDivisions: p2)
        }
        let p = findDivisions(dimension: m, targetPoints: targetCount)
        return dasDennis(dimension: m, divisions: p)
    }

    /// Smallest `p` such that `C(p+m-1, m-1) >= targetPoints`. Falls back
    /// to `p = 1` for degenerate input.
    private static func findDivisions(dimension m: Int, targetPoints: Int) -> Int {
        var p = 1
        while binomial(p + m - 1, m - 1) < targetPoints && p < 30 {
            p += 1
        }
        return p
    }

    private static func enumerate(dimension m: Int, divisions p: Int) -> [[Double]] {
        var result: [[Double]] = []
        var row = [Int](repeating: 0, count: m)
        fill(&row, index: 0, remaining: p, out: &result, divisions: p)
        return result
    }

    private static func fill(
        _ row: inout [Int],
        index: Int,
        remaining: Int,
        out: inout [[Double]],
        divisions p: Int
    ) {
        if index == row.count - 1 {
            row[index] = remaining
            out.append(row.map { Double($0) / Double(p) })
            return
        }
        for k in 0...remaining {
            row[index] = k
            fill(&row, index: index + 1, remaining: remaining - k, out: &out, divisions: p)
        }
    }

    private static func binomial(_ n: Int, _ k: Int) -> Int {
        if k < 0 || k > n { return 0 }
        var result = 1
        let kk = min(k, n - k)
        for i in 0..<kk {
            result = result * (n - i) / (i + 1)
        }
        return result
    }
}

// MARK: - NSGA-III Ranker

struct NSGA3 {

    /// Result of a single NSGA-III pass: selected indices (into the input
    /// population), the fronts they came from, and the niche each one
    /// associated with. Callers use the first to form the next generation
    /// and the rest for telemetry / archive feeding.
    struct SelectionResult {
        let selectedIndices: [Int]
        let frontOf: [Int: Int]       // index → front rank (0 = best)
        let nicheOf: [Int: Int]       // index → reference-point index
        let distanceToNiche: [Int: Double]
    }

    let referencePoints: ReferencePoints

    init(referencePoints: ReferencePoints) {
        self.referencePoints = referencePoints
    }

    /// Build an NSGA-III ranker suited to the objective count and target
    /// population size. The target governs reference-point density: roughly
    /// one ref point per individual is what Deb & Jain recommend.
    static func forPopulation(objectiveCount m: Int, populationSize n: Int) -> NSGA3 {
        NSGA3(referencePoints: .auto(dimension: m, targetCount: max(2, n)))
    }

    // MARK: - Top-level selection

    /// Select the best `k` individuals from `vectors` (higher is better on
    /// every axis). Returns indices into the input. Used by the GA loop
    /// after combining parents + offspring into a single pool.
    func select(_ vectors: [[Double]], count k: Int) -> SelectionResult {
        precondition(k >= 0)
        let n = vectors.count
        guard n > 0 else {
            return SelectionResult(
                selectedIndices: [],
                frontOf: [:],
                nicheOf: [:],
                distanceToNiche: [:]
            )
        }
        if k >= n {
            // Pool smaller than requested — return everything ranked by front.
            return rankAll(vectors)
        }

        let fronts = nonDominatedSort(vectors)
        var selected: [Int] = []
        var frontOf: [Int: Int] = [:]
        var lastAcceptedFront: [Int] = []
        var rejectedFromLastFront: [Int] = []

        for (rank, front) in fronts.enumerated() {
            for idx in front { frontOf[idx] = rank }
            if selected.count + front.count <= k {
                selected.append(contentsOf: front)
                if selected.count == k {
                    lastAcceptedFront = []
                    rejectedFromLastFront = []
                    break
                }
            } else {
                lastAcceptedFront = front
                rejectedFromLastFront = []
                break
            }
        }

        var nicheOf: [Int: Int] = [:]
        var distanceToNiche: [Int: Double] = [:]

        if !lastAcceptedFront.isEmpty {
            // Normalize using the ideal point (max per axis) over every
            // already-selected + candidate individual; NSGA-III's standard
            // normalization is based on the intercepts of the extreme
            // points, but for scores already in [0, 1] the simpler max-
            // normalization is numerically stable and faster.
            let associationPool = selected + lastAcceptedFront
            let normalized = normalize(vectors: associationPool.map { vectors[$0] })

            // Remap normalized to dictionary indexed by original index.
            var normByIndex: [Int: [Double]] = [:]
            for (i, idx) in associationPool.enumerated() {
                normByIndex[idx] = normalized[i]
            }

            // Associate every individual (selected + candidates) to its
            // nearest reference point. `niche` is the ref-point index.
            var selectedNiche: [Int: Int] = [:]
            var candidateNiche: [Int: Int] = [:]
            var candidateDistance: [Int: Double] = [:]
            var nicheCount: [Int: Int] = [:]
            for refIdx in referencePoints.points.indices { nicheCount[refIdx] = 0 }

            for idx in selected {
                guard let v = normByIndex[idx] else { continue }
                let (ref, _) = associate(vector: v)
                selectedNiche[idx] = ref
                nicheOf[idx] = ref
                distanceToNiche[idx] = perpDistance(v, to: referencePoints.points[ref])
                nicheCount[ref, default: 0] += 1
            }

            for idx in lastAcceptedFront {
                guard let v = normByIndex[idx] else { continue }
                let (ref, dist) = associate(vector: v)
                candidateNiche[idx] = ref
                candidateDistance[idx] = dist
            }

            // Fill remaining slots by niching: pick an under-filled reference
            // point, then take the closest-associated candidate on that ref.
            // Ties broken deterministically by original index so runs
            // remain reproducible.
            let slotsRemaining = k - selected.count
            var remaining = Set(lastAcceptedFront)
            for _ in 0..<slotsRemaining {
                guard !remaining.isEmpty else { break }
                // Find niche(s) with minimum count that still have candidates.
                let eligibleNiches: [Int] = nicheCount.keys.filter { ref in
                    remaining.contains(where: { candidateNiche[$0] == ref })
                }
                guard let minNiche = eligibleNiches.min(by: {
                    let a = nicheCount[$0] ?? 0
                    let b = nicheCount[$1] ?? 0
                    if a != b { return a < b }
                    return $0 < $1
                }) else { break }

                // From candidates on that niche, pick by rule:
                //   - If the niche is empty, take the closest candidate.
                //   - Else, tie-break by closest distance (NSGA-III spec).
                let onNiche = remaining.filter { candidateNiche[$0] == minNiche }
                let chosen = onNiche.min {
                    let da = candidateDistance[$0] ?? .infinity
                    let db = candidateDistance[$1] ?? .infinity
                    if abs(da - db) > 1e-12 { return da < db }
                    return $0 < $1
                } ?? onNiche.first!

                selected.append(chosen)
                nicheOf[chosen] = minNiche
                distanceToNiche[chosen] = candidateDistance[chosen] ?? 0
                nicheCount[minNiche, default: 0] += 1
                remaining.remove(chosen)
                // Rejected from the last front — not selected but still needed
                // for archive feeding and Pareto-aware migration downstream.
                // We push them into the rejected list at the end.
            }
            rejectedFromLastFront = Array(remaining)
            // Rejected individuals still get a front rank; niche/distance are
            // informational so downstream consumers that see them know where
            // they would have sat.
            for idx in rejectedFromLastFront {
                guard let v = normByIndex[idx] else { continue }
                let (ref, dist) = associate(vector: v)
                nicheOf[idx] = ref
                distanceToNiche[idx] = dist
            }
        }

        return SelectionResult(
            selectedIndices: selected,
            frontOf: frontOf,
            nicheOf: nicheOf,
            distanceToNiche: distanceToNiche
        )
    }

    /// When the requested `k >= n`, produce a SelectionResult that keeps
    /// every individual but still populates front / niche info for callers
    /// (Pareto-aware migration, MAP-Elites archive feeding) that want it.
    func rankAll(_ vectors: [[Double]]) -> SelectionResult {
        let fronts = nonDominatedSort(vectors)
        var frontOf: [Int: Int] = [:]
        for (rank, front) in fronts.enumerated() {
            for idx in front { frontOf[idx] = rank }
        }
        let normalized = normalize(vectors: vectors)
        var nicheOf: [Int: Int] = [:]
        var distanceToNiche: [Int: Double] = [:]
        for (idx, v) in normalized.enumerated() {
            let (ref, dist) = associate(vector: v)
            nicheOf[idx] = ref
            distanceToNiche[idx] = dist
        }
        return SelectionResult(
            selectedIndices: Array(vectors.indices),
            frontOf: frontOf,
            nicheOf: nicheOf,
            distanceToNiche: distanceToNiche
        )
    }

    // MARK: - Scalarization (post-hoc fitness rewrite)

    /// Rewrite each chromosome's `fitness` to a Pareto-consistent scalar so
    /// consumers that sort by `.fitness` descending get the NSGA-III-correct
    /// order. Called once per generation after selection.
    ///
    /// Encoding: `fitness = (1 - frontIndex/frontCount) + smallNicheBonus`,
    /// clamped to [0.01, 1.0]. `rawFitness` is preserved as the weighted-
    /// sum scalar — callers that need the legacy scalar can still read it.
    ///
    /// Generic over `C: Chromosome` so the helper can operate on both
    /// `ScheduleChromosome` and any other genome type that conforms.
    /// `Chromosome` exposes `fitness` as a mutable property, which is the
    /// only surface this helper needs.
    static func applyScalarFitness<C: Chromosome>(
        _ result: NSGA3.SelectionResult,
        to population: inout [C]
    ) {
        let frontCount = max(1, (result.frontOf.values.max() ?? 0) + 1)
        let frontWidth = 1.0 / Double(frontCount)

        let maxDist = result.distanceToNiche.values.filter(\.isFinite).max() ?? 1.0
        let normDist = maxDist > 0 ? maxDist : 1.0

        for idx in population.indices {
            let frontIdx = result.frontOf[idx] ?? (frontCount - 1)
            let dist = result.distanceToNiche[idx] ?? 0
            let bonus: Double
            if dist.isFinite {
                // Closer to niche = higher bonus. Rescale to [0, 0.9 · width]
                // so a distant point on a good front still beats a near-niche
                // point on a worse front.
                bonus = (1.0 - dist / normDist) * frontWidth * 0.9
            } else {
                bonus = 0
            }
            let base = 1.0 - Double(frontIdx) / Double(frontCount)
            population[idx].fitness = max(0.01, min(1.0, base - frontWidth + bonus))
        }
    }

    // MARK: - Non-Dominated Sorting (O(N² · M))

    func nonDominatedSort(_ vectors: [[Double]]) -> [[Int]] {
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
            if dominationCount[i] == 0 { currentFront.append(i) }
        }

        while !currentFront.isEmpty {
            fronts.append(currentFront)
            var nextFront: [Int] = []
            for i in currentFront {
                for j in dominated[i] {
                    dominationCount[j] -= 1
                    if dominationCount[j] == 0 { nextFront.append(j) }
                }
            }
            currentFront = nextFront
        }
        return fronts
    }

    /// `a` Pareto-dominates `b` iff a is at least as good on every axis and
    /// strictly better on one. Higher-is-better everywhere.
    private func dominates(_ a: [Double], _ b: [Double]) -> Bool {
        var strictlyBetter = false
        for (va, vb) in zip(a, b) {
            if va < vb { return false }
            if va > vb { strictlyBetter = true }
        }
        return strictlyBetter
    }

    // MARK: - Normalization

    /// Scale every objective to [0, 1] within the pool by its ideal (max)
    /// point. With scores already clamped to [0, 1] this is trivial, but
    /// keeping it explicit lets us swap in intercept-based normalization
    /// later if real-world scores stop being clamped.
    func normalize(vectors: [[Double]]) -> [[Double]] {
        guard let m = vectors.first?.count else { return [] }
        var minima = [Double](repeating: .infinity, count: m)
        var maxima = [Double](repeating: -.infinity, count: m)
        for v in vectors {
            for i in 0..<m {
                if v[i] < minima[i] { minima[i] = v[i] }
                if v[i] > maxima[i] { maxima[i] = v[i] }
            }
        }
        return vectors.map { v -> [Double] in
            var out = [Double](repeating: 0, count: m)
            for i in 0..<m {
                let lo = minima[i]
                let hi = maxima[i]
                let range = hi - lo
                // "Higher is better" → flip so the ideal is at 1 on every
                // axis; then reference points (which are all-non-negative
                // simplex vectors) act as direction weights pointing away
                // from the nadir.
                if range > 1e-12 {
                    out[i] = (v[i] - lo) / range
                } else {
                    out[i] = 1.0
                }
            }
            return out
        }
    }

    // MARK: - Reference-Point Association

    /// Associate a normalized vector with the reference point whose
    /// direction is closest in perpendicular-distance terms. Returns
    /// `(referenceIndex, distance)`.
    func associate(vector v: [Double]) -> (Int, Double) {
        precondition(!referencePoints.points.isEmpty, "empty reference set")
        var bestRef = 0
        var bestDist = Double.infinity
        for (i, ref) in referencePoints.points.enumerated() {
            let d = perpDistance(v, to: ref)
            if d < bestDist {
                bestDist = d
                bestRef = i
            }
        }
        return (bestRef, bestDist)
    }

    /// Perpendicular distance from `v` to the line through the origin and
    /// the reference direction `w`. NSGA-III's associate step uses this
    /// because reference points are directions, not absolute targets.
    func perpDistance(_ v: [Double], to w: [Double]) -> Double {
        precondition(v.count == w.count, "dimension mismatch")
        var dot = 0.0
        var wNormSq = 0.0
        for i in 0..<v.count {
            dot += v[i] * w[i]
            wNormSq += w[i] * w[i]
        }
        guard wNormSq > 1e-18 else { return Double.infinity }
        let t = dot / wNormSq
        var sumSq = 0.0
        for i in 0..<v.count {
            let projected = t * w[i]
            let diff = v[i] - projected
            sumSq += diff * diff
        }
        return sumSq.squareRoot()
    }
}
