import Foundation

// MARK: - Island Config Meta-Bandit
//
// Epsilon-greedy bandit over the hand-coded per-island configuration
// variations used by `IslandModelGA.makeIslandConfigs`. For every
// island slot index beyond the first four (which are intentionally
// hard-specialised for exploit/explore/niche/day-block), we have a pool
// of variation recipes. Historically the code cycled through them in a
// round-robin modulo the slot index — which meant a variation that did
// terribly on a given workload kept getting assigned to a slot every
// run, wasting exploration budget.
//
// This bandit lets that allocation learn instead. Every variation has a
// running average of the *best island-local fitness* it produced
// across runs; when `makeIslandConfigs` asks which variation to put in
// a given slot, the bandit returns the variation with the highest
// running score (with epsilon probability of a uniform-random pick so
// we keep exploring).
//
// Thread safety: the bandit lives on `IslandModelGA` and is touched
// exactly twice per run (pre-configure, post-evolve) so simple NSLock
// suffices. Persistence uses UserDefaults + CloudSync mirroring
// `PreferenceLearner`.
//
// Caveats (flagged in Phase 3 design): the historical record starts
// empty, so until ~5 runs land, the bandit behaves like round-robin.
// That's intentional — data-free arm preference is noise, and the
// epsilon fallback keeps the population of variations broad.

final class IslandConfigMetaBandit: @unchecked Sendable {
    /// Running score per variation key — arithmetic mean of "best island
    /// fitness" over runs that used this variation.
    struct ArmScore: Codable {
        var pulls: Int
        var totalReward: Double
        var mean: Double { pulls > 0 ? totalReward / Double(pulls) : 0 }
    }

    /// Probability of picking a random variation instead of the best.
    /// 0.1 is conservative — ~90% of runs exploit the learned ordering,
    /// ~10% keep probing the rest so the bandit doesn't lock in on
    /// stale winners when workload characteristics drift.
    let epsilon: Double

    /// Minimum pulls a variation needs before the bandit prefers it on
    /// merit. Below this, the arm is treated as equally-informative as
    /// any uninformed alternative.
    let minPullsForExploit: Int

    private var scores: [String: ArmScore] = [:]
    private let lock = NSLock()

    private let persistenceKey = "BuboIslandConfigMetaBandit"
    private var cloudSyncObserver: Any?

    init(epsilon: Double = 0.1, minPullsForExploit: Int = 3) {
        self.epsilon = epsilon
        self.minPullsForExploit = minPullsForExploit
        load()
        setupCloudSync()
    }

    private func setupCloudSync() {
        cloudSyncObserver = NotificationCenter.default.addObserver(
            forName: CloudSyncService.didReceiveRemoteChange,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let key = notification.object as? String,
                  key == "BuboIslandConfigMetaBandit"
            else { return }
            self?.load()
        }
    }

    // MARK: - Select

    /// Choose a variation key for this run. `candidateKeys` is the
    /// ordered pool the caller wants to pick from; with epsilon
    /// probability we return a random one, otherwise the key with the
    /// highest mean reward (ties broken by candidate order so results
    /// are reproducible under a fixed seed).
    func select(from candidateKeys: [String], rng: GARandom) -> String {
        precondition(!candidateKeys.isEmpty, "need at least one candidate")
        if candidateKeys.count == 1 { return candidateKeys[0] }

        lock.lock()
        let local = scores
        lock.unlock()

        if rng.bool(probability: epsilon) {
            return candidateKeys[rng.int(in: 0..<candidateKeys.count)]
        }

        // Only exploit when the top arm has enough pulls to be trusted.
        // Otherwise fall back to the first candidate (round-robin
        // ordering) so cold starts behave deterministically.
        var best: (key: String, mean: Double)?
        for key in candidateKeys {
            guard let s = local[key], s.pulls >= minPullsForExploit else { continue }
            if best == nil || s.mean > best!.mean {
                best = (key, s.mean)
            }
        }
        return best?.key ?? candidateKeys[0]
    }

    // MARK: - Record

    /// Update a variation's running score with the observed best fitness
    /// from the island that used it. Called once per island after
    /// evolution finishes.
    func record(key: String, reward: Double) {
        lock.lock()
        var arm = scores[key] ?? ArmScore(pulls: 0, totalReward: 0)
        arm.pulls += 1
        arm.totalReward += reward
        scores[key] = arm
        lock.unlock()
        save()
    }

    // MARK: - Telemetry

    struct Snapshot: Sendable {
        let key: String
        let pulls: Int
        let meanReward: Double
    }

    var snapshot: [Snapshot] {
        lock.lock()
        defer { lock.unlock() }
        return scores.map { key, arm in
            Snapshot(key: key, pulls: arm.pulls, meanReward: arm.mean)
        }.sorted { $0.meanReward > $1.meanReward }
    }

    // MARK: - Persistence

    private func save() {
        lock.lock()
        let copy = scores
        lock.unlock()
        guard let data = try? JSONEncoder().encode(copy) else { return }
        UserDefaults.standard.set(data, forKey: persistenceKey)
        CloudSyncService.shared.push(persistenceKey)
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: persistenceKey),
              let decoded = try? JSONDecoder().decode([String: ArmScore].self, from: data)
        else { return }
        lock.lock()
        scores = decoded
        lock.unlock()
    }

    /// Drop every arm's record. For tests and explicit user-side resets.
    func reset() {
        lock.lock()
        scores = [:]
        lock.unlock()
        UserDefaults.standard.removeObject(forKey: persistenceKey)
    }
}
