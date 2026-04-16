import Foundation

// MARK: - REINFORCE Policy over Mutation Operators

/// Softmax policy gradient (REINFORCE) learner over `MutationOperator`
/// conditioned on the same `LandscapeFeatures` the contextual bandit
/// consumes. Where `ContextualBandit` estimates per-arm *values* via
/// ridge regression, this module estimates a *policy* — a probability
/// distribution over arms — and improves it by gradient ascent on the
/// expected reward.
///
/// Update rule (per-trajectory, here each `record` call is one step):
///     ∇θ_a log π(a|x) = x · (1{a=chosen} − π(a|x))
///     θ_a ← θ_a + lr · (reward − baseline) · x · (1{a=chosen} − π(a|x))
///
/// The baseline is a running mean of recent rewards per-feature-bucket,
/// which reduces gradient variance by centring the advantage around
/// zero. REINFORCE is noisier than LinUCB on stationary problems but
/// *converges to the policy's best-response* even when the reward
/// structure is non-linear in features (contextual bandit can't); on
/// shifting workloads (where the optimal operator changes mid-run)
/// this matters a lot.
///
/// Why it's here alongside `ContextualBandit`: both are valid
/// operator-selection routes. We ship both and let config pick which
/// one this run listens to. Defaults to `ContextualBandit` for the
/// exploration/exploitation guarantees; swap to `NeuralOperatorPolicy`
/// when the landscape is known to be non-linear (long horizons,
/// many-objective runs with user preference anchors, etc.).
///
/// Thread safety: single NSLock around θ and the baseline EMA. Cheap
/// (microseconds per call) next to the fitness evaluation it closes a
/// loop on.
final class NeuralOperatorPolicy: @unchecked Sendable {
    /// Per-operator linear-softmax weights. θ_a has shape [dimension].
    private var theta: [MutationOperator: [Double]] = [:]

    /// Running baseline for reward centring. EMA so recent rewards
    /// weigh more than stale ones; α = 0.1 is a standard quiet-tracker
    /// value.
    private var baseline: Double = 0
    private let baselineAlpha: Double = 0.1
    private var updateCount: Int = 0

    /// Learning rate for SGD. Small — the gradient is noisy, and we'd
    /// rather nudge slowly than overshoot on one bad outcome.
    let learningRate: Double

    /// Temperature for the softmax. τ > 1 blurs the distribution
    /// toward uniform (more exploration), τ < 1 sharpens it toward
    /// deterministic (more exploitation). Anneals via `advance()` so
    /// early calls explore and late calls exploit.
    private var temperature: Double
    private let minTemperature: Double = 0.5
    private let temperatureDecay: Double = 0.995

    let dimension: Int
    private let lock = NSLock()

    init(
        dimension: Int = LandscapeFeatures.dimension,
        learningRate: Double = 0.05,
        initialTemperature: Double = 1.5
    ) {
        self.dimension = dimension
        self.learningRate = learningRate
        self.temperature = initialTemperature
        for op in MutationOperator.allCases {
            theta[op] = Array(repeating: 0.0, count: dimension)
        }
    }

    // MARK: - Selection

    /// Sample an operator from the current softmax policy. Uses the
    /// caller's RNG so runs with a fixed seed produce the same
    /// trajectories.
    func select(features: LandscapeFeatures, rng: GARandom) -> MutationOperator {
        let probs = policy(for: features)
        // Inverse-CDF sample. Guarantees reproducibility under RNG.
        let r = rng.unit()
        var acc = 0.0
        for (op, p) in probs {
            acc += p
            if r < acc { return op }
        }
        return probs.last?.key ?? .shift
    }

    /// Full softmax distribution for the given features. Exposed for
    /// tests and UI telemetry — users can see what the policy believes
    /// at any moment without perturbing the random stream.
    func policy(for features: LandscapeFeatures) -> [(key: MutationOperator, value: Double)] {
        let x = features.vector
        lock.lock()
        let temperature = self.temperature
        var logits: [MutationOperator: Double] = [:]
        for op in MutationOperator.allCases {
            guard let w = theta[op] else { continue }
            var z = 0.0
            for i in 0..<dimension { z += w[i] * x[i] }
            logits[op] = z / temperature
        }
        lock.unlock()

        // Numerically stable softmax: subtract max logit before exp.
        let maxL = logits.values.max() ?? 0
        var exps: [MutationOperator: Double] = [:]
        var sum = 0.0
        for (op, l) in logits {
            let e = exp(l - maxL)
            exps[op] = e
            sum += e
        }
        guard sum > 0 else {
            // Fallback: uniform distribution when the softmax underflows.
            let uniform = 1.0 / Double(MutationOperator.allCases.count)
            return MutationOperator.allCases.map { ($0, uniform) }
        }
        return MutationOperator.allCases.map { op in
            (op, (exps[op] ?? 0) / sum)
        }
    }

    // MARK: - Record + Update

    /// One REINFORCE step per observed (features, action, reward).
    /// `reward` is the same raw fitness delta (`child.rawFitness −
    /// baseline parent`) every other bandit path uses, so the policy
    /// learns on comparable units to `MutationBandit` / `ContextualBandit`.
    func record(op: MutationOperator, features: LandscapeFeatures, reward: Double) {
        // Squash reward to [0, 1] through the same logistic every other
        // bandit uses. Prevents outlier deltas from dominating θ.
        let squashed = 1.0 / (1.0 + exp(-reward * 10.0))
        let x = features.vector

        lock.lock()
        defer { lock.unlock() }

        // Update running baseline (advantage centring).
        if updateCount == 0 {
            baseline = squashed
        } else {
            baseline = (1 - baselineAlpha) * baseline + baselineAlpha * squashed
        }
        let advantage = squashed - baseline
        updateCount += 1

        // Compute current π(·|x) so the gradient knows how "surprising"
        // the chosen op was under the present policy.
        var logits: [MutationOperator: Double] = [:]
        for a in MutationOperator.allCases {
            guard let w = theta[a] else { continue }
            var z = 0.0
            for i in 0..<dimension { z += w[i] * x[i] }
            logits[a] = z / max(1e-3, temperature)
        }
        let maxL = logits.values.max() ?? 0
        var exps: [MutationOperator: Double] = [:]
        var sum = 0.0
        for (a, l) in logits {
            let e = exp(l - maxL)
            exps[a] = e
            sum += e
        }
        guard sum > 0 else { return }
        var probs: [MutationOperator: Double] = [:]
        for (a, e) in exps { probs[a] = e / sum }

        // Gradient ascent. For the chosen op, the gradient pushes
        // toward x; for every other op, away from x — scaled by
        // advantage.
        for a in MutationOperator.allCases {
            guard var w = theta[a], let pi = probs[a] else { continue }
            let indicator = (a == op) ? 1.0 : 0.0
            let coef = learningRate * advantage * (indicator - pi) / max(1e-3, temperature)
            for i in 0..<dimension {
                w[i] += coef * x[i]
            }
            theta[a] = w
        }

        // Anneal temperature — bounded below by minTemperature so the
        // policy never fully collapses to deterministic (an occasional
        // off-policy sample is cheap insurance against drift).
        temperature = max(minTemperature, temperature * temperatureDecay)
    }

    // MARK: - Introspection

    /// Snapshot of the learned θ per arm, for tests/UI.
    func thetaSnapshot() -> [MutationOperator: [Double]] {
        lock.lock(); defer { lock.unlock() }
        return theta
    }

    /// Current policy entropy in nats. High = exploratory, low =
    /// exploitative. Useful for telemetry plots.
    func entropy(for features: LandscapeFeatures) -> Double {
        let probs = policy(for: features)
        return probs.reduce(0.0) { acc, pair in
            pair.value > 0 ? acc - pair.value * log(pair.value) : acc
        }
    }

    func reset() {
        lock.lock(); defer { lock.unlock() }
        for op in MutationOperator.allCases {
            theta[op] = Array(repeating: 0.0, count: dimension)
        }
        baseline = 0
        updateCount = 0
    }
}
