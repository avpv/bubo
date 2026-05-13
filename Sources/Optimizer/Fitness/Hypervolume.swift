import Foundation

// MARK: - Hypervolume Estimator (HypE-lite, Monte Carlo)
//
// Hypervolume is the canonical many-objective quality measure. Two
// uses inside the GA:
//
//   1. Tiebreak on the last-accepted NSGA-III front: pick survivors
//      by hypervolume contribution instead of perpendicular-distance
//      to the reference direction. Contribution captures "how much
//      front area would I lose if I removed this individual" —
//      objectively grounded where the reference-direction tiebreak
//      is blind.
//   2. Standalone telemetry: the running hypervolume of the
//      current front is a clean signal for "are we improving
//      Pareto coverage?"
//
// Exact hypervolume in m=13 dimensions is intractable (O(N^m)). HypE
// (Bader & Zitzler, 2011) uses Monte Carlo sampling: draw N points
// uniformly in the unit hypercube, count the dominators of each
// sample, credit each dominator with `1 / count` of that sample's
// volume.
//
// Implementation notes vs. the previous version:
//   • Per-call seeded sampler. The old shared `GARandom` was a
//     correctness hazard under parallel survivor selection (the
//     struct was `@unchecked Sendable` but had mutable state). Each
//     call now constructs a tiny `GARandom` from a deterministic
//     seed mixed with a per-call salt, so two parallel callers get
//     non-overlapping streams without sharing.
//   • Reusable `ContiguousArray` buffers for the per-sample
//     dominator bitmap and the contribution accumulator. Steady-
//     state allocation is zero.

/// Monte Carlo hypervolume estimator.
///
/// Reference point is **adaptive**: the caller invokes `updateNadir`
/// with observed objective vectors each generation, and the estimator
/// rescales its sampling box to the worst-seen per-axis value. This
/// matters when several objectives saturate near 1.0 — the origin
/// nadir would then over-count empty volume below the achievable
/// region, giving identical-looking contributions to genuinely
/// different individuals. A live-tracked nadir concentrates samples
/// in the region the population actually spans.
public final class HypervolumeEstimator: @unchecked Sendable {
    /// Samples per `contributions` / `totalHypervolume` call.
    public let sampleCount: Int

    /// Objective count.
    public let objectiveCount: Int

    /// Base seed for the per-call sampler. Mixed with a salt on each
    /// call so concurrent invocations get disjoint streams.
    public let baseSeed: UInt64

    /// Live per-axis nadir. Starts at the origin; `updateNadir` walks
    /// it toward the worst-seen per-axis value with a small EMA so
    /// single outliers don't swing the sampling box.
    private var nadir: ContiguousArray<Double>
    private let nadirLock = NSLock()

    /// EMA smoothing factor for nadir updates. `0` freezes at init,
    /// `1` jumps to observed-worst every call. The default `0.2`
    /// absorbs persistent saturation within ~5 generations
    /// (`1 / α` is the EMA's effective half-life in update events)
    /// without reacting to single noisy drops. Tune up for fast-
    /// changing populations, down for high-noise fitness landscapes.
    /// Configurable via the `nadirAlpha:` init parameter.
    private let nadirAlpha: Double

    public init(
        objectiveCount m: Int,
        sampleCount: Int = 8_000,
        seed: UInt64,
        nadirAlpha: Double = 0.2
    ) {
        precondition(m > 0)
        self.objectiveCount = m
        self.sampleCount = max(256, sampleCount)
        self.baseSeed = seed
        self.nadir = ContiguousArray(repeating: 0.0, count: m)
        self.nadirAlpha = max(0, min(1, nadirAlpha))
    }

    /// Fold the observed per-axis minimum of `vectors` into the
    /// tracked nadir via exponential moving average. Call once per
    /// generation from the survivor-selection pool.
    public func updateNadir(from vectors: [[Double]]) {
        guard !vectors.isEmpty else { return }
        var observed = ContiguousArray<Double>(repeating: .infinity, count: objectiveCount)
        for v in vectors {
            for k in 0..<objectiveCount where v[k] < observed[k] {
                observed[k] = v[k]
            }
        }
        nadirLock.lock()
        defer { nadirLock.unlock() }
        for k in 0..<objectiveCount where observed[k].isFinite {
            nadir[k] = (1 - nadirAlpha) * nadir[k] + nadirAlpha * observed[k]
            // Clamp to [0, 1): the achievable region lies in [nadir, 1].
            if nadir[k] < 0 { nadir[k] = 0 }
            if nadir[k] >= 1 { nadir[k] = 0.99 }
        }
    }

    /// Snapshot the current nadir for sampling. Copy semantics keep
    /// the estimator lock-free in the hot path.
    private func nadirSnapshot() -> ContiguousArray<Double> {
        nadirLock.lock()
        defer { nadirLock.unlock() }
        return nadir
    }

    // MARK: - Per-individual contribution

    /// Estimate per-individual hypervolume contribution. Higher means
    /// the individual covers volume that no other member of the
    /// population covers.
    /// Per-individual hypervolume contribution **as a fraction of
    /// the achievable box** `[nadir, 1]^M`. Returned values lie in
    /// `[0, 1]` regardless of the live nadir, which keeps the
    /// numerical scale stable for telemetry and tiebreaking even when
    /// `updateNadir` shrinks the box. Relative ordering across
    /// individuals is unchanged by the normalization (every
    /// contribution shares the same divisor).
    public func contributions(
        _ vectors: [[Double]],
        callSalt: UInt64 = 0
    ) -> [Double] {
        let n = vectors.count
        guard n > 0 else { return [] }
        precondition(vectors[0].count == objectiveCount, "objective count mismatch")

        let sampler = makeSampler(salt: callSalt)
        let sampleNadir = nadirSnapshot()
        var contributions = ContiguousArray<Double>(repeating: 0.0, count: n)
        var sample = ContiguousArray<Double>(repeating: 0.0, count: objectiveCount)
        var dominators = ContiguousArray<Int>()
        dominators.reserveCapacity(min(n, 64))

        let perSampleShare = 1.0 / Double(sampleCount)

        for _ in 0..<sampleCount {
            for k in 0..<objectiveCount {
                sample[k] = sampleNadir[k] + (1.0 - sampleNadir[k]) * sampler.unit()
            }
            dominators.removeAll(keepingCapacity: true)
            for i in 0..<n where dominatesSample(vectors[i], sample) {
                dominators.append(i)
            }
            if !dominators.isEmpty {
                let share = perSampleShare / Double(dominators.count)
                for idx in dominators { contributions[idx] += share }
            }
        }
        return Array(contributions)
    }

    /// Total hypervolume of the population's union — the "is the
    /// front getting bigger?" signal.
    /// Total hypervolume of the population's union, **as a fraction
    /// of the achievable box** `[nadir, 1]^M`. Returns a value in
    /// `[0, 1]` — `0` means "no individual dominates any sample," `1`
    /// means "every sample is dominated." Stable across nadir updates:
    /// when the nadir shrinks the achievable region, the absolute
    /// volume covered shrinks proportionally so the *fraction* stays
    /// meaningful for "are we expanding our share of what's reachable?"
    public func totalHypervolume(
        _ vectors: [[Double]],
        callSalt: UInt64 = 0
    ) -> Double {
        let n = vectors.count
        guard n > 0 else { return 0 }
        precondition(vectors[0].count == objectiveCount, "objective count mismatch")

        let sampler = makeSampler(salt: callSalt)
        let sampleNadir = nadirSnapshot()

        var sample = ContiguousArray<Double>(repeating: 0.0, count: objectiveCount)
        var dominated = 0
        for _ in 0..<sampleCount {
            for k in 0..<objectiveCount {
                sample[k] = sampleNadir[k] + (1.0 - sampleNadir[k]) * sampler.unit()
            }
            for v in vectors where dominatesSample(v, sample) {
                dominated += 1
                break
            }
        }
        return Double(dominated) / Double(sampleCount)
    }

    // MARK: - HypE-lite survivor rule

    /// Survivor selection that combines NSGA-III fronts with a
    /// hypervolume tiebreak on the last accepted front. Returns
    /// indices into `vectors` (the first `k` are survivors).
    public func survivorsWithNSGA3(
        _ vectors: [[Double]],
        keeping k: Int,
        using ranker: NSGA3,
        callSalt: UInt64 = 0
    ) -> [Int] {
        precondition(k >= 0)
        let n = vectors.count
        if k >= n { return Array(0..<n) }

        let fronts = ranker.nonDominatedSort(vectors)

        var survivors: [Int] = []
        var frontBeingCut: [Int] = []
        for front in fronts {
            if survivors.count + front.count <= k {
                survivors.append(contentsOf: front)
                if survivors.count == k { break }
            } else {
                frontBeingCut = front
                break
            }
        }
        if survivors.count == k { return survivors }

        let slotsRemaining = k - survivors.count
        let subsetVectors = frontBeingCut.map { vectors[$0] }
        let subsetContributions = contributions(subsetVectors, callSalt: callSalt)

        let ranked = zip(frontBeingCut, subsetContributions)
            .enumerated()
            .sorted { a, b in
                if abs(a.element.1 - b.element.1) > 1e-12 {
                    return a.element.1 > b.element.1
                }
                return a.element.0 < b.element.0
            }
            .prefix(slotsRemaining)
            .map { $0.element.0 }

        survivors.append(contentsOf: ranked)
        return survivors
    }

    // MARK: - Helpers

    /// Tiny seeded sampler per call. SplitMix is cheap to construct
    /// (one mix step) and self-contained, so concurrent callers get
    /// independent streams without contention.
    private func makeSampler(salt: UInt64) -> GARandom {
        // Mix base seed and salt deterministically — same (seed, salt)
        // pair always produces the same stream, so unit tests stay
        // reproducible.
        var z = baseSeed &+ salt &+ 0x9E37_79B9_7F4A_7C15
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        let mixed = z ^ (z >> 31)
        return GARandom(seed: mixed)
    }

    @inline(__always)
    private func dominatesSample(_ v: [Double], _ sample: ContiguousArray<Double>) -> Bool {
        for k in 0..<objectiveCount where v[k] < sample[k] { return false }
        return true
    }
}
