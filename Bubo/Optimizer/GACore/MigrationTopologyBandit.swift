import Foundation

// MARK: - Migration Topology Bandit (Wave 3 / п.18)
//
// The existing IslandModelGA migrates individuals between islands on
// a fixed topology (ring or fully-connected depending on config). In
// practice, different island pairs contribute very differently to the
// run's progress: a diverse island donating to a converged one usually
// yields a hypervolume gain, while migration between two already-
// similar islands wastes evaluation budget.
//
// This bandit picks (donor, receiver) island pairs via UCB weighted
// by the hypervolume delta the last migration on that pair produced.
// Donors with stale rewards naturally drop out of the roulette;
// productive pairs get picked more.
//
// Scope: standalone, plug into the host's migration loop. Does not
// modify IslandModelGA directly — the island GA asks this bandit for
// the next pair, then performs the transfer as usual. This lets
// callers A/B the fixed topology against the learned one without
// rewiring the engine.

/// One island pair (donor → receiver) with bandit statistics.
struct MigrationPair: Hashable, Sendable {
    let donor: Int
    let receiver: Int
}

/// Per-pair running stats. Exposed for telemetry / tests.
struct MigrationPairStats: Sendable {
    let pair: MigrationPair
    let selections: Int
    let meanReward: Double
    /// Generation at which the pair last produced a positive reward.
    /// Used to identify stale pairs worth disabling.
    let lastPositiveGeneration: Int
}

final class MigrationTopologyBandit: @unchecked Sendable {
    struct Configuration: Sendable {
        /// UCB exploration constant.
        let explorationC: Double
        /// Force-explore any pair with fewer than this many selections.
        let warmupSelectionsPerPair: Int
        /// Exponential reward blend. 0 = no history, 1 = never update.
        let rewardBlend: Double
        /// After this many generations with no positive reward, the
        /// pair's mean is reset to zero so UCB picks it up again.
        let stalePairAgeGenerations: Int

        static let `default` = Configuration(
            explorationC: sqrt(2.0),
            warmupSelectionsPerPair: 2,
            rewardBlend: 0.3,
            stalePairAgeGenerations: 50
        )
    }

    let config: Configuration
    let islandCount: Int

    private let lock = NSLock()
    private var selections: [MigrationPair: Int] = [:]
    private var means: [MigrationPair: Double] = [:]
    private var lastPositive: [MigrationPair: Int] = [:]
    private var generation: Int = 0

    init(islandCount: Int, config: Configuration = .default) {
        precondition(islandCount >= 2, "migration needs at least 2 islands")
        self.islandCount = islandCount
        self.config = config
    }

    // MARK: - Selection

    /// Pick the next (donor, receiver) migration pair. `k` pairs
    /// returns the top-k by UCB score, useful for batching
    /// multiple migrations per generation.
    func selectTopPairs(_ k: Int) -> [MigrationPair] {
        lock.lock()
        defer { lock.unlock() }
        generation += 1

        let allPairs = allUniquePairs()

        // Warmup path: any pair with fewer than warmupSelectionsPerPair selections.
        let warmupPool = allPairs.filter {
            (selections[$0] ?? 0) < config.warmupSelectionsPerPair
        }
        if warmupPool.count >= k {
            return Array(warmupPool.prefix(k))
        }

        // Age-out: reset mean for stale pairs so they re-enter contention.
        for pair in allPairs {
            let lp = lastPositive[pair] ?? -1
            if lp >= 0 && generation - lp > config.stalePairAgeGenerations {
                means[pair] = 0
            }
        }

        let totalSelections = allPairs.reduce(0) { $0 + (selections[$1] ?? 0) }
        let logT = log(Double(max(1, totalSelections)))

        let scored = allPairs.map { pair -> (MigrationPair, Double) in
            let n = selections[pair] ?? 1
            let mean = means[pair] ?? 0
            let ucb = mean + config.explorationC * sqrt(logT / Double(n))
            return (pair, ucb)
        }.sorted { $0.1 > $1.1 }

        // Combine warmup + UCB-ranked remainder, never exceeding k.
        var chosen: [MigrationPair] = warmupPool
        for (pair, _) in scored {
            if chosen.count >= k { break }
            if chosen.contains(pair) { continue }
            chosen.append(pair)
        }
        return chosen
    }

    /// Single-pair convenience.
    func selectOne() -> MigrationPair {
        selectTopPairs(1).first ?? MigrationPair(donor: 0, receiver: 1)
    }

    // MARK: - Update

    /// Record the hypervolume delta produced by a migration. Reward
    /// should be in roughly `[0, 1]`; negative rewards are valid
    /// (migration hurt the receiver) and push the pair down the
    /// UCB ranking.
    func observe(pair: MigrationPair, reward: Double) {
        lock.lock()
        defer { lock.unlock() }
        let n = selections[pair] ?? 0
        let prev = means[pair] ?? 0
        let updated: Double
        if n == 0 {
            updated = reward
        } else {
            let a = config.rewardBlend
            updated = (1 - a) * prev + a * reward
        }
        means[pair] = updated
        selections[pair] = n + 1
        if reward > 0 {
            lastPositive[pair] = generation
        }
    }

    // MARK: - Introspection

    func stats(for pair: MigrationPair) -> MigrationPairStats {
        lock.lock(); defer { lock.unlock() }
        return MigrationPairStats(
            pair: pair,
            selections: selections[pair] ?? 0,
            meanReward: means[pair] ?? 0,
            lastPositiveGeneration: lastPositive[pair] ?? -1
        )
    }

    var allStats: [MigrationPairStats] {
        lock.lock(); defer { lock.unlock() }
        return allUniquePairs().map { pair in
            MigrationPairStats(
                pair: pair,
                selections: selections[pair] ?? 0,
                meanReward: means[pair] ?? 0,
                lastPositiveGeneration: lastPositive[pair] ?? -1
            )
        }
    }

    func reset() {
        lock.lock(); defer { lock.unlock() }
        selections.removeAll()
        means.removeAll()
        lastPositive.removeAll()
        generation = 0
    }

    // MARK: - Internals

    /// Every directed donor→receiver pair with donor ≠ receiver.
    /// For N islands, this is N·(N-1) pairs.
    private func allUniquePairs() -> [MigrationPair] {
        var result: [MigrationPair] = []
        result.reserveCapacity(islandCount * (islandCount - 1))
        for d in 0..<islandCount {
            for r in 0..<islandCount where r != d {
                result.append(MigrationPair(donor: d, receiver: r))
            }
        }
        return result
    }
}
