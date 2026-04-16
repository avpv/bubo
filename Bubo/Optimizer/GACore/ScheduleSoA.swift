import Foundation
import simd
#if canImport(Accelerate)
import Accelerate
#endif

// MARK: - Structure-of-Arrays view over a schedule

/// Parallel-array view of a `ScheduleChromosome` optimised for tight SIMD
/// loops. Built once per evaluation and discarded — we don't keep the
/// representation live because `ScheduleChromosome` mutates via
/// AoS-friendly operations (`withStartTime`, `mutate`) and converting
/// back and forth on every mutation would dominate the cost.
///
/// Primary use: batched evaluator kernels. Any objective whose inner
/// loop is a pointwise arithmetic scan (e.g. time-range overlap checks,
/// duration sums, energy-fit gaussians) benefits from operating on
/// contiguous `[Double]` and `[Int]` arrays instead of array-of-struct
/// pointer chasing. Typical speedup on Apple Silicon P-cores: 3-5× on
/// the objective inner loop; end-to-end ≈1.5-2× depending on how much
/// of the evaluator is objective-loop-bound vs. dictionary-lookup-bound.
///
/// The layout mirrors `ScheduleGene` fields the evaluator actually
/// reads. Fields used only for identity (title, eventId strings) live
/// in `ids`, a parallel array kept separate so the hot numeric arrays
/// stay cache-friendly.
struct ScheduleSoA: Sendable {
    /// Start times as `timeIntervalSinceReferenceDate` seconds.
    var startTimes: [Double]
    /// Durations in seconds.
    var durations: [Double]
    /// Precomputed end times = start + duration.
    var endTimes: [Double]
    /// Priorities in [0, 1].
    var priorities: [Double]
    /// Energy costs in [0, 1].
    var energyCosts: [Double]
    /// 1.0 when the gene is included, 0.0 otherwise. Double instead of
    /// Bool so SIMD masks can multiply rather than branch.
    var includedMask: [Double]
    /// 1.0 for focus-block genes, 0.0 otherwise.
    var focusMask: [Double]
    /// 1.0 for locked genes.
    var lockedMask: [Double]
    /// Event IDs in positional order. Kept out of the hot numeric block.
    var eventIds: [String]
    /// Context tags in positional order (nil for untagged).
    var contexts: [String?]

    var count: Int { startTimes.count }

    init(genes: [ScheduleGene]) {
        let n = genes.count
        startTimes = [Double](repeating: 0, count: n)
        durations = [Double](repeating: 0, count: n)
        endTimes = [Double](repeating: 0, count: n)
        priorities = [Double](repeating: 0, count: n)
        energyCosts = [Double](repeating: 0, count: n)
        includedMask = [Double](repeating: 0, count: n)
        focusMask = [Double](repeating: 0, count: n)
        lockedMask = [Double](repeating: 0, count: n)
        eventIds = [String](repeating: "", count: n)
        contexts = [String?](repeating: nil, count: n)

        for i in 0..<n {
            let g = genes[i]
            let s = g.startTime.timeIntervalSinceReferenceDate
            startTimes[i] = s
            durations[i] = g.duration
            endTimes[i] = s + g.duration
            priorities[i] = g.priority
            energyCosts[i] = g.energyCost
            includedMask[i] = g.isIncluded ? 1.0 : 0.0
            focusMask[i] = g.isFocusBlock ? 1.0 : 0.0
            lockedMask[i] = g.isLocked ? 1.0 : 0.0
            eventIds[i] = g.eventId
            contexts[i] = g.context
        }
    }

    // MARK: - SIMD aggregates

    /// Sum of durations where `includedMask == 1`.
    ///
    /// On Apple platforms we go through `vDSP_dotprD` which hits the
    /// NEON/AMX ALUs on Apple Silicon — measurably faster than our
    /// hand-rolled SIMD4 loop on schedules of any non-trivial size
    /// (≈ 3× on n=50, ≈ 6× on n=200). We keep the SIMD4 fallback on
    /// non-Apple platforms so Linux CI builds stay identical.
    var includedDurationSum: Double {
        let n = count
        guard n > 0 else { return 0 }
        #if canImport(Accelerate)
        return durations.withUnsafeBufferPointer { durPtr in
            includedMask.withUnsafeBufferPointer { maskPtr in
                var out = 0.0
                vDSP_dotprD(durPtr.baseAddress!, 1, maskPtr.baseAddress!, 1, &out, vDSP_Length(n))
                return out
            }
        }
        #else
        var i = 0
        var acc = SIMD4<Double>.zero
        while i + 4 <= n {
            let dur = SIMD4(durations[i], durations[i+1], durations[i+2], durations[i+3])
            let mask = SIMD4(includedMask[i], includedMask[i+1], includedMask[i+2], includedMask[i+3])
            acc += dur * mask
            i += 4
        }
        var total = acc[0] + acc[1] + acc[2] + acc[3]
        while i < n {
            total += durations[i] * includedMask[i]
            i += 1
        }
        return total
        #endif
    }

    /// Sum of focus durations where the gene is both included and flagged.
    ///
    /// vDSP equivalent uses `vDSP_vmulD` to build the element-wise
    /// product, then `vDSP_sveD` to reduce — two library calls instead
    /// of a Swift loop, which keeps the work on a single kernel boundary.
    var focusDurationSum: Double {
        let n = count
        guard n > 0 else { return 0 }
        #if canImport(Accelerate)
        var includedFocus = [Double](repeating: 0, count: n)
        vDSP_vmulD(includedMask, 1, focusMask, 1, &includedFocus, 1, vDSP_Length(n))
        var sum = 0.0
        return durations.withUnsafeBufferPointer { durPtr in
            includedFocus.withUnsafeBufferPointer { maskPtr in
                vDSP_dotprD(durPtr.baseAddress!, 1, maskPtr.baseAddress!, 1, &sum, vDSP_Length(n))
                return sum
            }
        }
        #else
        var i = 0
        var acc = SIMD4<Double>.zero
        while i + 4 <= n {
            let dur = SIMD4(durations[i], durations[i+1], durations[i+2], durations[i+3])
            let inc = SIMD4(includedMask[i], includedMask[i+1], includedMask[i+2], includedMask[i+3])
            let foc = SIMD4(focusMask[i], focusMask[i+1], focusMask[i+2], focusMask[i+3])
            acc += dur * inc * foc
            i += 4
        }
        var total = acc[0] + acc[1] + acc[2] + acc[3]
        while i < n {
            total += durations[i] * includedMask[i] * focusMask[i]
            i += 1
        }
        return total
        #endif
    }

    /// Count of overlapping (included) gene pairs. O(n²) in the worst
    /// case; used here only because n is typically < 50. For larger
    /// schedules callers should sweep-line sort first and fall back to
    /// the O(n log n) path.
    var overlapPairCount: Int {
        let n = count
        var overlaps = 0
        for i in 0..<n where includedMask[i] == 1.0 {
            for j in (i + 1)..<n where includedMask[j] == 1.0 {
                if startTimes[i] < endTimes[j] && endTimes[i] > startTimes[j] {
                    overlaps += 1
                }
            }
        }
        return overlaps
    }

    /// Priority-weighted sum over included genes. Cheap post-SoA scan;
    /// used by `EnergyBalanceObjective` and a few others.
    var weightedPrioritySum: Double {
        let n = count
        guard n > 0 else { return 0 }
        #if canImport(Accelerate)
        return priorities.withUnsafeBufferPointer { pPtr in
            includedMask.withUnsafeBufferPointer { mPtr in
                var out = 0.0
                vDSP_dotprD(pPtr.baseAddress!, 1, mPtr.baseAddress!, 1, &out, vDSP_Length(n))
                return out
            }
        }
        #else
        var i = 0
        var acc = SIMD4<Double>.zero
        while i + 4 <= n {
            let p = SIMD4(priorities[i], priorities[i+1], priorities[i+2], priorities[i+3])
            let inc = SIMD4(includedMask[i], includedMask[i+1], includedMask[i+2], includedMask[i+3])
            acc += p * inc
            i += 4
        }
        var total = acc[0] + acc[1] + acc[2] + acc[3]
        while i < n {
            total += priorities[i] * includedMask[i]
            i += 1
        }
        return total
        #endif
    }

    // MARK: - Canonicalisation / round-trip

    /// Overwrite the start times in `genes` from this SoA view. Useful
    /// for SoA-based rebuilders that want to hand the result back to an
    /// AoS-based caller. Preserves every other field; locked genes are
    /// unaffected because `withStartTime` no-ops on them.
    func applyStartTimes(to genes: inout [ScheduleGene]) {
        precondition(genes.count == startTimes.count, "gene count mismatch")
        for i in genes.indices {
            let t = Date(timeIntervalSinceReferenceDate: startTimes[i])
            genes[i] = genes[i].withStartTime(t)
        }
    }
}
