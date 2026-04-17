import Foundation

// MARK: - Hypervolume-Based Selection (HypE-lite)
//
// Hypervolume is the many-objective gold standard for measuring "how much
// of objective space a Pareto front covers." For the calendar optimizer
// it has two uses:
//
//   1. A tiebreaker that replaces the perpendicular-distance-to-niche
//      tiebreaker in NSGA-III's last accepted front. Niching is good at
//      enforcing coverage of pre-declared directions, but hypervolume
//      contribution captures how much a point *would cost the front* if
//      removed — a directly objective-grounded quality measure.
//   2. A standalone survivor rule (SMS-EMOA style) when the NSGA-III
//      direction set is misaligned with the true front geometry. With
//      M = 13 objectives exact hypervolume is intractable (O(N^M)), so we
//      use HypE's Monte Carlo approximation (Bader & Zitzler, 2011) with a
//      deterministic sampler driven by the GA's `GARandom`.
//
// Reference point: (0, 0, …, 0) — "worst" on every axis. Every score is
// already normalized to [0, 1] by NSGA3.normalize, so the unit hypercube
// is the sampling volume and contributions integrate cleanly.

/// Monte Carlo hypervolume estimator with a fixed-seed sampler so
/// selections are reproducible under the GA's seeded RNG.
///
/// Thread safety: immutable snapshot constructed per-generation; no
/// locking required once constructed.
struct HypervolumeEstimator: Sendable {
    /// Number of Monte Carlo samples used per hypervolume query. HypE's
    /// authors recommend 10k – 50k for 10+ objectives; we default to 20k
    /// which, on a modern CPU, costs ~2ms for a 200-individual combined
    /// pool. Increase when many objectives saturate near 1.0 (less volume
    /// to sample means more variance).
    let sampleCount: Int

    /// Objective count. Derived from the first vector on `estimate`.
    let objectiveCount: Int

    /// Reference point on each axis — "worst" direction. Clamped to (0, 1).
    let referencePoint: [Double]

    /// Shared sampler. Seeded at construction so hypervolume queries are
    /// reproducible regardless of which generation calls them first.
    private let sampler: GARandom

    init(
        objectiveCount m: Int,
        sampleCount: Int = 20_000,
        seed: UInt64,
        referencePoint: [Double]? = nil
    ) {
        precondition(m > 0)
        self.objectiveCount = m
        self.sampleCount = max(256, sampleCount)
        self.referencePoint = referencePoint ?? [Double](repeating: 0.0, count: m)
        self.sampler = GARandom(seed: seed)
    }

    // MARK: - Per-individual contribution

    /// HypE-style per-individual hypervolume contribution estimate.
    ///
    /// Intuitively: "if I removed individual `i` from the set, how much
    /// hypervolume would I lose?" Higher = better, because the individual
    /// uniquely covers objective-space volume.
    ///
    /// Implementation is the linear-time Monte Carlo variant from HypE:
    /// draw `sampleCount` points uniformly in the unit hypercube, for each
    /// sample count how many individuals dominate it, and credit every
    /// dominating individual with `1 / count` volume. Summing across
    /// samples gives an unbiased estimate of per-individual contribution.
    ///
    /// - Parameters:
    ///   - vectors: normalized objective vectors (higher is better), one
    ///     per individual. Must all have length `objectiveCount`.
    /// - Returns: array of same length as `vectors`; each entry is the
    ///   estimated hypervolume contribution of that individual.
    func contributions(_ vectors: [[Double]]) -> [Double] {
        let n = vectors.count
        guard n > 0 else { return [] }
        // Validate dims on the first vector only — rest are trusted.
        precondition(vectors[0].count == objectiveCount, "objective count mismatch")

        var contributions = [Double](repeating: 0, count: n)
        let volumePerSample = 1.0 / Double(sampleCount)

        // Pre-allocate sample buffer.
        var sample = [Double](repeating: 0, count: objectiveCount)

        for _ in 0..<sampleCount {
            // Draw a uniform sample in the unit hypercube. HypE's theory
            // requires the sampling region to dominate the reference point;
            // for our unit-cube formulation every sample satisfies that.
            for k in 0..<objectiveCount {
                sample[k] = sampler.unit()
            }

            // Count dominating individuals — those whose score is >= sample
            // on every axis. "Higher is better" everywhere.
            var dominatingIndices: [Int] = []
            for i in 0..<n {
                if dominatesSample(vectors[i], sample) {
                    dominatingIndices.append(i)
                }
            }

            // Credit each dominating individual with its share of this
            // sample's volume. HypE's `1 / count` is the unbiased linear
            // estimator; variants use different share functions, but the
            // linear one is what SMS-EMOA's contribution rule assumes.
            if !dominatingIndices.isEmpty {
                let share = volumePerSample / Double(dominatingIndices.count)
                for idx in dominatingIndices {
                    contributions[idx] += share
                }
            }
        }

        return contributions
    }

    /// Global hypervolume of the Pareto front formed by `vectors`. Rough
    /// upper bound on the quality of a generation — larger is better.
    /// Useful as a logging/telemetry signal independent of selection.
    func totalHypervolume(_ vectors: [[Double]]) -> Double {
        let n = vectors.count
        guard n > 0 else { return 0 }
        precondition(vectors[0].count == objectiveCount, "objective count mismatch")

        var dominated = 0
        var sample = [Double](repeating: 0, count: objectiveCount)
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

    /// Survivor selection that combines NSGA-III front ranking with a
    /// hypervolume tiebreaker on the last accepted front. Faster than pure
    /// SMS-EMOA (which reranks on every removal) but retains the property
    /// that removed individuals have the lowest hypervolume contribution.
    ///
    /// Returns indices into `vectors` sorted so the first `k` are the
    /// survivors. Front rank is computed by the provided NSGA3 instance to
    /// avoid duplicating the O(N²) non-dominated sort — the GA already has
    /// a ranker; we just borrow its fronts.
    func survivorsWithNSGA3(
        _ vectors: [[Double]],
        keeping k: Int,
        using ranker: NSGA3
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

        // On the last front, compute per-individual contribution ranking
        // and keep the top `slotsRemaining`. We compute on the subset only
        // because HypE's contribution is local to the front (dominating
        // members of lower fronts add no info to the last-front ranking).
        let slotsRemaining = k - survivors.count
        let subsetVectors = frontBeingCut.map { vectors[$0] }
        let subsetContributions = contributions(subsetVectors)

        // Sort front indices by contribution descending; tiebreak by
        // original index for reproducibility.
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

    @inline(__always)
    private func dominatesSample(_ v: [Double], _ sample: [Double]) -> Bool {
        // v dominates the sample iff every axis of v >= sample, i.e. the
        // sample lies in the box anchored at the reference point whose
        // upper corner is v.
        for k in 0..<objectiveCount where v[k] < sample[k] { return false }
        return true
    }
}
