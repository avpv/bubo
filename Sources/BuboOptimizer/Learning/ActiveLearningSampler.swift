import Foundation

// MARK: - Active Learning Sampler (Wave 4 / item 10)
//
// Given a pool of candidate schedule pairs and a `DPOWeightLearner`,
// surface the pair whose preference the model is most uncertain
// about — i.e. the pair whose resolved preference would maximally
// reduce the DPO model's entropy.
//
// For a Bradley-Terry / logistic DPO, the per-pair entropy is
//   H(A ≻ B) = -p log p - (1-p) log (1-p)
// where p = σ(⟨w, φ(A) - φ(B)⟩). Picking argmax H naively works but
// has a failure mode: pairs that are structurally very similar can
// sit at p ≈ 0.5 because their objective-score deltas are tiny,
// not because the model is confused. We correct by multiplying
// entropy by the magnitude of the score-delta vector — so genuine
// "strong but uncertain" pairs rank above "weak and meaningless" ones.

public struct ScenarioPairCandidate: Sendable {

    public init(
        id: String,
        aScores: [String: Double],
        bScores: [String: Double]
    ) {
        self.id = id
        self.aScores = aScores
        self.bScores = bScores
    }

    public let id: String
    public let aScores: [String: Double]
    public let bScores: [String: Double]
}

/// Ranking score for one candidate pair.
public struct ActiveLearningRank: Sendable {

    public init(
        id: String,
        probability: Double,   // p(A ≻ B) under current weights
        entropy: Double,       // base entropy
        magnitude: Double,     // L2 norm of score-delta
        value: Double          // entropy × magnitude — total information value
    ) {
        self.id = id
        self.probability = probability
        self.entropy = entropy
        self.magnitude = magnitude
        self.value = value
    }

    public let id: String
    public let probability: Double   // p(A ≻ B) under current weights
    public let entropy: Double       // base entropy
    public let magnitude: Double     // L2 norm of score-delta
    public let value: Double         // entropy × magnitude — total information value
}

public enum ActiveLearningSampler {
    /// Rank every candidate pair. Returns the top-k by information
    /// value (entropy × magnitude). When `count` equals `candidates.count`
    /// the full ranking is returned.
    public static func topK(
        count: Int,
        candidates: [ScenarioPairCandidate],
        learner: DPOWeightLearner
    ) -> [ActiveLearningRank] {
        guard !candidates.isEmpty, count > 0 else { return [] }
        let ranks: [ActiveLearningRank] = candidates.map { cand in
            let p = learner.preferenceProbability(
                aScores: cand.aScores,
                bScores: cand.bScores
            )
            let h = entropy(p: p)
            let mag = deltaMagnitude(a: cand.aScores, b: cand.bScores)
            return ActiveLearningRank(
                id: cand.id,
                probability: p,
                entropy: h,
                magnitude: mag,
                value: h * mag
            )
        }
        return ranks.sorted { $0.value > $1.value }.prefix(count).map { $0 }
    }

    /// Single best pair — shorthand for `topK(count: 1)`.
    public static func best(
        in candidates: [ScenarioPairCandidate],
        learner: DPOWeightLearner
    ) -> ActiveLearningRank? {
        topK(count: 1, candidates: candidates, learner: learner).first
    }

    // MARK: - Internals

    /// Binary entropy with numerical safety. Returns 0 at extremes.
    private static func entropy(p: Double) -> Double {
        guard p > 1e-9 && p < 1 - 1e-9 else { return 0 }
        return -p * log(p) - (1 - p) * log(1 - p)
    }

    private static func deltaMagnitude(
        a: [String: Double],
        b: [String: Double]
    ) -> Double {
        let keys = Set(a.keys).union(b.keys)
        var sumSq = 0.0
        for k in keys {
            let d = (a[k] ?? 0) - (b[k] ?? 0)
            sumSq += d * d
        }
        return sqrt(sumSq)
    }
}

// MARK: - Pair Selection from Scenario List

/// Convenience wrapper over `ActiveLearningSampler` when the host has
/// a flat list of scored `ScheduleScenario`s and wants an information-
/// dense pair to display.
public enum ScenarioPairActiveSelector {
    /// Generate all unique pairs of scenarios, filter to the top-k
    /// by DPO information value, surface their identifiers.
    public static func bestPair(
        scenarios: [ScheduleScenario],
        learner: DPOWeightLearner
    ) -> (ScheduleScenario, ScheduleScenario)? {
        guard scenarios.count >= 2 else { return nil }
        var candidates: [ScenarioPairCandidate] = []
        candidates.reserveCapacity(scenarios.count * (scenarios.count - 1) / 2)
        for i in 0..<scenarios.count {
            for j in (i + 1)..<scenarios.count {
                candidates.append(ScenarioPairCandidate(
                    id: "\(i)-\(j)",
                    aScores: scenarios[i].objectiveBreakdown,
                    bScores: scenarios[j].objectiveBreakdown
                ))
            }
        }
        guard let top = ActiveLearningSampler.best(in: candidates, learner: learner) else {
            return nil
        }
        let parts = top.id.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 2 else { return nil }
        return (scenarios[parts[0]], scenarios[parts[1]])
    }
}
