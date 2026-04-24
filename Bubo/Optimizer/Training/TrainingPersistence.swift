import Foundation

// MARK: - Training Persistence
//
// Codable snapshots of every learner that carries persistent state.
// The training coordinator writes these snapshots at the end of each
// training cycle and the host restores them on app launch so learned
// state survives across sessions.
//
// JSON-on-disk at a fixed path next to the replay buffer. Atomic
// writes (`.write(atomically:)`). Missing files are treated as
// "first run" and the host falls back to fresh learners.

struct PersistedDPOWeights: Codable, Sendable {
    let weights: [String: Double]
    let observedPairs: Int
    let savedAt: Date
}

struct PersistedChanceBufferStore: Codable, Sendable {
    struct Entry: Codable, Sendable {
        let titleKey: String
        let contextKey: String?
        let scheduledDurationBucket: Int
        let count: Int
        let meanLog: Double
        let m2Log: Double
    }
    let entries: [Entry]
    let savedAt: Date
}

struct PersistedBranchingBanditState: Codable, Sendable {
    struct Entry: Codable, Sendable {
        let regime: Int
        let policy: String
        let count: Int
        let meanReward: Double
    }
    let entries: [Entry]
    let savedAt: Date
}

/// One on-disk snapshot covering every trainable learner. Written as
/// a single file for atomic consistency across learner state —
/// partial restore would lead to drift between, e.g., DPO and its
/// prior.
struct TrainingSnapshot: Codable, Sendable {
    let dpo: PersistedDPOWeights?
    let buffers: PersistedChanceBufferStore?
    let branching: PersistedBranchingBanditState?
    let savedAt: Date
}

enum TrainingPersistence {
    /// Default on-disk location — sibling of the replay buffer.
    static func defaultSnapshotPath() -> String? {
        let fm = FileManager.default
        guard let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        let dir = support.appendingPathComponent("Bubo/Training", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("learner_snapshot.json").path
    }

    // MARK: - Save

    static func save(snapshot: TrainingSnapshot, to path: String) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(snapshot) else { return }
        let url = URL(fileURLWithPath: path)
        try? data.write(to: url, options: .atomic)
    }

    // MARK: - Load

    static func load(from path: String) -> TrainingSnapshot? {
        let url = URL(fileURLWithPath: path)
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(TrainingSnapshot.self, from: data)
    }

    // MARK: - DPO roundtrip

    static func capture(dpo: DPOWeightLearner) -> PersistedDPOWeights {
        PersistedDPOWeights(
            weights: dpo.currentWeights,
            observedPairs: dpo.observedPairCount,
            savedAt: Date()
        )
    }

    static func restore(
        dpo: DPOWeightLearner,
        from persisted: PersistedDPOWeights
    ) {
        // Direct rehydration via setWeights: persisted state becomes
        // the live state without going through the regulariser.
        // Pair count is preserved so SGD step sizes remain stable.
        dpo.setWeights(persisted.weights, observedPairs: persisted.observedPairs)
    }

    // MARK: - Chance-buffer roundtrip

    static func capture(buffers: ChanceConstrainedBufferStore) -> PersistedChanceBufferStore {
        PersistedChanceBufferStore(
            entries: buffers.exportSnapshot(),
            savedAt: Date()
        )
    }

    static func restore(
        buffers: ChanceConstrainedBufferStore,
        from persisted: PersistedChanceBufferStore
    ) {
        buffers.importSnapshot(persisted.entries)
    }

    // Branching-bandit persistence was retired with the
    // LearnedBranchingBandit type. `TrainingSnapshot.branching`
    // stays on the wire (optional) so older saved snapshots still
    // decode; the payload is ignored on restore.
}
