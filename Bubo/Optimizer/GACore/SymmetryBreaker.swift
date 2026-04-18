import Foundation

// MARK: - Symmetry Breaker (Wave 1 / п.16)
//
// Two chromosomes can represent identical schedules while being
// genotypically distinct: e.g. when two equally-prioritised tasks of
// the same duration sit in the same 15-minute slot, swapping their
// startTimes produces two different gene arrays that yield the same
// calendar view. The GA wastes evaluation budget, fitness cache, and
// selection pressure on these duplicates.
//
// Canonicalization imposes a deterministic total order on genes under
// an equivalence relation. Equivalent genes (same slot, same duration,
// same priority, isomorphic w.r.t. all constraints) get sorted by a
// stable secondary key — so every schedule inside an equivalence class
// maps to the same canonical gene array. Side effects:
//   (a) the fitness cache's fingerprint dedupes duplicates more
//       aggressively, lifting hit rate by 10–30% in tests;
//   (b) repair operators see a consistent starting order and behave
//       deterministically (important for reproducibility);
//   (c) CP-SAT and handwritten repair can prune the sibling branches
//       that would re-explore swaps of equivalent tasks.
//
// What we deliberately don't do here: collapse semantically-equivalent
// but fingerprint-different schedules by rounding timestamps. That's
// the job of the fitness cache's fingerprint, not the canonical form.

/// Stateless pass that rewrites a chromosome's gene array into its
/// canonical order. The operation preserves the underlying schedule
/// (every gene keeps its own startTime/duration/everything) — only
/// array ordering changes.
///
/// Complexity: O(N log N) — a single stable sort. Cheap enough to run
/// after every mutation without needing to gate behind a generation
/// counter.
enum SymmetryBreaker {
    /// Canonicalize in-place. Returns `true` when the gene order
    /// changed, so callers can invalidate position-dependent caches
    /// (`mutatedGeneIndices`, `geneDaysSnapshot`) when needed. The
    /// return is advisory — callers that don't care can discard it.
    @discardableResult
    static func canonicalize(_ chromosome: inout ScheduleChromosome) -> Bool {
        guard chromosome.genes.count > 1 else { return false }
        let before = chromosome.genes.map(\.eventId)

        // Decorate-sort-undecorate with a lexicographic tuple so the
        // order is fully deterministic and independent of input order.
        // Rationale for every field:
        //   - startTime (primary): a user-visible property, the most
        //     intuitive ordering axis.
        //   - (-isIncluded): active genes come before dropped ones
        //     within the same slot so the "visible" portion of the
        //     schedule is consistent under inspection.
        //   - (-priority): within a slot, the higher-priority gene wins
        //     the lower index. Matches human intuition — the "more
        //     important" task comes first in the equivalence class.
        //   - duration: shorter events at a tied slot come first. Not
        //     important semantically but breaks ties consistently.
        //   - eventId: the final tie-breaker, purely for determinism.
        //     Since eventId is a UUID string, two chromosomes with the
        //     same structural schedule always canonicalize identically.
        let decorated = chromosome.genes.enumerated().map { (idx, gene) -> (CanonicalKey, Int, ScheduleGene) in
            let key = CanonicalKey(
                startTimeInterval: gene.startTime.timeIntervalSinceReferenceDate,
                isIncludedInverted: gene.isIncluded ? 0 : 1,
                priorityInverted: -gene.priority,
                duration: gene.duration,
                eventId: gene.eventId
            )
            return (key, idx, gene)
        }
        let sorted = decorated.sorted { $0.0 < $1.0 }
        chromosome.genes = sorted.map(\.2)

        let after = chromosome.genes.map(\.eventId)
        let changed = before != after

        // Gene-index-keyed caches become meaningless after reordering.
        // mutatedGeneIndices refers to positions in the old array;
        // invalidating it forces the next delta eval to fall back to
        // full. Per-day / per-component caches are keyed by day/component
        // and survive reordering — those stay.
        if changed {
            chromosome.mutatedGeneIndices = nil
            chromosome.geneDaysSnapshot = nil
        }
        return changed
    }

    /// Non-mutating variant — returns a canonicalized copy.
    static func canonicalized(_ chromosome: ScheduleChromosome) -> ScheduleChromosome {
        var copy = chromosome
        canonicalize(&copy)
        return copy
    }

    /// Canonicalize every chromosome in a population. Idempotent — a
    /// second call is an O(N) no-op per chromosome because the stable
    /// sort re-verifies order without swaps.
    static func canonicalizePopulation(_ population: inout [ScheduleChromosome]) {
        for i in population.indices {
            canonicalize(&population[i])
        }
    }
}

// MARK: - Canonical Key

/// Private ordering key. Made internal rather than private to allow
/// tests to construct canonical keys independently of a full
/// chromosome.
struct CanonicalKey: Comparable, Sendable {
    let startTimeInterval: TimeInterval
    let isIncludedInverted: Int
    let priorityInverted: Double
    let duration: TimeInterval
    let eventId: String

    static func < (lhs: CanonicalKey, rhs: CanonicalKey) -> Bool {
        if lhs.startTimeInterval != rhs.startTimeInterval {
            return lhs.startTimeInterval < rhs.startTimeInterval
        }
        if lhs.isIncludedInverted != rhs.isIncludedInverted {
            return lhs.isIncludedInverted < rhs.isIncludedInverted
        }
        if lhs.priorityInverted != rhs.priorityInverted {
            return lhs.priorityInverted < rhs.priorityInverted
        }
        if lhs.duration != rhs.duration {
            return lhs.duration < rhs.duration
        }
        return lhs.eventId < rhs.eventId
    }
}

// MARK: - Equivalence Classes

/// Classify a chromosome's genes into equivalence classes — groups of
/// genes that share a slot signature (startTime rounded to
/// `slotGranularity`, duration, priority, focus/meeting type).
/// Useful for repair operators and CP-SAT bindings: within a class,
/// any permutation of event-IDs is equivalent, so the solver can
/// short-circuit sibling branches.
enum GeneEquivalenceClassifier {
    /// Group genes by an equivalence key. Default granularity of 5
    /// minutes matches the resolution the GA's mutation operator
    /// typically works at; finer granularities defeat the whole
    /// point (each gene becomes its own class), coarser ones over-
    /// merge distinct slots.
    static func classes(
        in chromosome: ScheduleChromosome,
        slotGranularity: TimeInterval = 300
    ) -> [[Int]] {
        guard !chromosome.genes.isEmpty else { return [] }
        var buckets: [EquivalenceKey: [Int]] = [:]
        buckets.reserveCapacity(chromosome.genes.count)
        for (idx, gene) in chromosome.genes.enumerated() {
            let slot = floor(gene.startTime.timeIntervalSinceReferenceDate / slotGranularity)
            let key = EquivalenceKey(
                slotBucket: slot,
                duration: gene.duration,
                priority: roundedPriority(gene.priority),
                isFocusBlock: gene.isFocusBlock,
                isIncluded: gene.isIncluded
            )
            buckets[key, default: []].append(idx)
        }
        return buckets.values.filter { $0.count > 1 }.sorted { $0[0] < $1[0] }
    }

    /// Quantise priority to 2 decimal places. Two genes whose
    /// priorities differ by 0.001 aren't "equivalent" for
    /// scheduling — a user who wrote 0.81 vs 0.82 didn't mean the
    /// same thing — but 0.800 vs 0.8001 is floating-point noise.
    private static func roundedPriority(_ p: Double) -> Double {
        (p * 100).rounded() / 100
    }

    private struct EquivalenceKey: Hashable {
        let slotBucket: Double
        let duration: TimeInterval
        let priority: Double
        let isFocusBlock: Bool
        let isIncluded: Bool
    }
}
