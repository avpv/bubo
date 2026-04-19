import Foundation

// MARK: - Learned Branching Bandit (Wave 3 / п.13)
//
// The built-in CP repair uses dom/deg variable ordering and a
// caller-supplied value order. Both are static heuristics — good
// defaults but blind to the current instance's structure.
//
// This bandit learns which (feature-signature → branching policy)
// pairs perform best across repair invocations and nudges the solver
// toward those policies. Features describe the branching choice
// point (domain size, in-degree, average out-degree of remaining
// constraints, stagnation); arms are a small closed set of heuristic
// mixtures (dom-only, dom/deg, deg-only, activity-weighted, random).
//
// Linear UCB-style updates keep the implementation stateless at the
// arm level (no per-arm weight matrices — just running means +
// counts), which is adequate for a 5-arm discrete action space and
// keeps per-decision overhead sub-microsecond.

enum BranchingPolicy: String, CaseIterable, Sendable {
    /// Pick variable with smallest remaining domain.
    case domainOnly
    /// Pick variable with largest constraint degree.
    case degreeOnly
    /// dom/deg: smallest (domain / degree) ratio.
    case domOverDeg
    /// VSIDS: highest activity score.
    case activity
    /// Random — exploration fallback.
    case random
}

/// Feature vector describing one branching decision point. Low-dim
/// so a simple per-arm UCB converges fast.
struct BranchingDecisionFeatures: Sendable {
    /// Average domain size across unassigned variables, normalised
    /// by the max domain size at problem start. `[0, 1]`.
    let averageDomainRatio: Double
    /// Fraction of constraints still propagating (i.e. not yet
    /// fully determined by partial assignment). `[0, 1]`.
    let activeConstraintFraction: Double
    /// Stagnation signal from the outer GA bandit — mirror of
    /// `BanditContext.stagnation`. `[0, 1]`.
    let stagnation: Double
    /// Partial-assignment depth / total variables. `[0, 1]`.
    let searchDepth: Double

    /// Rough bucketing for discrete feature hashing. Quantises each
    /// [0,1] axis into 3 buckets → 3^4 = 81 total regimes. Fine
    /// enough to distinguish low/medium/high across each axis,
    /// coarse enough that per-(arm, regime) counts accumulate fast.
    var regimeKey: Int {
        let b0 = bucket(averageDomainRatio)
        let b1 = bucket(activeConstraintFraction)
        let b2 = bucket(stagnation)
        let b3 = bucket(searchDepth)
        return (((b0 * 3) + b1) * 3 + b2) * 3 + b3
    }

    private func bucket(_ v: Double) -> Int {
        if v < 0.33 { return 0 }
        if v < 0.66 { return 1 }
        return 2
    }
}

/// UCB1-tuned bandit over `BranchingPolicy`, sliced by feature regime.
/// Every (policy, regime) pair has its own running mean and count,
/// letting the same bandit instance adapt to the different dynamics
/// of early-vs-late branching within one run.
final class LearnedBranchingBandit: @unchecked Sendable {
    struct Configuration: Sendable {
        /// UCB exploration constant. √2 is the theoretical default
        /// for bounded rewards in [0, 1].
        let explorationC: Double
        /// Minimum samples per (arm, regime) before UCB is trusted.
        /// Below this we round-robin to bootstrap.
        let warmupSamplesPerArm: Int
        /// Exponential smoothing on per-arm rewards. Higher = faster
        /// adaptation, more variance.
        let rewardSmoothing: Double

        static let `default` = Configuration(
            explorationC: sqrt(2.0),
            warmupSamplesPerArm: 3,
            rewardSmoothing: 0.25
        )
    }

    let config: Configuration
    private let lock = NSLock()

    /// Per-(regime, policy) statistics. Keyed by (regime * arms + policy.index).
    private var counts: [Int: Int] = [:]
    private var meanReward: [Int: Double] = [:]
    private var totalDecisions: Int = 0

    init(config: Configuration = .default) {
        self.config = config
    }

    // MARK: - Select

    /// Pick a branching policy for the given feature regime. Uses
    /// UCB1-tuned when every arm has ≥ warmupSamplesPerArm in this
    /// regime; otherwise returns the least-played arm to bootstrap.
    func select(features: BranchingDecisionFeatures) -> BranchingPolicy {
        let regime = features.regimeKey
        lock.lock()
        defer { lock.unlock() }

        // Warmup: ensure every arm has baseline samples in this regime.
        for (i, policy) in BranchingPolicy.allCases.enumerated() {
            let key = regime * BranchingPolicy.allCases.count + i
            if (counts[key] ?? 0) < config.warmupSamplesPerArm {
                return policy
            }
        }

        let totalInRegime = BranchingPolicy.allCases.enumerated().reduce(0) { sum, pair in
            let key = regime * BranchingPolicy.allCases.count + pair.offset
            return sum + (counts[key] ?? 0)
        }
        let logT = log(Double(max(1, totalInRegime)))

        var bestPolicy = BranchingPolicy.allCases[0]
        var bestScore = -Double.infinity
        for (i, policy) in BranchingPolicy.allCases.enumerated() {
            let key = regime * BranchingPolicy.allCases.count + i
            let n = counts[key] ?? 1
            let mean = meanReward[key] ?? 0
            let score = mean + config.explorationC * sqrt(logT / Double(n))
            if score > bestScore {
                bestScore = score
                bestPolicy = policy
            }
        }
        return bestPolicy
    }

    // MARK: - Update

    /// Record the outcome of a branching decision. `reward` should
    /// be a unit-scaled signal — suggested: normalised fitness
    /// improvement of the repaired solution versus the pre-repair
    /// baseline.
    func observe(
        policy: BranchingPolicy,
        features: BranchingDecisionFeatures,
        reward: Double
    ) {
        let regime = features.regimeKey
        let armIdx = BranchingPolicy.allCases.firstIndex(of: policy) ?? 0
        let key = regime * BranchingPolicy.allCases.count + armIdx

        lock.lock()
        defer { lock.unlock() }

        let n = counts[key] ?? 0
        let previous = meanReward[key] ?? 0
        let updated: Double
        if n == 0 {
            updated = reward
        } else {
            // Exponential-ish blend for fast adaptation.
            let a = config.rewardSmoothing
            updated = (1 - a) * previous + a * reward
        }
        meanReward[key] = updated
        counts[key] = n + 1
        totalDecisions += 1
    }

    // MARK: - Introspection

    var totalObservations: Int {
        lock.lock(); defer { lock.unlock() }
        return totalDecisions
    }

    /// For a given regime, report each policy's mean reward +
    /// sample count. Useful for telemetry / unit tests.
    func summary(regime: Int) -> [(policy: BranchingPolicy, count: Int, mean: Double)] {
        lock.lock(); defer { lock.unlock() }
        return BranchingPolicy.allCases.enumerated().map { (i, p) in
            let key = regime * BranchingPolicy.allCases.count + i
            return (p, counts[key] ?? 0, meanReward[key] ?? 0)
        }
    }

    func reset() {
        lock.lock(); defer { lock.unlock() }
        counts.removeAll()
        meanReward.removeAll()
        totalDecisions = 0
    }

    // MARK: - Persistence

    /// Flatten the (regime, policy) statistics for serialisation.
    /// Only entries with at least one observation are exported.
    func exportSnapshot() -> [PersistedBranchingBanditState.Entry] {
        lock.lock()
        defer { lock.unlock() }
        var out: [PersistedBranchingBanditState.Entry] = []
        out.reserveCapacity(counts.count)
        for (key, count) in counts {
            let armCount = BranchingPolicy.allCases.count
            let armIdx = key % armCount
            let regime = key / armCount
            let policy = BranchingPolicy.allCases[armIdx].rawValue
            out.append(PersistedBranchingBanditState.Entry(
                regime: regime,
                policy: policy,
                count: count,
                meanReward: meanReward[key] ?? 0
            ))
        }
        return out
    }

    /// Replace state from a snapshot. Caller is expected to call
    /// before any observe() so totals stay coherent.
    func importSnapshot(_ entries: [PersistedBranchingBanditState.Entry]) {
        lock.lock()
        defer { lock.unlock() }
        counts.removeAll()
        meanReward.removeAll()
        let armCount = BranchingPolicy.allCases.count
        var totalObs = 0
        for entry in entries {
            guard let armIdx = BranchingPolicy.allCases.firstIndex(where: {
                $0.rawValue == entry.policy
            }) else { continue }
            let key = entry.regime * armCount + armIdx
            counts[key] = entry.count
            meanReward[key] = entry.meanReward
            totalObs += entry.count
        }
        totalDecisions = totalObs
    }
}
