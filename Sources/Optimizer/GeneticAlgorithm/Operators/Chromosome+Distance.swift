import Foundation
import simd

// MARK: - ScheduleChromosome distance
//
// Genotypic distance for diversity measurement, crowding, and fitness
// sharing. Extracted from `Chromosome.swift` so the SIMD distance
// implementation lives with its consumers (NSGA-III crowding,
// `genotypicDiversity`) rather than buried 3000 lines into the struct.

public extension ScheduleChromosome {

    // MARK: - Genotypic Distance

    /// Normalized distance between two schedule chromosomes in [0, 1].
    /// Combines time displacement and inclusion differences across genes.
    ///
    /// - Complexity: O(n) — other.genes is indexed by eventId once. Previously
    ///   O(n²) due to repeated `.first(where:)` lookups, which was a hot path
    ///   because `genotypicDiversity` and crowding both call it every generation.
    /// - SIMD: the aligned-by-index path (both parents descend from the same
    ///   lineage — the common case in steady-state GA) processes four gene
    ///   pairs at a time using `SIMD4<Double>` for the time-difference lanes.
    ///   Branching on inclusion stays scalar because the three-way logic
    ///   (both-excluded / mismatched / both-included) doesn't vectorize
    ///   cleanly, but the time-diff lanes dominate the arithmetic cost.
    func distance(to other: ScheduleChromosome) -> Double {
        guard !genes.isEmpty else { return 0 }

        // Fast path: identical gene order (common when both descend from same parent).
        // Avoid building the index dictionary when we can align by position.
        let alignedByIndex = genes.count == other.genes.count
            && zip(genes, other.genes).allSatisfy { $0.eventId == $1.eventId }

        if alignedByIndex {
            return simdAlignedDistance(to: other)
        }

        // Slow path: genes don't align by index (pre-crossover parents, or
        // chromosomes from different lineages). Use dictionary lookup.
        var totalDiff = 0.0
        var count = 0
        let otherById: [String: ScheduleGene] = Dictionary(
            other.genes.map { ($0.eventId, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        for geneA in genes {
            guard let geneB = otherById[geneA.eventId] else {
                totalDiff += 1.0
                count += 1
                continue
            }
            totalDiff += pairDistance(geneA, geneB, &count)
        }
        return count > 0 ? totalDiff / Double(count) : 0
    }

    /// Aligned-index distance computed four lanes at a time.
    ///
    /// For each batch of 4 gene pairs, the time differences are computed in a
    /// single `SIMD4<Double>` subtraction, absolute-valued, and normalized
    /// against the 9h reference — three instructions instead of twelve. The
    /// inclusion logic remains scalar; it's a cheap branch-predictor-friendly
    /// pattern because in most generations the vast majority of genes keep
    /// their inclusion flag.
    @inline(__always)
    private func simdAlignedDistance(to other: ScheduleChromosome) -> Double {
        let n = genes.count
        let normalize = 9.0 * 3600.0
        var totalDiff = 0.0
        var count = 0

        var i = 0
        while i + 4 <= n {
            // Gather four time differences in one SIMD op. We load
            // timeIntervalSinceReferenceDate directly (Double) rather than
            // going through timeIntervalSince() which would be an extra
            // subtract per lane.
            let aTimes = SIMD4<Double>(
                genes[i].startTime.timeIntervalSinceReferenceDate,
                genes[i + 1].startTime.timeIntervalSinceReferenceDate,
                genes[i + 2].startTime.timeIntervalSinceReferenceDate,
                genes[i + 3].startTime.timeIntervalSinceReferenceDate
            )
            let bTimes = SIMD4<Double>(
                other.genes[i].startTime.timeIntervalSinceReferenceDate,
                other.genes[i + 1].startTime.timeIntervalSinceReferenceDate,
                other.genes[i + 2].startTime.timeIntervalSinceReferenceDate,
                other.genes[i + 3].startTime.timeIntervalSinceReferenceDate
            )
            let rawDelta = aTimes - bTimes
            // `abs()` returns abs value per-lane. Divide by normalize to
            // put every lane in [0, ∞); the final min(1, ·) clamps the tail.
            let normalized = abs(rawDelta) / SIMD4(repeating: normalize)
            let clamped = normalized.clamped(
                lowerBound: SIMD4<Double>.zero,
                upperBound: SIMD4(repeating: 1.0)
            )

            for lane in 0..<4 {
                let a = genes[i + lane]
                let b = other.genes[i + lane]
                count += 1
                if a.isIncluded != b.isIncluded {
                    totalDiff += 1.0
                } else if !a.isIncluded {
                    // Both excluded — distance contribution is 0, no-op.
                } else {
                    totalDiff += clamped[lane]
                }
            }
            i += 4
        }

        // Scalar remainder for tail < 4.
        while i < n {
            totalDiff += pairDistance(genes[i], other.genes[i], &count)
            i += 1
        }

        return count > 0 ? totalDiff / Double(count) : 0
    }

    /// Per-gene distance contribution. Mutates `count` to keep the two paths aligned.
    @inline(__always)
    private func pairDistance(_ a: ScheduleGene, _ b: ScheduleGene, _ count: inout Int) -> Double {
        count += 1
        // Inclusion mismatch = full difference
        if a.isIncluded != b.isIncluded { return 1.0 }
        // Both excluded = identical
        if !a.isIncluded { return 0.0 }
        // Time difference normalized by 9h working day
        let timeDiff = abs(a.startTime.timeIntervalSince(b.startTime))
        return min(1.0, timeDiff / (9 * 3600))
    }

}
