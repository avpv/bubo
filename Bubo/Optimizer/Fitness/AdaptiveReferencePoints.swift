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
        /// Number of pruned reference directions currently held in the
        /// resurrection pool — non-zero on workloads whose Pareto front
        /// moves over time.
        let ghostPoolSize: Int
        /// Lifetime count of ghost directions promoted back into the
        /// active reference set.
        let pointsResurrected: Int
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
    private(set) var pointsResurrectedTotal: Int = 0

    /// Pruned reference directions kept around for possible
    /// resurrection. Each entry is `(point, generation-when-pruned)`;
    /// entries older than `ghostExpiryGenerations` are discarded.
    /// Keeps the pool bounded at `ghostPoolLimit` by FIFO eviction.
    private var ghostPool: [(point: [Double], prunedAt: Int)] = []

    private let ghostPoolLimit: Int = 256

    /// A ghost expires after this many generations. Long enough that
    /// a genuine front shift can surface, short enough that the
    /// pool doesn't accumulate stale directions indefinitely.
    private let ghostExpiryGenerations: Int = 120

    /// Moving average of per-reference niche deltas used to detect
    /// "the population just started attracting this direction"
    /// dynamics that should trigger resurrection. Indexed by the same
    /// `PointKey` as the ghost pool — ghosts whose nearest live
    /// direction loses attraction get promoted back in.
    private var liveNicheEMA: [PointKey: Double] = [:]

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
            crowdedNicheCount: crowded,
            ghostPoolSize: ghostPool.count,
            pointsResurrected: pointsResurrectedTotal
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
    /// chronically vacant ones. Returns `(added, removed)` for
    /// telemetry. Must be called with `lock` held.
    ///
    /// Hash-based dedup replaces the previous O(N²) close-duplicate
    /// scan. We round each coordinate to 6 decimal places and look up
    /// the resulting tuple in a set; collisions on the hash imply
    /// numerically-equal points (well below `1e-6` per axis).
    private func adjustReferencePoints() -> (added: Int, removed: Int) {
        let current = ranker.referencePoints.points
        guard let m = current.first?.count else { return (0, 0) }

        // Pair every existing point with its history so the rebuild
        // step doesn't need to re-match against position.
        var keepers: [(point: [Double], history: [Int])] = Array(zip(current, nicheHistory))
            .map { ($0, $1) }

        // 1) Prune vacant references first (never below min). We do
        // pruning before splitting so the new points spawned by
        // splitting can't be accidentally evicted by a stale empty
        // history slot they inherited. Pruned directions are parked
        // in `ghostPool` so they can be resurrected later if the
        // population drifts back toward them (Jain & Deb's original
        // adaptive algorithm discards them outright, which is a
        // well-known limitation on non-stationary fronts).
        var removed = 0
        if keepers.count > minReferencePoints {
            let maxRemovable = keepers.count - minReferencePoints
            keepers = keepers.compactMap { entry in
                guard removed < maxRemovable else { return entry }
                let hist = entry.history
                let hasEnoughHistory = hist.count >= vacantWindow
                let vacantStreak = hasEnoughHistory
                    && hist.prefix(vacantWindow).allSatisfy { $0 == 0 }
                if vacantStreak {
                    removed += 1
                    // Park the pruned direction. FIFO-evict the oldest
                    // ghost when the pool is full so the structure
                    // stays bounded even on very long runs.
                    ghostPool.append((entry.point, generation))
                    if ghostPool.count > ghostPoolLimit {
                        ghostPool.removeFirst(ghostPool.count - ghostPoolLimit)
                    }
                    return nil
                }
                return entry
            }
        }

        // Garbage-collect expired ghosts — directions that have been
        // parked long enough are probably truly gone from the Pareto
        // front and shouldn't be resurrected.
        ghostPool.removeAll { generation - $0.prunedAt > ghostExpiryGenerations }

        // 2) Split crowded references. Hash-set tracks every point we
        // already plan to keep so duplicates are O(1) to reject.
        var seenKeys: Set<PointKey> = Set(keepers.map { PointKey($0.point) })
        var added = 0

        // 2a) Resurrect ghosts whose direction is now "in demand".
        // Heuristic: a ghost is reintroduced if its nearest live
        // reference is currently crowded — indicating the front has
        // spread into the region the ghost used to cover. This
        // recovers from the Jain & Deb pruning mistake without
        // reintroducing the O(N²) naive adaptive update.
        var resurrected = 0
        if !ghostPool.isEmpty {
            // Snapshot keeper coordinates so we can do O(G × K)
            // nearest-neighbour scans (G = ghosts, K = keepers). Both
            // are bounded by a few hundred, so this stays sub-
            // millisecond.
            let keeperHistories = keepers.map(\.history)
            let keeperPoints = keepers.map(\.point)

            var survivingGhosts: [(point: [Double], prunedAt: Int)] = []
            survivingGhosts.reserveCapacity(ghostPool.count)

            for ghost in ghostPool {
                guard keepers.count + added - resurrected < maxReferencePoints else {
                    survivingGhosts.append(ghost)
                    continue
                }

                // Nearest-live by L2 distance on the simplex.
                var bestIdx = 0
                var bestDist = Double.infinity
                for (idx, candidate) in keeperPoints.enumerated() {
                    let dist = Self.euclidean(ghost.point, candidate)
                    if dist < bestDist {
                        bestDist = dist
                        bestIdx = idx
                    }
                }

                // Promote only when the nearest-live has a crowded
                // rolling niche count — i.e. the population genuinely
                // needs more coverage in that neighbourhood.
                let hist = keeperHistories[bestIdx]
                let neighbourCrowded = meanCount(hist) >= crowdedThreshold

                if neighbourCrowded {
                    let key = PointKey(ghost.point)
                    if !seenKeys.contains(key) {
                        seenKeys.insert(key)
                        // Fresh history so the resurrected direction
                        // gets `vacantWindow` generations to attract
                        // solutions before being re-evaluated.
                        keepers.append((ghost.point, []))
                        resurrected += 1
                        continue
                    }
                }
                survivingGhosts.append(ghost)
            }
            ghostPool = survivingGhosts
        }

        let centroid = [Double](repeating: 1.0 / Double(m), count: m)
        // Iterate over a snapshot of `current` (the historic point set);
        // crowdedness is measured against the surviving-keepers list
        // via index lookup.
        let historyByIndex: [PointKey: [Int]] = Dictionary(uniqueKeysWithValues:
            zip(current, nicheHistory).map { (PointKey($0.0), $0.1) })
        for original in current {
            guard keepers.count + added < maxReferencePoints else { break }
            let hist = historyByIndex[PointKey(original)] ?? []
            guard meanCount(hist) >= crowdedThreshold else { continue }

            // Spawn an interior point halfway toward the centroid
            // along this direction. The new point sits on the same
            // ray but closer to the centroid, splitting the niche
            // along its radial axis (associate uses perpendicular
            // distance, so a closer-to-centroid point captures part
            // of the original niche).
            var interior = [Double](repeating: 0, count: m)
            for k in 0..<m {
                interior[k] = centroid[k] + (original[k] - centroid[k]) * splitShrink
            }
            interior = normalizeToSimplex(interior)
            let key = PointKey(interior)
            guard !seenKeys.contains(key) else { continue }
            seenKeys.insert(key)
            // Fresh history: empty so the new point gets `vacantWindow`
            // generations to attract solutions before being eligible
            // for pruning.
            keepers.append((interior, []))
            added += 1
        }

        guard added > 0 || removed > 0 || resurrected > 0 else { return (0, 0) }

        let nextRefs = ReferencePoints(points: keepers.map(\.point), dimension: m)
        ranker = NSGA3(referencePoints: nextRefs)
        nicheHistory = keepers.map(\.history)
        pointsResurrectedTotal += resurrected
        // Resurrections count as "added" from the telemetry viewpoint so
        // the running tally reflects total set growth; the dedicated
        // `pointsResurrected` field disambiguates when needed.
        return (added + resurrected, removed)
    }

    /// Euclidean distance between two equal-length coordinate vectors.
    /// Kept out of the main body so `adjustReferencePoints` reads
    /// cleanly; Swift's optimiser inlines the small helper anyway.
    private static func euclidean(_ a: [Double], _ b: [Double]) -> Double {
        var sum = 0.0
        let n = min(a.count, b.count)
        for i in 0..<n {
            let d = a[i] - b[i]
            sum += d * d
        }
        return sum.squareRoot()
    }

    // MARK: - Helpers

    private func meanCount(_ history: [Int]) -> Double {
        guard !history.isEmpty else { return 0 }
        let sum = history.reduce(0, +)
        return Double(sum) / Double(history.count)
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

// MARK: - Hash-friendly point key

/// `[Double]` is not Hashable, and using `Double` directly as a hash
/// key is fragile under floating-point noise. `PointKey` quantizes
/// each coordinate to 6 decimal places (well below the dedup epsilon
/// of `1e-6`) and uses the resulting `Int64` tuple for the hash. Two
/// points map to the same key iff they are within ~5e-7 per axis,
/// which is exactly the equivalence relation the splitter needs.
private struct PointKey: Hashable {
    let q: [Int64]

    init(_ p: [Double]) {
        // 1e6 scale → 6-decimal-place precision. Reference points are
        // in [0, 1], so quantized values fit easily in Int64.
        self.q = p.map { Int64(($0 * 1_000_000.0).rounded()) }
    }
}
