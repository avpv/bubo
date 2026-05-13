import Foundation

// MARK: - Lexicographic Fitness (Wave 1 / item 7)
//
// Hierarchical objective evaluation. Splits the 14 objectives into two
// tiers: a "near-hard" tier (Precedence, Conflict) whose violations
// dominate everything else, and a "soft" tier for the remaining 12
// quality-of-life objectives. Comparisons prefer any individual with a
// strictly better near-hard score (ε-tolerance) and only fall through
// to the soft tier when the top tier ties.
//
// This fixes a specific GA pathology: without a hierarchy, the weighted
// sum can trade one Precedence violation for a big gain in FocusBlock or
// MeetingClustering, producing pretty-looking schedules that violate
// user-stated dependencies. Promoting Precedence/Conflict to a dedicated
// tier makes that trade literally impossible without solving the
// violation first.
//
// The feature is orthogonal to the weighted-sum fitness path — callers
// opt in by using `LexicographicComparator` for selection / elitism /
// incumbent tracking. When the GA's base fitness path is used for back-
// compat, lex-fitness silently does nothing.

/// Three tier scores, higher is better in each. Comparisons walk the
/// tiers top-down: `hardTier` dominates, then `midTier`, then
/// `softTier`. Ties within ε on a tier fall through to the next.
public struct LexFitness: Hashable, Sendable {
    /// Near-hard tier: aggregate of Precedence and Conflict scores.
    /// These are almost-hard constraints — any soft-tier win traded
    /// for a hard violation is a bug. [0, 1], 1 = no violations.
    public let hardTier: Double

    /// User-declared preference tier: aggregate of Deadline and
    /// BacklogOrder. Sacrificing these for Buffer / ContextSwitch /
    /// EnergyCurve is the exact failure mode the previous
    /// two-tier setup produced for backlog-inclusion scenarios —
    /// the GA spread task 1 across next week to save a few percent
    /// on ContextSwitch. Making them a separate tier makes that
    /// trade impossible without first matching the user's order.
    public let midTier: Double

    /// Soft tier: weighted aggregate of the remaining quality
    /// objectives (Buffer, ContextSwitch, Break, FocusBlock, …).
    /// [0, 1], 1 = perfect quality.
    public let softTier: Double

    public init(hardTier: Double, midTier: Double, softTier: Double) {
        self.hardTier = hardTier
        self.midTier = midTier
        self.softTier = softTier
    }
}

/// Comparator that orders two `LexFitness` values lexicographically
/// across three tiers (hard → mid → soft). Tie-tolerance on each tier
/// is `epsilon`; within it, the two are treated as equal on that
/// coordinate and the next tier decides. Default ε = 1e-4 prevents the
/// GA from churning on floating-point noise while still keeping a
/// meaningful dominance signal on each tier.
public struct LexicographicComparator: Sendable {
    public let epsilon: Double

    public init(epsilon: Double = 1e-4) { self.epsilon = epsilon }

    /// Returns true when `lhs` dominates `rhs` under the lex order.
    public func isBetter(_ lhs: LexFitness, than rhs: LexFitness) -> Bool {
        let hardDelta = lhs.hardTier - rhs.hardTier
        if hardDelta > epsilon { return true }
        if hardDelta < -epsilon { return false }
        let midDelta = lhs.midTier - rhs.midTier
        if midDelta > epsilon { return true }
        if midDelta < -epsilon { return false }
        return lhs.softTier > rhs.softTier
    }

    /// Sort comparator callable — lower index = better individual.
    public func sort(_ lhs: LexFitness, _ rhs: LexFitness) -> Bool {
        isBetter(lhs, than: rhs)
    }
}

// MARK: - Classification

/// Which objectives live in which tier. Names come from the objective
/// protocol's `name` field as wired into `FitnessEvaluator.standard`.
/// Keep these sets in sync when objectives are added or renamed.
public enum LexTier: Sendable {
    /// Precedence + Conflict. Sacrificing these for any softer gain
    /// is a bug. The constraint engine catches most violations, but
    /// these objectives provide gradient even when the constraint
    /// is satisfied (soft buffers around fixed events, etc.).
    public static let hardTierObjectiveNames: Set<String> = [
        "Precedence",
        "Conflict",
    ]

    /// User-declared preferences that must dominate the quality axes.
    /// Deadline violations and backlog-order inversions are visible
    /// to the user in a way that "2 fewer context switches" is not;
    /// the GA should never trade them for those softer gains.
    public static let midTierObjectiveNames: Set<String> = [
        "Deadline",
        "BacklogOrder",
    ]

    /// Classify an objective by name into its tier.
    public static func tier(of name: String) -> Tier {
        if hardTierObjectiveNames.contains(name) { return .hard }
        if midTierObjectiveNames.contains(name) { return .mid }
        return .soft
    }

    public enum Tier: Sendable { case hard, mid, soft }
}

// MARK: - Extraction from objective cache

/// Reads a `LexFitness` out of a chromosome's cached objective scores,
/// weighting by the evaluator's objective weights. Returns nil when
/// the cache isn't populated — callers are expected to call
/// `evaluator.evaluateAndAssign(…)` first.
///
/// Design choice: we read from the cache (populated during normal
/// evaluation) rather than re-scoring. That means lex-fitness is free
/// — one dictionary walk per chromosome, no extra objective calls.
public struct LexicographicExtractor: Sendable {
    public let objectiveWeights: [String: Double]

    /// Build from a live evaluator. The closure captures the current
    /// per-objective weights; pass a fresh extractor after weights
    /// change (e.g. after DPO learning fires).
    public init(evaluator: FitnessEvaluator) {
        var w: [String: Double] = [:]
        w.reserveCapacity(evaluator.objectives.count)
        for obj in evaluator.objectives {
            w[obj.name] = obj.weight
        }
        self.objectiveWeights = w
    }

    /// Test-only initialiser from a raw weight map.
    public init(weights: [String: Double]) { self.objectiveWeights = weights }

    /// Extract. When the chromosome has no objective cache (e.g.
    /// surrogate-predicted but with empty objective vector), returns
    /// `nil` so callers can fall back to the scalar `rawFitness`.
    public func extract(from chromosome: ScheduleChromosome) -> LexFitness? {
        guard let cache = chromosome.objectiveCache, !cache.isEmpty else {
            return nil
        }
        return extract(fromCache: cache)
    }

    /// Direct-from-cache variant. Useful for callers that have a
    /// pre-computed per-objective dictionary (e.g. scenario metadata).
    public func extract(fromCache cache: [String: Double]) -> LexFitness {
        var hardNum = 0.0, hardDen = 0.0
        var midNum = 0.0, midDen = 0.0
        var softNum = 0.0, softDen = 0.0
        for (name, score) in cache {
            let clamped = max(0.0, min(1.0, score))
            let w = max(0.0, objectiveWeights[name] ?? 1.0)
            guard w > 0 else { continue }
            switch LexTier.tier(of: name) {
            case .hard:
                hardNum += clamped * w
                hardDen += w
            case .mid:
                midNum += clamped * w
                midDen += w
            case .soft:
                softNum += clamped * w
                softDen += w
            }
        }
        // Denominator of 0 = that tier has no contributing objectives.
        // Return 1.0 (perfect) for empty tiers so the comparator
        // gracefully degrades through tiers when some are unwired.
        let hard = hardDen > 0 ? hardNum / hardDen : 1.0
        let mid = midDen > 0 ? midNum / midDen : 1.0
        let soft = softDen > 0 ? softNum / softDen : 1.0
        return LexFitness(hardTier: hard, midTier: mid, softTier: soft)
    }
}

// MARK: - Selection helpers

public extension Array where Element == ScheduleChromosome {
    /// Select the best individual by lex order. Useful as a drop-in
    /// replacement for `max(by: { $0.rawFitness < $1.rawFitness })`
    /// when hard-tier priority matters.
    public func bestByLex(
        using extractor: LexicographicExtractor,
        comparator: LexicographicComparator = LexicographicComparator()
    ) -> ScheduleChromosome? {
        guard !isEmpty else { return nil }
        var bestIdx = 0
        var bestLex = extractor.extract(from: self[0])
            ?? LexFitness(hardTier: self[0].rawFitness, midTier: self[0].rawFitness, softTier: self[0].rawFitness)
        for i in 1..<count {
            let lex = extractor.extract(from: self[i])
                ?? LexFitness(hardTier: self[i].rawFitness, midTier: self[i].rawFitness, softTier: self[i].rawFitness)
            if comparator.isBetter(lex, than: bestLex) {
                bestLex = lex
                bestIdx = i
            }
        }
        return self[bestIdx]
    }

    /// Sort in-place by lex order (best first).
    public mutating func sortByLex(
        using extractor: LexicographicExtractor,
        comparator: LexicographicComparator = LexicographicComparator()
    ) {
        // Decorate-sort-undecorate to avoid recomputing lex per comparison.
        let decorated: [(LexFitness, ScheduleChromosome)] = map { chromo in
            let lex = extractor.extract(from: chromo)
                ?? LexFitness(hardTier: chromo.rawFitness, midTier: chromo.rawFitness, softTier: chromo.rawFitness)
            return (lex, chromo)
        }
        let sorted = decorated.sorted { comparator.isBetter($0.0, than: $1.0) }
        self = sorted.map(\.1)
    }
}
