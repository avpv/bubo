import Foundation
@testable import Bubo

// MARK: - Benchmark Metrics
//
// Pareto-front quality measures for comparing two optimizer variants on
// the same workload. Scalar fitness delta is insufficient for 14-objective
// NSGA-III — a variant may raise the weighted mean while collapsing front
// diversity, which is a regression dressed up as an improvement.
//
// Three metrics here, one wrapper:
//
//   hypervolume(vectors:) — reuses the production HypervolumeEstimator so
//     variant comparisons use the same machinery as survivor selection.
//     Higher = better. Maximization form (each objective already in [0,1]
//     with 1 = ideal).
//
//   igd(front:referenceFront:) — inverted generational distance. Measures
//     how close `front` approximates `referenceFront`. Lower = better.
//     Reference is usually the union of all observed fronts (best-known
//     approximation).
//
//   spread(front:) — front diversity. Sum of pairwise L2 distances on
//     unit axes, normalized by count. Higher = more diverse (avoids the
//     "all collapse to one corner" pathology that scalar fitness misses).
//
//   dominates(frontA:frontB:) — boolean plus fractions. Answers "is A
//     strictly better than B on Pareto terms": every B point dominated by
//     some A point, and not vice versa.

enum BenchmarkMetrics {

    // MARK: - Hypervolume

    /// Estimate the unit-cube-normalized hypervolume covered by `vectors`.
    /// Reuses the production `HypervolumeEstimator` with a fixed seed so
    /// the same input produces the same estimate across runs.
    ///
    /// Objectives are maximization-sense in [0,1]; the estimator internally
    /// samples the unit hypercube and counts dominated samples. Adaptive
    /// nadir is not updated here — benchmarks want a stable reference
    /// across variants, not a drifting one.
    static func hypervolume(
        _ vectors: [[Double]],
        sampleCount: Int = 8_000,
        seed: UInt64 = 0xBE_BE_1234_5678
    ) -> Double {
        guard let first = vectors.first, !first.isEmpty else { return 0 }
        let estimator = HypervolumeEstimator(
            objectiveCount: first.count,
            sampleCount: sampleCount,
            seed: seed
        )
        return estimator.totalHypervolume(vectors)
    }

    // MARK: - Inverted Generational Distance (IGD)

    /// For each reference point, take the L2 distance to the nearest point
    /// in `front`; average those. Lower = front approximates reference better.
    ///
    /// When reference is the union of baseline + treatment fronts, IGD of
    /// each variant measures how well it covers the best-known approximation.
    /// IGD(A) < IGD(B) ⇒ A is closer to the combined frontier.
    static func igd(front: [[Double]], referenceFront: [[Double]]) -> Double {
        guard !referenceFront.isEmpty, !front.isEmpty else { return .infinity }
        var sum = 0.0
        for ref in referenceFront {
            var nearest = Double.infinity
            for p in front {
                let d = l2(ref, p)
                if d < nearest { nearest = d }
            }
            sum += nearest
        }
        return sum / Double(referenceFront.count)
    }

    // MARK: - Spread / Diversity

    /// Mean pairwise L2 distance across front points, normalized by pair count.
    /// Higher = more diverse coverage. Zero for singleton fronts.
    /// Independent of hypervolume: two fronts with equal HV can have very
    /// different spread (cluster vs. even coverage).
    static func spread(_ front: [[Double]]) -> Double {
        let n = front.count
        guard n > 1 else { return 0 }
        var sum = 0.0
        var pairs = 0
        for i in 0..<(n - 1) {
            for j in (i + 1)..<n {
                sum += l2(front[i], front[j])
                pairs += 1
            }
        }
        return pairs > 0 ? sum / Double(pairs) : 0
    }

    // MARK: - Dominance Test

    struct DominanceReport {
        /// Fraction of B points dominated by at least one A point.
        let bDominatedByA: Double
        /// Fraction of A points dominated by at least one B point.
        let aDominatedByB: Double
        /// True when A strictly dominates B (>50% of B dominated and <20% of A dominated).
        /// The asymmetric thresholds tolerate a few noisy outliers in A without letting
        /// B claim parity when A is really winning on the bulk of points.
        var aStrictlyDominatesB: Bool {
            bDominatedByA > 0.5 && aDominatedByB < 0.2
        }
    }

    /// Compare two fronts in Pareto-dominance terms. Objectives are
    /// maximization-sense (higher better) — internal `dominates` helper
    /// reflects that.
    static func compareDominance(
        frontA: [[Double]],
        frontB: [[Double]]
    ) -> DominanceReport {
        let bDominated = fractionDominated(target: frontB, by: frontA)
        let aDominated = fractionDominated(target: frontA, by: frontB)
        return DominanceReport(
            bDominatedByA: bDominated,
            aDominatedByB: aDominated
        )
    }

    // MARK: - Helpers

    private static func fractionDominated(target: [[Double]], by source: [[Double]]) -> Double {
        guard !target.isEmpty else { return 0 }
        var count = 0
        for t in target {
            for s in source where dominates(s, t) {
                count += 1
                break
            }
        }
        return Double(count) / Double(target.count)
    }

    /// Maximization-sense dominance: `a` dominates `b` iff every component
    /// of `a` is ≥ the corresponding in `b`, and at least one is strictly greater.
    private static func dominates(_ a: [Double], _ b: [Double]) -> Bool {
        guard a.count == b.count else { return false }
        var anyBetter = false
        for i in 0..<a.count {
            if a[i] < b[i] { return false }
            if a[i] > b[i] { anyBetter = true }
        }
        return anyBetter
    }

    private static func l2(_ a: [Double], _ b: [Double]) -> Double {
        guard a.count == b.count else { return .infinity }
        var sum = 0.0
        for i in 0..<a.count {
            let d = a[i] - b[i]
            sum += d * d
        }
        return sum.squareRoot()
    }
}

