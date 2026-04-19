import Foundation

// MARK: - Lexicographic Fitness (Wave 1 / п.7)
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

/// A pair of tier scores, higher is better in both tiers.
struct LexFitness: Hashable, Sendable {
    /// Near-hard tier: aggregate of Precedence and Conflict scores.
    /// [0, 1], 1 = no violations.
    let hardTier: Double

    /// Soft tier: weighted aggregate of the 12 quality objectives.
    /// [0, 1], 1 = perfect quality.
    let softTier: Double

    init(hardTier: Double, softTier: Double) {
        self.hardTier = hardTier
        self.softTier = softTier
    }
}

/// Comparator that orders two `LexFitness` values lexicographically.
/// Tie-tolerance on the hard tier is configurable: within `epsilon`
/// the two are treated as equal on the first coordinate and decide
/// by the soft tier. The default ε is 1e-4, which prevents the GA from
/// churning on floating-point noise while still keeping a meaningful
/// hard-tier dominance signal.
struct LexicographicComparator: Sendable {
    let epsilon: Double

    init(epsilon: Double = 1e-4) { self.epsilon = epsilon }

    /// Returns true when `lhs` dominates `rhs` under the lex order.
    func isBetter(_ lhs: LexFitness, than rhs: LexFitness) -> Bool {
        let delta = lhs.hardTier - rhs.hardTier
        if delta > epsilon { return true }
        if delta < -epsilon { return false }
        return lhs.softTier > rhs.softTier
    }

    /// Sort comparator callable — lower index = better individual.
    func sort(_ lhs: LexFitness, _ rhs: LexFitness) -> Bool {
        isBetter(lhs, than: rhs)
    }
}

// MARK: - Classification

/// Which objectives live in the near-hard tier. Names come from the
/// objective protocol's `name` field as wired into
/// `FitnessEvaluator.standard`. Keep this in sync — adding a new
/// objective that is structurally hard (e.g. NoConflict, ResourceLimit)
/// belongs here too.
enum LexTier: Sendable {
    /// Precedence + Conflict. Sacrificing these for any soft gain is a bug.
    static let hardTierObjectiveNames: Set<String> = [
        "Precedence",
        "Conflict",
    ]

    /// Classify an objective by name into hard or soft tier.
    static func tier(of name: String) -> Tier {
        hardTierObjectiveNames.contains(name) ? .hard : .soft
    }

    enum Tier: Sendable { case hard, soft }
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
struct LexicographicExtractor: Sendable {
    let objectiveWeights: [String: Double]

    /// Build from a live evaluator. The closure captures the current
    /// per-objective weights; pass a fresh extractor after weights
    /// change (e.g. after DPO learning fires).
    init(evaluator: FitnessEvaluator) {
        var w: [String: Double] = [:]
        w.reserveCapacity(evaluator.objectives.count)
        for obj in evaluator.objectives {
            w[obj.name] = obj.weight
        }
        self.objectiveWeights = w
    }

    /// Test-only initialiser from a raw weight map.
    init(weights: [String: Double]) { self.objectiveWeights = weights }

    /// Extract. When the chromosome has no objective cache (e.g.
    /// surrogate-predicted but with empty objective vector), returns
    /// `nil` so callers can fall back to the scalar `rawFitness`.
    func extract(from chromosome: ScheduleChromosome) -> LexFitness? {
        guard let cache = chromosome.objectiveCache, !cache.isEmpty else {
            return nil
        }
        return extract(fromCache: cache)
    }

    /// Direct-from-cache variant. Useful for callers that have a
    /// pre-computed per-objective dictionary (e.g. scenario metadata).
    func extract(fromCache cache: [String: Double]) -> LexFitness {
        var hardNum = 0.0, hardDen = 0.0
        var softNum = 0.0, softDen = 0.0
        for (name, score) in cache {
            let clamped = max(0.0, min(1.0, score))
            let w = max(0.0, objectiveWeights[name] ?? 1.0)
            guard w > 0 else { continue }
            switch LexTier.tier(of: name) {
            case .hard:
                hardNum += clamped * w
                hardDen += w
            case .soft:
                softNum += clamped * w
                softDen += w
            }
        }
        // Denominator of 0 = that tier has no contributing objectives.
        // Return 1.0 (perfect) for empty tiers so the comparator
        // gracefully degrades to pure soft comparison when no hard
        // objective is wired.
        let hard = hardDen > 0 ? hardNum / hardDen : 1.0
        let soft = softDen > 0 ? softNum / softDen : 1.0
        return LexFitness(hardTier: hard, softTier: soft)
    }
}

// MARK: - Selection helpers

extension Array where Element == ScheduleChromosome {
    /// Select the best individual by lex order. Useful as a drop-in
    /// replacement for `max(by: { $0.rawFitness < $1.rawFitness })`
    /// when hard-tier priority matters.
    func bestByLex(
        using extractor: LexicographicExtractor,
        comparator: LexicographicComparator = LexicographicComparator()
    ) -> ScheduleChromosome? {
        guard !isEmpty else { return nil }
        var bestIdx = 0
        var bestLex = extractor.extract(from: self[0])
            ?? LexFitness(hardTier: self[0].rawFitness, softTier: self[0].rawFitness)
        for i in 1..<count {
            let lex = extractor.extract(from: self[i])
                ?? LexFitness(hardTier: self[i].rawFitness, softTier: self[i].rawFitness)
            if comparator.isBetter(lex, than: bestLex) {
                bestLex = lex
                bestIdx = i
            }
        }
        return self[bestIdx]
    }

    /// Sort in-place by lex order (best first).
    mutating func sortByLex(
        using extractor: LexicographicExtractor,
        comparator: LexicographicComparator = LexicographicComparator()
    ) {
        // Decorate-sort-undecorate to avoid recomputing lex per comparison.
        let decorated: [(LexFitness, ScheduleChromosome)] = map { chromo in
            let lex = extractor.extract(from: chromo)
                ?? LexFitness(hardTier: chromo.rawFitness, softTier: chromo.rawFitness)
            return (lex, chromo)
        }
        let sorted = decorated.sorted { comparator.isBetter($0.0, than: $1.0) }
        self = sorted.map(\.1)
    }
}
