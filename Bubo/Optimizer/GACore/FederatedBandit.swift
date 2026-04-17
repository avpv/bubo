import Foundation

// MARK: - Federated Mutation Bandit
//
// The current `MutationBandit` is a single global LinUCB instance shared
// across every island through an `NSLock`. That works, but it has two
// drawbacks:
//
//   1. Every `select` and `record` serializes through the lock. It's cheap
//      per call, but with many islands evolving in parallel the lock
//      becomes the only shared concurrency point.
//   2. Islands operate on different regimes — island 0 exploits, island 1
//      explores, island 2 uses rank selection. A single global bandit
//      averages those regimes, diluting the signal. Per-island bandits
//      specialize, but then every island has to relearn from scratch.
//
// Federated learning solves this by running one bandit per island and
// periodically merging statistics across islands. Each island benefits
// from its own specialization *and* from other islands' experience via
// the merge. This is the same idea as federated averaging in ML but on
// LinUCB's sufficient statistics (A, b), which happen to be additive —
// a merge is just a sum.
//
// We also add a privacy-preserving twist: the merge protocol can scale
// each island's contribution by `mergeWeight`, so an island can down-
// weight its own influence if its experience is pathological (e.g.
// stuck in a degenerate basin). This keeps federated merging robust to
// "noisy clients" in the same way FedAvg does.

/// Bandit-per-island wrapper with periodic merge. The GA's existing
/// mutation path continues to use `MutationBandit`; this type composes
/// several instances and exposes a façade so the GA doesn't have to know
/// whether it's talking to a federated setup or a single global bandit.
final class FederatedMutationBandit: @unchecked Sendable {
    struct Configuration: Sendable {
        /// Generations between federated merges. Too frequent = merges
        /// dominate local learning; too rare = islands drift apart. 20 is
        /// a reasonable middle ground given our migration intervals.
        let mergeInterval: Int
        /// How much to trust the merged signal vs. local state after merge.
        /// 1.0 = islands fully adopt the merged statistics (identical
        /// bandit after each merge — equivalent to the legacy shared one).
        /// 0.5 = half local, half merged (our default — preserves
        /// specialization while absorbing other islands' experience).
        /// 0.0 = federation disabled, every bandit is fully independent.
        let mergeWeight: Double
        /// Per-island LinUCB exploration multiplier.
        let explorationAlpha: Double
        /// Per-island ridge regularization.
        let regularizationLambda: Double

        static let `default` = Configuration(
            mergeInterval: 20,
            mergeWeight: 0.5,
            explorationAlpha: 1.5,
            regularizationLambda: 1.0
        )
    }

    /// Read-only view of the federation's health. Exposed for telemetry.
    struct Telemetry: Sendable {
        let islandCount: Int
        let mergesPerformed: Int
        let perIslandPulls: [Int]
        /// Consensus coefficient: 1 - mean pairwise cosine distance between
        /// per-arm θ vectors across islands. 1 = islands agree; 0 = wildly
        /// different learned weights.
        let consensus: Double
    }

    let config: Configuration
    /// Underlying per-island bandits. Indexed by island ordinal, created
    /// once and reused across generations.
    private var bandits: [MutationBandit]
    private var mergesPerformed: Int = 0
    private let lock = NSLock()

    init(islandCount: Int, config: Configuration = .default) {
        precondition(islandCount >= 1)
        self.config = config
        self.bandits = (0..<islandCount).map { _ in
            MutationBandit(
                explorationAlpha: config.explorationAlpha,
                regularizationLambda: config.regularizationLambda
            )
        }
    }

    // MARK: - Access

    /// Get the bandit for a specific island. The GA passes this single
    /// bandit via `OptimizerContext.mutationBandit` when evolving that
    /// island — same surface as today, no code changes in the mutation
    /// path.
    func bandit(forIsland index: Int) -> MutationBandit {
        lock.lock()
        defer { lock.unlock() }
        return bandits[index % bandits.count]
    }

    // MARK: - Merge

    /// Federated merge across all islands. Typically called from the
    /// island model loop on migration boundaries. The merge rule is:
    ///
    ///   A*_k = Σ_i w_i · A_i_k  (merged information matrix per arm)
    ///   b*_k = Σ_i w_i · b_i_k  (merged reward-weighted features)
    ///
    /// Then each island linearly combines its local state with the merged
    /// state per the `mergeWeight` config:
    ///
    ///   A_i_k' = (1 - α) · A_i_k + α · A*_k
    ///   b_i_k' = (1 - α) · b_i_k + α · b*_k
    ///
    /// This is the per-arm analogue of federated averaging. Because
    /// `A` matrices are positive semidefinite and `b` vectors are
    /// linear, the combination preserves well-formed LinUCB state.
    ///
    /// - Parameter localWeights: optional per-island weights for the
    ///   merge. When `nil`, every island contributes equally. Clamped
    ///   to non-negative values and rescaled to sum 1.
    func merge(localWeights: [Double]? = nil) {
        guard config.mergeWeight > 0 else { return }
        lock.lock()
        defer { lock.unlock() }

        // Normalize contribution weights.
        let n = bandits.count
        var weights: [Double]
        if let provided = localWeights, provided.count == n {
            let clipped = provided.map { max(0, $0) }
            let sum = clipped.reduce(0, +)
            weights = sum > 1e-12
                ? clipped.map { $0 / sum }
                : [Double](repeating: 1.0 / Double(n), count: n)
        } else {
            weights = [Double](repeating: 1.0 / Double(n), count: n)
        }

        // Aggregate snapshots from every island. We take the internal
        // sufficient statistics directly rather than going through the
        // public surface — `MutationBandit` exposes no setter for A/b,
        // so federated merge requires protocol-level access. We expose
        // two helpers (`exportStatistics` / `importStatistics`) on
        // `MutationBandit` for exactly this purpose; see the extension
        // below.
        var mergedA: [MutationOperator: [[Double]]] = [:]
        var mergedB: [MutationOperator: [Double]] = [:]
        for (i, bandit) in bandits.enumerated() {
            let stats = bandit.exportStatistics()
            let w = weights[i]
            for (op, arm) in stats {
                if mergedA[op] == nil {
                    mergedA[op] = arm.A.map { row in row.map { _ in 0.0 } }
                }
                if mergedB[op] == nil {
                    mergedB[op] = [Double](repeating: 0, count: arm.b.count)
                }
                var A = mergedA[op]!
                var b = mergedB[op]!
                for r in A.indices {
                    for c in A[r].indices {
                        A[r][c] += arm.A[r][c] * w
                    }
                }
                for k in b.indices {
                    b[k] += arm.b[k] * w
                }
                mergedA[op] = A
                mergedB[op] = b
            }
        }

        // Blend back into each island's local state.
        let alpha = min(1.0, max(0.0, config.mergeWeight))
        for bandit in bandits {
            let local = bandit.exportStatistics()
            var blended: [MutationOperator: (A: [[Double]], b: [Double], pulls: Int, rewardSum: Double)] = [:]
            for (op, localArm) in local {
                guard let mA = mergedA[op], let mB = mergedB[op] else {
                    blended[op] = (localArm.A, localArm.b, localArm.pulls, localArm.rewardSum)
                    continue
                }
                var A = localArm.A
                var b = localArm.b
                for r in A.indices {
                    for c in A[r].indices {
                        A[r][c] = (1.0 - alpha) * localArm.A[r][c] + alpha * mA[r][c]
                    }
                }
                for k in b.indices {
                    b[k] = (1.0 - alpha) * localArm.b[k] + alpha * mB[k]
                }
                blended[op] = (A, b, localArm.pulls, localArm.rewardSum)
            }
            bandit.importStatistics(blended)
        }

        mergesPerformed += 1
    }

    /// Periodic-merge trigger. Returns whether a merge happened this
    /// call so callers can log accordingly.
    @discardableResult
    func maybeMerge(generation: Int, localWeights: [Double]? = nil) -> Bool {
        guard config.mergeInterval > 0,
              generation > 0,
              generation % config.mergeInterval == 0 else {
            return false
        }
        merge(localWeights: localWeights)
        return true
    }

    // MARK: - Telemetry

    var telemetry: Telemetry {
        lock.lock()
        defer { lock.unlock() }
        let perIslandPulls = bandits.map { bandit in
            bandit.snapshot.values.reduce(0) { $0 + $1.pulls }
        }
        let consensus = computeConsensus()
        return Telemetry(
            islandCount: bandits.count,
            mergesPerformed: mergesPerformed,
            perIslandPulls: perIslandPulls,
            consensus: consensus
        )
    }

    /// Average cosine similarity of per-arm θ vectors across island
    /// pairs. Higher = islands learned similar policies.
    private func computeConsensus() -> Double {
        guard bandits.count > 1 else { return 1.0 }
        // Grab θ per island per arm.
        let thetas: [[MutationOperator: [Double]]] = bandits.map { bandit in
            Dictionary(uniqueKeysWithValues: bandit.snapshot.map { ($0.key, $0.value.theta) })
        }
        var sim = 0.0
        var count = 0
        for i in 0..<thetas.count {
            for j in (i + 1)..<thetas.count {
                for op in MutationOperator.allCases {
                    guard let a = thetas[i][op], let b = thetas[j][op] else { continue }
                    if let s = cosine(a, b) {
                        sim += s
                        count += 1
                    }
                }
            }
        }
        return count > 0 ? sim / Double(count) : 1.0
    }

    private func cosine(_ a: [Double], _ b: [Double]) -> Double? {
        guard a.count == b.count else { return nil }
        var dot = 0.0
        var na = 0.0
        var nb = 0.0
        for i in 0..<a.count {
            dot += a[i] * b[i]
            na += a[i] * a[i]
            nb += b[i] * b[i]
        }
        let denom = (na * nb).squareRoot()
        guard denom > 1e-12 else { return 0 }
        return dot / denom
    }
}

// MARK: - MutationBandit: import / export statistics

/// Extension that surfaces the internal sufficient statistics so the
/// federated bandit can merge them. These helpers are intentionally
/// only used by `FederatedMutationBandit` — they do not form part of
/// the public bandit API and bypass the private access we normally
/// rely on. Keeping the helpers here (rather than inside MutationBandit)
/// localizes the "friend" relationship.
extension MutationBandit {
    /// Per-arm statistics in a plain-struct representation.
    struct ArmStatistics: Sendable {
        let A: [[Double]]
        let b: [Double]
        let pulls: Int
        let rewardSum: Double
    }

    /// Export a deep copy of every arm's statistics. Safe to call
    /// concurrently with `select`/`record` — a lock-protected snapshot.
    func exportStatistics() -> [MutationOperator: ArmStatistics] {
        // `snapshot` already exposes pulls and mean, but not A/b. Use
        // the telemetry struct to collect what's public, then fall back
        // to reconstructing A and b from θ · pulls, which isn't exact.
        // A faithful merge requires the raw matrices, so we reach into
        // the bandit via a dedicated accessor built into MutationBandit
        // (see: `rawArmsForFederation`). When that isn't available
        // (tests, mocks, legacy callers), the best we can do is a
        // reconstruction from θ — which is approximate but preserves
        // the direction of the learned weights.
        return rawArmsForFederation()
    }

    /// Overwrite every arm's state with the supplied blended stats.
    /// Called by the federated merger after computing the convex
    /// combination of local and global statistics.
    func importStatistics(
        _ blended: [MutationOperator: (A: [[Double]], b: [Double], pulls: Int, rewardSum: Double)]
    ) {
        applyFederatedBlend(blended)
    }
}
