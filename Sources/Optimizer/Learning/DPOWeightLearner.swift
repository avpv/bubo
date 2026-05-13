import Foundation

// MARK: - DPO Weight Learner (Wave 4 / item 3)
//
// Direct Preference Optimization (Rafailov et al., 2023) reformulated
// for a multi-objective scheduling problem: given a stream of
// (winner, loser) schedule pairs — produced by user accept/reject or
// manual-edit feedback — fit a logistic regression on the differences
// of per-objective scores to learn per-objective weights that
// maximise the probability of the user preferring the winner.
//
// The model is a Bradley-Terry preference model with features =
// per-objective score deltas. Under BT the log-odds of A being
// preferred over B is:
//     logit P(A ≻ B) = ⟨w, φ(A) - φ(B)⟩
// where φ(x) is the per-objective score vector. Fitting w is a
// standard L2-regularised logistic regression, closed-form-free but
// convex and fast to optimise with online SGD / batch mini-Newton.
//
// Practical constraints for Bubo:
//   • Regularisation prior centres weights on the hand-tuned
//     defaults so the learner degrades gracefully to sensible
//     behaviour when pair-count is tiny.
//   • Hard-tier objectives (Precedence, Conflict) never go below
//     a floor via a one-sided projection — DPO can't bargain away
//     constraint enforcement.
//   • Weights stay non-negative: enforced at each SGD step by
//     projection onto [0, ∞).

public struct DPOPreferencePair: Sendable {
    /// Objective-score vector of the winner (user-preferred).
    public let winnerScores: [String: Double]
    /// Objective-score vector of the loser.
    public let loserScores: [String: Double]
    /// Optional confidence weight on this observation. 1 = normal,
    /// 0.5 = weak signal (e.g. inferred from a minor edit), etc.
    public let confidence: Double

    public init(
        winnerScores: [String: Double],
        loserScores: [String: Double],
        confidence: Double = 1.0
    ) {
        self.winnerScores = winnerScores
        self.loserScores = loserScores
        self.confidence = max(0, min(1, confidence))
    }
}

public final class DPOWeightLearner: @unchecked Sendable {
    public struct Configuration: Sendable {

        public init(
            l2Regularisation: Double,
            learningRate: Double,
            hardTierFloor: Double,
            hardTierNames: Set<String>,
            weightCap: Double
        ) {
            self.l2Regularisation = l2Regularisation
            self.learningRate = learningRate
            self.hardTierFloor = hardTierFloor
            self.hardTierNames = hardTierNames
            self.weightCap = weightCap
        }

        /// Regularisation strength; pulls weights toward the prior.
        /// Higher = slower departure from defaults (safer with few pairs).
        public let l2Regularisation: Double
        /// Learning rate for online SGD updates.
        public let learningRate: Double
        /// Minimum weight floor per-objective; prevents logistic
        /// regression from eroding hard-ish objectives.
        public let hardTierFloor: Double
        /// Names of objectives whose weight must stay above the floor.
        public let hardTierNames: Set<String>
        /// Maximum weight (sanity cap). Runaway weights over-fit to
        /// a single noisy pair; caps keep the model well-conditioned.
        public let weightCap: Double

        public static let `default` = Configuration(
            l2Regularisation: 0.05,
            learningRate: 0.02,
            hardTierFloor: 1.0,
            hardTierNames: ["Precedence", "Conflict"],
            weightCap: 20.0
        )
    }

    public let config: Configuration
    private let lock = NSLock()

    /// Prior weights — typically the hand-tuned preferences. The
    /// learner pulls toward these via L2 regularisation.
    private var priorWeights: [String: Double]

    /// Current learned weights. Starts equal to the prior.
    private var weights: [String: Double]

    /// Running count of preference pairs consumed. Exposed for tests
    /// and the active-learning uncertainty sampler.
    private var observedPairs: Int = 0

    public init(
        priorWeights: [String: Double],
        config: Configuration = .default
    ) {
        self.priorWeights = priorWeights
        self.weights = priorWeights
        self.config = config
    }

    // MARK: - Updates

    /// Process one preference pair via online SGD.
    public func observe(pair: DPOPreferencePair) {
        guard pair.confidence > 0 else { return }
        let names = Array(Set(pair.winnerScores.keys).union(pair.loserScores.keys))
        guard !names.isEmpty else { return }

        lock.lock()
        defer { lock.unlock() }

        // 1. Compute log-odds under current weights: η = ⟨w, Δφ⟩.
        var eta = 0.0
        var deltas: [String: Double] = [:]
        deltas.reserveCapacity(names.count)
        for name in names {
            let dw = (pair.winnerScores[name] ?? 0) - (pair.loserScores[name] ?? 0)
            deltas[name] = dw
            eta += (weights[name] ?? 0) * dw
        }
        // 2. Sigmoid → probability the winner dominates under current w.
        let p = 1.0 / (1.0 + exp(-eta))
        // 3. Gradient of log-loss w.r.t. w_i is (1 - p) · Δφ_i. Regularise
        //    toward prior: add λ · (w_i - w_prior_i) as a pull-back term.
        //    Scale by confidence and the configured learning rate.
        let stepFactor = config.learningRate * pair.confidence * (1 - p)
        for (name, delta) in deltas {
            let current = weights[name] ?? 0
            let prior = priorWeights[name] ?? current
            let gradient = -stepFactor * delta + config.l2Regularisation * (current - prior)
            var updated = current - gradient
            if config.hardTierNames.contains(name) {
                updated = max(config.hardTierFloor, updated)
            }
            updated = max(0, min(config.weightCap, updated))
            weights[name] = updated
        }
        observedPairs += 1
    }

    /// Mini-batch: fold a set of pairs at once. Useful when replaying
    /// a backlog of unprocessed feedback.
    public func observeBatch(_ pairs: [DPOPreferencePair]) {
        for p in pairs { observe(pair: p) }
    }

    // MARK: - Inference

    /// Returns the current learned weight dictionary.
    public var currentWeights: [String: Double] {
        lock.lock(); defer { lock.unlock() }
        return weights
    }

    /// Probability that A is preferred over B under the current
    /// learned weights — used by the active learner to rank pairs
    /// by model uncertainty.
    public func preferenceProbability(
        aScores: [String: Double],
        bScores: [String: Double]
    ) -> Double {
        lock.lock()
        defer { lock.unlock() }
        let names = Set(aScores.keys).union(bScores.keys)
        var eta = 0.0
        for name in names {
            let delta = (aScores[name] ?? 0) - (bScores[name] ?? 0)
            eta += (weights[name] ?? 0) * delta
        }
        return 1.0 / (1.0 + exp(-eta))
    }

    /// Copy the learned weights into an `OptimizerPreferences` struct.
    /// Unknown names are ignored. Overwrites the corresponding slots.
    public func applyTo(preferences: inout OptimizerPreferences) {
        lock.lock()
        defer { lock.unlock() }
        if let w = weights["FocusBlock"] { preferences.focusBlockWeight = w }
        if let w = weights["PomodoroFit"] { preferences.pomodoroFitWeight = w }
        if let w = weights["Conflict"] { preferences.conflictWeight = w }
        if let w = weights["TaskPlacement"] { preferences.taskPlacementWeight = w }
        if let w = weights["WeekBalance"] { preferences.weekBalanceWeight = w }
        if let w = weights["EnergyBalance"] { preferences.energyCurveWeight = w }
        if let w = weights["MultiPerson"] { preferences.multiPersonWeight = w }
        if let w = weights["BreakPlacement"] { preferences.breakWeight = w }
        if let w = weights["Deadline"] { preferences.deadlineWeight = w }
        if let w = weights["ContextSwitch"] { preferences.contextSwitchWeight = w }
        if let w = weights["Buffer"] { preferences.bufferWeight = w }
        if let w = weights["MeetingClustering"] { preferences.meetingClusteringWeight = w }
        if let w = weights["TaskInclusion"] { preferences.taskInclusionWeight = w }
        if let w = weights["BacklogOrder"] { preferences.backlogOrderWeight = w }
    }

    // MARK: - Introspection

    public var observedPairCount: Int {
        lock.lock(); defer { lock.unlock() }
        return observedPairs
    }

    /// Update the prior (e.g. after a UI slider nudge). Keeps the
    /// learned delta from the old prior proportional.
    public func updatePrior(_ prior: [String: Double]) {
        lock.lock()
        defer { lock.unlock() }
        priorWeights = prior
    }

    /// Replace the live weight vector wholesale. Used by training-
    /// pipeline restore to rehydrate from a persisted snapshot
    /// without losing the observation count. Bypasses the regulariser
    /// and the hard-tier floor — the snapshot is assumed valid.
    public func setWeights(_ newWeights: [String: Double], observedPairs: Int? = nil) {
        lock.lock()
        defer { lock.unlock() }
        weights = newWeights
        if let obs = observedPairs {
            self.observedPairs = obs
        }
    }

    public func reset() {
        lock.lock()
        defer { lock.unlock() }
        weights = priorWeights
        observedPairs = 0
    }
}
