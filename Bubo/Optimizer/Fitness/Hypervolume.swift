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
struct HypervolumeEstimator: Sendable {
    /// Samples per `contributions` / `totalHypervolume` call.
    let sampleCount: Int

    /// Objective count.
    let objectiveCount: Int

    /// Reference point (per-axis "worst"). For unit-cube objectives
    /// this is the origin.
    let referencePoint: ContiguousArray<Double>

    /// Base seed for the per-call sampler. Mixed with a salt on each
    /// call so concurrent invocations get disjoint streams.
    let baseSeed: UInt64

    init(
        objectiveCount m: Int,
        sampleCount: Int = 8_000,
        seed: UInt64,
        referencePoint: ContiguousArray<Double>? = nil
    ) {
        precondition(m > 0)
        self.objectiveCount = m
        self.sampleCount = max(256, sampleCount)
        self.referencePoint = referencePoint ?? ContiguousArray(repeating: 0.0, count: m)
        self.baseSeed = seed
    }

    // MARK: - Per-individual contribution

    /// Estimate per-individual hypervolume contribution. Higher means
    /// the individual covers volume that no other member of the
    /// population covers.
    func contributions(
        _ vectors: [[Double]],
        callSalt: UInt64 = 0
    ) -> [Double] {
        let n = vectors.count
        guard n > 0 else { return [] }
        precondition(vectors[0].count == objectiveCount, "objective count mismatch")

        let sampler = makeSampler(salt: callSalt)
        var contributions = ContiguousArray<Double>(repeating: 0.0, count: n)
        var sample = ContiguousArray<Double>(repeating: 0.0, count: objectiveCount)
        var dominators = ContiguousArray<Int>()
        dominators.reserveCapacity(min(n, 64))

        let volumePerSample = 1.0 / Double(sampleCount)

        for _ in 0..<sampleCount {
            for k in 0..<objectiveCount {
                sample[k] = sampler.unit()
            }
            dominators.removeAll(keepingCapacity: true)
            for i in 0..<n where dominatesSample(vectors[i], sample) {
                dominators.append(i)
            }
            if !dominators.isEmpty {
                let share = volumePerSample / Double(dominators.count)
                for idx in dominators { contributions[idx] += share }
            }
        }
        return Array(contributions)
    }

    /// Total hypervolume of the population's union — the "is the
    /// front getting bigger?" signal.
    func totalHypervolume(
        _ vectors: [[Double]],
        callSalt: UInt64 = 0
    ) -> Double {
        let n = vectors.count
        guard n > 0 else { return 0 }
        precondition(vectors[0].count == objectiveCount, "objective count mismatch")

        let sampler = makeSampler(salt: callSalt)
        var sample = ContiguousArray<Double>(repeating: 0.0, count: objectiveCount)
        var dominated = 0
        for _ in 0..<sampleCount {
            for k in 0..<objectiveCount { sample[k] = sampler.unit() }
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
    func survivorsWithNSGA3(
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
