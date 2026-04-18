import Foundation
@testable import Bubo

// MARK: - Benchmark Statistics
//
// Paired tests for "does treatment differ from baseline". Sign test is too
// weak for small samples (50 pairs) on noisy fitness landscapes; Wilcoxon
// signed-rank uses magnitude information and bootstrap gives a confidence
// interval on the median delta. Together they answer two questions:
//
//   1. Is the median delta non-zero at p < 0.05? (Wilcoxon)
//   2. What's the 95% CI on the mean delta? (Bootstrap)
//
// The CI width also tells us "is our sample large enough to detect a 1-3%
// effect" — if the CI is ±5% on 50 pairs, any claim of "+2% improvement" is
// under the noise floor.

enum BenchmarkStatistics {

    // MARK: - Wilcoxon Signed-Rank Test (paired)

    struct WilcoxonResult {
        /// Sum of signed ranks (positive − negative).
        let statistic: Double
        /// Two-sided p-value approximated via normal approximation for n ≥ 10.
        /// For smaller n, returns 1 and the caller should prefer bootstrap CI.
        let pValue: Double
        /// Number of non-zero pairs used (zeros dropped per Wilcoxon convention).
        let effectiveN: Int
    }

    /// Paired Wilcoxon signed-rank test on (baseline, treatment) samples.
    /// Null hypothesis: the median of (treatment - baseline) is zero.
    /// Uses the normal approximation with tie correction; for n < 10 it
    /// returns pValue=1 so the caller knows the test is under-powered.
    static func wilcoxonSignedRank(
        baseline: [Double],
        treatment: [Double]
    ) -> WilcoxonResult {
        precondition(baseline.count == treatment.count, "paired samples must match")
        let diffs = zip(treatment, baseline).map { $0 - $1 }
        let nonZero = diffs.filter { $0 != 0 }
        let n = nonZero.count
        guard n >= 1 else {
            return WilcoxonResult(statistic: 0, pValue: 1, effectiveN: 0)
        }

        // Rank by absolute magnitude, resolve ties via mean rank.
        let indexed = nonZero.enumerated().map { ($0.offset, $0.element, abs($0.element)) }
        let sorted = indexed.sorted { $0.2 < $1.2 }

        // Assign mid-ranks to ties.
        var ranks = Array(repeating: 0.0, count: n)
        var tieCorrection = 0.0
        var i = 0
        while i < n {
            var j = i
            while j + 1 < n && sorted[j + 1].2 == sorted[i].2 { j += 1 }
            let meanRank = Double(i + j + 2) / 2.0   // 1-based ranks
            let tieSize = j - i + 1
            if tieSize > 1 {
                tieCorrection += Double(tieSize * tieSize * tieSize - tieSize)
            }
            for k in i...j {
                ranks[sorted[k].0] = meanRank
            }
            i = j + 1
        }

        var wPlus = 0.0
        var wMinus = 0.0
        for (idx, _, _) in indexed {
            let d = nonZero[idx]
            if d > 0 { wPlus += ranks[idx] } else { wMinus += ranks[idx] }
        }
        let w = wPlus - wMinus

        guard n >= 10 else {
            return WilcoxonResult(statistic: w, pValue: 1, effectiveN: n)
        }

        // Normal approximation with continuity + tie correction.
        let nD = Double(n)
        let meanW = 0.0
        let varW = (nD * (nD + 1) * (2 * nD + 1)) / 6.0 - tieCorrection / 2.0
        guard varW > 0 else {
            return WilcoxonResult(statistic: w, pValue: 1, effectiveN: n)
        }
        let z = (w - meanW) / varW.squareRoot()
        let p = 2.0 * (1.0 - standardNormalCDF(abs(z)))
        return WilcoxonResult(statistic: w, pValue: p, effectiveN: n)
    }

    // MARK: - Bootstrap Confidence Interval

    struct BootstrapResult {
        let meanDelta: Double
        let ciLower: Double
        let ciHigh: Double
        let relativeWidth: Double        // (high-low) / |mean|, or inf if mean ≈ 0
    }

    /// Percentile bootstrap 95% CI on the mean paired delta (treatment - baseline).
    /// 2000 resamples is a conventional default — wide enough to stabilize the
    /// percentiles, narrow enough to run in milliseconds on 50-pair inputs.
    /// Seed is fixed so the CI is reproducible across runs of the same data.
    static func bootstrapMeanDelta(
        baseline: [Double],
        treatment: [Double],
        resamples: Int = 2_000,
        seed: UInt64 = 0xB007_5BAB_0012_3456
    ) -> BootstrapResult {
        precondition(baseline.count == treatment.count, "paired samples must match")
        let diffs = zip(treatment, baseline).map { $0 - $1 }
        let n = diffs.count
        guard n > 0 else {
            return BootstrapResult(meanDelta: 0, ciLower: 0, ciHigh: 0, relativeWidth: .infinity)
        }

        var rng = SplitMix64(seed: seed)
        var means = [Double](repeating: 0, count: resamples)
        for r in 0..<resamples {
            var sum = 0.0
            for _ in 0..<n {
                let idx = Int(rng.next() % UInt64(n))
                sum += diffs[idx]
            }
            means[r] = sum / Double(n)
        }
        means.sort()
        let low = means[Int(0.025 * Double(resamples))]
        let high = means[min(resamples - 1, Int(0.975 * Double(resamples)))]
        let mean = diffs.reduce(0, +) / Double(n)
        let width = abs(mean) > 1e-12 ? (high - low) / abs(mean) : .infinity
        return BootstrapResult(
            meanDelta: mean,
            ciLower: low,
            ciHigh: high,
            relativeWidth: width
        )
    }

    // MARK: - Standard Normal CDF

    /// Abramowitz–Stegun 7.1.26 rational approximation to the standard
    /// normal CDF. Accurate to ~7.5e-8 — well below any threshold we'd
    /// use for "is p < 0.05".
    private static func standardNormalCDF(_ x: Double) -> Double {
        let t = 1.0 / (1.0 + 0.2316419 * abs(x))
        let d = 0.39894228 * exp(-x * x / 2.0)
        let poly = t * (0.319381530
            + t * (-0.356563782
            + t * (1.781477937
            + t * (-1.821255978
            + t * 1.330274429))))
        let prob = d * poly
        return x > 0 ? 1.0 - prob : prob
    }
}

// MARK: - SplitMix64 (local)
//
// The benchmark must be independent of GA seeding so that swapping the GA's
// RNG implementation doesn't change p-values. SplitMix64 is a standard
// seedable 64-bit PRNG used inside the std libs of several languages; fine
// for resampling where we only need uniform-in-[0,n) integers.

private struct SplitMix64 {
    private var state: UInt64
    init(seed: UInt64) { self.state = seed &+ 0x9E37_79B9_7F4A_7C15 }
    mutating func next() -> UInt64 {
        state = state &+ 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

