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

public struct PersistedDPOWeights: Codable, Sendable {

    public init(
        weights: [String: Double],
        observedPairs: Int,
        savedAt: Date
    ) {
        self.weights = weights
        self.observedPairs = observedPairs
        self.savedAt = savedAt
    }

    public let weights: [String: Double]
    public let observedPairs: Int
    public let savedAt: Date
}

public struct PersistedChanceBufferStore: Codable, Sendable {

    public init(
        entries: [Entry],
        savedAt: Date
    ) {
        self.entries = entries
        self.savedAt = savedAt
    }

    public struct Entry: Codable, Sendable {

        public init(
            titleKey: String,
            contextKey: String?,
            scheduledDurationBucket: Int,
            count: Int,
            meanLog: Double,
            m2Log: Double
        ) {
            self.titleKey = titleKey
            self.contextKey = contextKey
            self.scheduledDurationBucket = scheduledDurationBucket
            self.count = count
            self.meanLog = meanLog
            self.m2Log = m2Log
        }

        public let titleKey: String
        public let contextKey: String?
        public let scheduledDurationBucket: Int
        public let count: Int
        public let meanLog: Double
        public let m2Log: Double
    }
    public let entries: [Entry]
    public let savedAt: Date
}

public struct PersistedBranchingBanditState: Codable, Sendable {

    public init(
        entries: [Entry],
        savedAt: Date
    ) {
        self.entries = entries
        self.savedAt = savedAt
    }

    public struct Entry: Codable, Sendable {

        public init(
            regime: Int,
            policy: String,
            count: Int,
            meanReward: Double
        ) {
            self.regime = regime
            self.policy = policy
            self.count = count
            self.meanReward = meanReward
        }

        public let regime: Int
        public let policy: String
        public let count: Int
        public let meanReward: Double
    }
    public let entries: [Entry]
    public let savedAt: Date
}

/// One on-disk snapshot covering every trainable learner. Written as
/// a single file for atomic consistency across learner state —
/// partial restore would lead to drift between, e.g., DPO and its
/// prior.
public struct TrainingSnapshot: Codable, Sendable {

    public init(
        dpo: PersistedDPOWeights?,
        buffers: PersistedChanceBufferStore?,
        branching: PersistedBranchingBanditState?,
        savedAt: Date
    ) {
        self.dpo = dpo
        self.buffers = buffers
        self.branching = branching
        self.savedAt = savedAt
    }

    public let dpo: PersistedDPOWeights?
    public let buffers: PersistedChanceBufferStore?
    public let branching: PersistedBranchingBanditState?
    public let savedAt: Date
}

public enum TrainingPersistence {
    /// Default on-disk location — sibling of the replay buffer.
    public static func defaultSnapshotPath() -> String? {
        let fm = FileManager.default
        guard let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        let dir = support.appendingPathComponent("Bubo/Training", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("learner_snapshot.json").path
    }

    // MARK: - Save

    public static func save(snapshot: TrainingSnapshot, to path: String) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(snapshot) else { return }
        let url = URL(fileURLWithPath: path)
        try? data.write(to: url, options: .atomic)
    }

    // MARK: - Load

    public static func load(from path: String) -> TrainingSnapshot? {
        let url = URL(fileURLWithPath: path)
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(TrainingSnapshot.self, from: data)
    }

    // MARK: - DPO roundtrip

    public static func capture(dpo: DPOWeightLearner) -> PersistedDPOWeights {
        PersistedDPOWeights(
            weights: dpo.currentWeights,
            observedPairs: dpo.observedPairCount,
            savedAt: Date()
        )
    }

    public static func restore(
        dpo: DPOWeightLearner,
        from persisted: PersistedDPOWeights
    ) {
        // Direct rehydration via setWeights: persisted state becomes
        // the live state without going through the regulariser.
        // Pair count is preserved so SGD step sizes remain stable.
        dpo.setWeights(persisted.weights, observedPairs: persisted.observedPairs)
    }

    // MARK: - Chance-buffer roundtrip

    public static func capture(buffers: ChanceConstrainedBufferStore) -> PersistedChanceBufferStore {
        PersistedChanceBufferStore(
            entries: buffers.exportSnapshot(),
            savedAt: Date()
        )
    }

    public static func restore(
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
