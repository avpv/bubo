import Foundation

// MARK: - A-NSGA-III: Adaptive Reference Points
//
// Extension of `NSGA3` that grows the reference-point set over time toward
// regions of objective space where many solutions converge, and prunes
// directions that never attract any. The static Das–Dennis grid is a
// 2013-era baseline; adaptive placement (Jain & Deb, 2014) is the variant
// that handles irregular Pareto fronts — which is exactly what our
// 13-objective calendar scheduler produces (some objectives saturate on
// most real schedules, others scale continuously).
//
// Algorithm sketch:
//   1. After NSGA-III selection on the combined pool, record per-reference
//      niche counts over the last `memoryWindow` generations.
//   2. For every reference point whose running niche count is above
//      `crowdedThreshold`, spawn `p2` new interior points around it via
//      the centroid-shrink recipe. Centroid is a convex combination with
//      the original point; shrink factor controls exploration.
//   3. Evict reference points whose running niche count stays at zero
//      beyond `vacantWindow` generations.
//
// The adaptive ranker owns its `NSGA3` instance and returns a fresh
// `NSGA3` snapshot on `currentRanker()` so the GA's selection code remains
// agnostic to the update cycle — it just calls the ranker each generation.

/// Adaptive variant of NSGA-III's reference-point set. Wraps a mutable
/// ranker whose reference directions are added/pruned in response to
/// niche-association statistics collected across generations.
///
/// Thread safety: updates happen from the GA's main loop between
/// selection calls, which runs sequentially. `NSLock` guards the internal
/// history because `IslandModelGA` may share one adaptive ranker across
/// islands (same rationale as `MutationBandit`).
final class AdaptiveNSGA3: @unchecked Sendable {
    /// Snapshot stats so telemetry can observe the ranker without locking.
    struct Telemetry: Sendable {
        let generationsElapsed: Int
        let referencePointCount: Int
        let pointsAdded: Int
        let pointsRemoved: Int
        let crowdedNicheCount: Int
    }

    private let lock = NSLock()

    /// Current ranker. Replaced whenever the reference set grows or shrinks.
    private var ranker: NSGA3

    /// Rolling per-reference niche history (most recent generation first).
    private var nicheHistory: [[Int]]

    /// Max window of niche-count observations kept per reference point.
    private let memoryWindow: Int

    /// Generations of zero niche count before a point is eligible for pruning.
    private let vacantWindow: Int

    /// A reference point is "crowded" and triggers splitting when its rolling
    /// mean exceeds this threshold.
    private let crowdedThreshold: Double

    /// Shrink factor for interior points spawned around crowded references.
    /// 0.5 = halfway toward the simplex centroid.
    private let splitShrink: Double

    /// Hard cap so adaptation can't blow up the ranker. Two-layer Das–Dennis
    /// already produces a few hundred points for 13 objectives; we allow
    /// another 50% headroom.
    private let maxReferencePoints: Int

    /// Minimum kept reference points — never drop below the initial count
    /// so we always have basic simplex coverage.
    private let minReferencePoints: Int

    /// Generation counter; advanced on every `observe()`.
    private(set) var generation: Int = 0

    private(set) var pointsAddedTotal: Int = 0
    private(set) var pointsRemovedTotal: Int = 0

    init(
        base: NSGA3,
        memoryWindow: Int = 40,
        vacantWindow: Int = 20,
        crowdedThreshold: Double = 2.5,
        splitShrink: Double = 0.5,
        maxReferencePoints: Int = 600
    ) {
        // Invariant: vacantWindow must not exceed memoryWindow, otherwise
        // the pruning check can never fire (hist length is capped at
        // memoryWindow). Silently clamp to preserve both knobs in config
        // code that treats them as independent.
        self.ranker = base
        self.memoryWindow = max(1, memoryWindow)
        self.vacantWindow = max(1, min(vacantWindow, memoryWindow))
        self.crowdedThreshold = max(1.0, crowdedThreshold)
        self.splitShrink = min(0.9, max(0.05, splitShrink))
        self.maxReferencePoints = max(base.referencePoints.points.count, maxReferencePoints)
        self.minReferencePoints = base.referencePoints.points.count
        // Empty history — observations accumulate over time. Pruning is
        // gated on `hist.count >= vacantWindow` so the first vacantWindow
        // generations can't evict any point that simply hasn't yet
        // attracted a solution.
        self.nicheHistory = Array(
            repeating: [],
            count: base.referencePoints.points.count
        )
    }

    /// Convenience factory that mirrors `NSGA3.forPopulation` so callers can
    /// drop in an adaptive ranker without constructing the Das–Dennis layer
    /// themselves.
    static func forPopulation(
        objectiveCount m: Int,
        populationSize n: Int
    ) -> AdaptiveNSGA3 {
        AdaptiveNSGA3(base: NSGA3.forPopulation(objectiveCount: m, populationSize: n))
    }

    // MARK: - Accessors

    /// Returns the current ranker for selection. Taken by value so callers
    /// don't hold the lock while running their own work.
    var currentRanker: NSGA3 {
        lock.lock()
        defer { lock.unlock() }
        return ranker
    }

    var telemetry: Telemetry {
        lock.lock()
        defer { lock.unlock() }
        let crowded = nicheHistory.filter {
            meanCount($0) >= crowdedThreshold
        }.count
        return Telemetry(
            generationsElapsed: generation,
            referencePointCount: ranker.referencePoints.points.count,
            pointsAdded: pointsAddedTotal,
            pointsRemoved: pointsRemovedTotal,
            crowdedNicheCount: crowded
        )
    }

    // MARK: - Observation loop

    /// Record a selection result's niche associations and, periodically,
    /// adjust the reference-point set. `result.nicheOf` values are the
    /// indices into the *current* `ranker.referencePoints.points` array.
    ///
    /// `updateInterval` gates how often the reference set is adjusted —
    /// every generation is unnecessarily expensive; every N generations is
    /// enough to react to converging fronts without thrashing.
    func observe(_ result: NSGA3.SelectionResult, updateInterval: Int = 10) {
        lock.lock()
        defer { lock.unlock() }

        // 1. Update rolling counts per reference point.
        var counts = [Int](repeating: 0, count: ranker.referencePoints.points.count)
        for (_, ref) in result.nicheOf {
            guard ref >= 0 && ref < counts.count else { continue }
            counts[ref] += 1
        }
        for i in 0..<nicheHistory.count {
            nicheHistory[i].insert(counts[i], at: 0)
            if nicheHistory[i].count > memoryWindow {
                nicheHistory[i].removeLast()
            }
        }

        generation += 1

        // 2. Trigger adaptation on the interval boundary.
        guard generation % max(1, updateInterval) == 0 else { return }

        let (added, removed) = adjustReferencePoints()
        pointsAddedTotal += added
        pointsRemovedTotal += removed
    }

    /// Adjust the reference-point set: split crowded points and prune
    /// chronically vacant ones. Returns `(added, removed)` for telemetry.
    /// Must be called with `lock` held.
    private func adjustReferencePoints() -> (added: Int, removed: Int) {
        let current = ranker.referencePoints.points
        guard let m = current.first?.count else { return (0, 0) }

        // 1) Split crowded references.
        var newPoints: [[Double]] = current
        var added = 0

        let centroid = [Double](repeating: 1.0 / Double(m), count: m)
        for i in current.indices {
            let history = nicheHistory[i]
            guard meanCount(history) >= crowdedThreshold else { continue }
            guard newPoints.count < maxReferencePoints else { break }

            // Spawn an interior point halfway toward the centroid along this
            // direction. This preserves the original direction while adding
            // a distinct niche nearby (the new point is on the same ray, but
            // closer to the centroid — receivers are associated by
            // perpendicular distance so "nearer to centroid" actually
            // splits the niche along its radial direction).
            var interior = [Double](repeating: 0, count: m)
            for k in 0..<m {
                interior[k] = centroid[k] + (current[i][k] - centroid[k]) * splitShrink
            }
            // Renormalize onto the simplex (sum = 1, non-negative).
            interior = normalizeToSimplex(interior)

            // Avoid duplicate points (numerically close to an existing one).
            if !hasCloseDuplicate(interior, in: newPoints, epsilon: 1e-6) {
                newPoints.append(interior)
                added += 1
            }
        }

        // 2) Prune vacant references (but never below min count).
        var removed = 0
        if newPoints.count > minReferencePoints {
            // Budget: how many points we can remove before hitting the floor.
            let maxRemovable = max(0, newPoints.count - minReferencePoints)
            var survivors: [Int] = []
            for i in current.indices {
                let hist = nicheHistory[i]
                // Vacant iff the running window is long enough *and* every
                // observation in that window is zero. Empty history (fresh
                // point) fails the count guard and is always kept.
                let hasEnoughHistory = hist.count >= vacantWindow
                let vacantStreak = hasEnoughHistory
                    && hist.prefix(vacantWindow).allSatisfy { $0 == 0 }
                if vacantStreak && removed < maxRemovable {
                    removed += 1
                } else {
                    survivors.append(i)
                }
            }
            // Rebuild newPoints: keep survivors + whatever we just appended.
            let appendedSuffix = Array(newPoints.suffix(added))
            var rebuilt: [[Double]] = survivors.map { current[$0] }
            rebuilt.append(contentsOf: appendedSuffix)
            newPoints = rebuilt
        }

        guard added > 0 || removed > 0 else { return (0, 0) }

        let nextRefs = ReferencePoints(points: newPoints, dimension: m)
        ranker = NSGA3(referencePoints: nextRefs)

        // Reset histories so freshly added points start from zero and
        // surviving ones carry forward. We rebuild `nicheHistory` parallel
        // to `newPoints`.
        var nextHistory: [[Int]] = []
        let previouslyKept = newPoints.count - added
        // Keep histories for the first `previouslyKept` slots from the
        // surviving originals. Because pruning happens before append, the
        // first `previouslyKept` entries of `newPoints` are the survivors
        // (in original order).
        var survivingIdx = 0
        for i in current.indices {
            // Identify survivors by reference equality in the simplex space.
            if survivingIdx < previouslyKept,
               pointsAreClose(current[i], newPoints[survivingIdx], epsilon: 1e-9) {
                nextHistory.append(nicheHistory[i])
                survivingIdx += 1
            }
        }
        // Fill any mismatch with fresh zero history (defensive fallback).
        while nextHistory.count < previouslyKept {
            nextHistory.append([Int](repeating: 0, count: memoryWindow))
        }
        // New points start with empty history — they haven't observed
        // any generation yet, so they cannot be pruned until they
        // accumulate vacantWindow consecutive zero observations.
        for _ in 0..<added {
            nextHistory.append([])
        }
        nicheHistory = nextHistory

        return (added, removed)
    }

    // MARK: - Helpers

    private func meanCount(_ history: [Int]) -> Double {
        guard !history.isEmpty else { return 0 }
        let sum = history.reduce(0, +)
        return Double(sum) / Double(history.count)
    }

    private func hasCloseDuplicate(_ p: [Double], in set: [[Double]], epsilon: Double) -> Bool {
        for q in set where pointsAreClose(p, q, epsilon: epsilon) { return true }
        return false
    }

    private func pointsAreClose(_ a: [Double], _ b: [Double], epsilon: Double) -> Bool {
        guard a.count == b.count else { return false }
        var sumSq = 0.0
        for i in 0..<a.count {
            let d = a[i] - b[i]
            sumSq += d * d
        }
        return sumSq.squareRoot() < epsilon
    }

    private func normalizeToSimplex(_ p: [Double]) -> [Double] {
        // Clip negatives and rescale to sum 1. Interior-point perturbations
        // can in principle drift slightly negative; clipping is cheaper than
        // a full projection and accurate enough for reference directions.
        let clipped = p.map { max(0, $0) }
        let sum = clipped.reduce(0, +)
        guard sum > 1e-12 else {
            // Degenerate fallback: uniform weights.
            let m = p.count
            return [Double](repeating: 1.0 / Double(m), count: m)
        }
        return clipped.map { $0 / sum }
    }
}
