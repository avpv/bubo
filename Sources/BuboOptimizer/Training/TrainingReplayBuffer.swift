import Foundation

// MARK: - Training Replay Buffer
//
// Persistent, capped, typed event store that the autonomous training
// pipeline reads from. Four event kinds are supported:
//
//   • preferencePair: winner/loser objective-score vectors — DPO
//     training data. Sourced from real user accept/reject events
//     and from the synthetic generator during cold-start.
//   • durationSample: (scheduled, actual) duration observation for
//     the chance-constrained buffer fitter.
//   • branchingDecision: (features, policy, reward) tuple from the
//     CP-SAT learned-branching bandit's online observations.
//   • embeddingContrast: (anchorGenes, targetGenes, signedWeight)
//     — anchored contrastive pairs for the calendar embedder.
//
// Storage backend is JSON-on-disk through Codable so the data
// survives app restarts and can be inspected manually during
// debugging. Read/write is lock-protected; writes are append-only.
// Rotation happens on a total-events cap (default 20k): older
// events are dropped FIFO so the active window always represents
// recent user behaviour.

public struct PreferencePairEvent: Codable, Sendable, Hashable {

    public init(
        timestamp: Date,
        winnerScores: [String: Double],
        loserScores: [String: Double],
        confidence: Double,
        source: Source
    ) {
        self.timestamp = timestamp
        self.winnerScores = winnerScores
        self.loserScores = loserScores
        self.confidence = confidence
        self.source = source
    }

    public let timestamp: Date
    public let winnerScores: [String: Double]
    public let loserScores: [String: Double]
    public let confidence: Double
    public let source: Source

    public enum Source: String, Codable, Sendable {
        case userAccept
        case userReject
        case userManualEdit
        case synthetic
    }
}

public struct DurationSampleEvent: Codable, Sendable, Hashable {

    public init(
        timestamp: Date,
        title: String,
        context: String?,
        scheduledDuration: TimeInterval,
        actualDuration: TimeInterval
    ) {
        self.timestamp = timestamp
        self.title = title
        self.context = context
        self.scheduledDuration = scheduledDuration
        self.actualDuration = actualDuration
    }

    public let timestamp: Date
    public let title: String
    public let context: String?
    public let scheduledDuration: TimeInterval
    public let actualDuration: TimeInterval
}

public struct BranchingDecisionEvent: Codable, Sendable, Hashable {

    public init(
        timestamp: Date,
        regimeKey: Int,
        policy: String,
        reward: Double
    ) {
        self.timestamp = timestamp
        self.regimeKey = regimeKey
        self.policy = policy
        self.reward = reward
    }

    public let timestamp: Date
    public let regimeKey: Int
    public let policy: String
    public let reward: Double
}

public struct EmbeddingContrastEvent: Codable, Sendable, Hashable {

    public init(
        timestamp: Date,
        anchor: [ScheduleGene],
        target: [ScheduleGene],
        signedWeight: Double
    ) {
        self.timestamp = timestamp
        self.anchor = anchor
        self.target = target
        self.signedWeight = signedWeight
    }

    public let timestamp: Date
    public let anchor: [ScheduleGene]
    public let target: [ScheduleGene]
    /// +1 = pull closer, -1 = push apart, magnitudes scale learning rate.
    public let signedWeight: Double
}

/// One typed event. Sum type so the buffer is homogeneous in
/// memory — each array entry is a single `TrainingEvent`, allowing
/// chronological iteration without a join across separate arrays.
public enum TrainingEvent: Codable, Sendable, Hashable {
    case preferencePair(PreferencePairEvent)
    case durationSample(DurationSampleEvent)
    case branchingDecision(BranchingDecisionEvent)
    case embeddingContrast(EmbeddingContrastEvent)

    public var timestamp: Date {
        switch self {
        case .preferencePair(let e): return e.timestamp
        case .durationSample(let e): return e.timestamp
        case .branchingDecision(let e): return e.timestamp
        case .embeddingContrast(let e): return e.timestamp
        }
    }
}

// MARK: - Buffer

/// Thread-safe, capped, on-disk training event buffer.
public final class TrainingReplayBuffer: @unchecked Sendable {
    public struct Configuration: Sendable {

        public init(
            capacity: Int,
            storagePath: String?,
            flushEveryN: Int
        ) {
            self.capacity = capacity
            self.storagePath = storagePath
            self.flushEveryN = flushEveryN
        }

        /// Maximum number of events retained. Older events evict FIFO.
        let capacity: Int
        /// Absolute path of the on-disk JSON file. When nil the
        /// buffer is memory-only (useful for unit tests and
        /// ephemeral runs).
        let storagePath: String?
        /// Flush to disk after every N appends. Lower values = safer
        /// against crashes, higher = less IO cost.
        let flushEveryN: Int

        static let `default` = Configuration(
            capacity: 20_000,
            storagePath: Self.defaultStoragePath(),
            flushEveryN: 32
        )

        static let memoryOnly = Configuration(
            capacity: 2_000,
            storagePath: nil,
            flushEveryN: 0
        )

        static func defaultStoragePath() -> String? {
            let fm = FileManager.default
            guard let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
                return nil
            }
            let dir = support.appendingPathComponent("Bubo/Training", isDirectory: true)
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
            return dir.appendingPathComponent("replay_buffer.json").path
        }
    }

    public let config: Configuration
    private let lock = NSLock()
    private var events: [TrainingEvent] = []
    private var appendsSinceFlush: Int = 0

    public init(config: Configuration = .default) {
        self.config = config
        load()
    }

    // MARK: - Append

    public func append(_ event: TrainingEvent) {
        lock.lock()
        events.append(event)
        if events.count > config.capacity {
            events.removeFirst(events.count - config.capacity)
        }
        appendsSinceFlush += 1
        let shouldFlush = config.flushEveryN > 0
            && appendsSinceFlush >= config.flushEveryN
        lock.unlock()
        if shouldFlush { flush() }
    }

    public func append(batch: [TrainingEvent]) {
        lock.lock()
        events.append(contentsOf: batch)
        if events.count > config.capacity {
            events.removeFirst(events.count - config.capacity)
        }
        appendsSinceFlush += batch.count
        let shouldFlush = config.flushEveryN > 0
            && appendsSinceFlush >= config.flushEveryN
        lock.unlock()
        if shouldFlush { flush() }
    }

    // MARK: - Read

    public var count: Int {
        lock.lock(); defer { lock.unlock() }
        return events.count
    }

    /// Snapshot of every preference pair event. Returned as a
    /// fresh array; caller can iterate without holding the lock.
    public func preferencePairs() -> [PreferencePairEvent] {
        lock.lock(); defer { lock.unlock() }
        return events.compactMap {
            if case .preferencePair(let e) = $0 { return e }
            return nil
        }
    }

    public func durationSamples() -> [DurationSampleEvent] {
        lock.lock(); defer { lock.unlock() }
        return events.compactMap {
            if case .durationSample(let e) = $0 { return e }
            return nil
        }
    }

    public func branchingDecisions() -> [BranchingDecisionEvent] {
        lock.lock(); defer { lock.unlock() }
        return events.compactMap {
            if case .branchingDecision(let e) = $0 { return e }
            return nil
        }
    }

    public func embeddingContrasts() -> [EmbeddingContrastEvent] {
        lock.lock(); defer { lock.unlock() }
        return events.compactMap {
            if case .embeddingContrast(let e) = $0 { return e }
            return nil
        }
    }

    /// Chronological range by timestamp. Inclusive on start, exclusive on end.
    public func events(from start: Date, to end: Date) -> [TrainingEvent] {
        lock.lock(); defer { lock.unlock() }
        return events.filter { $0.timestamp >= start && $0.timestamp < end }
    }

    // MARK: - Persistence

    /// Force-write to disk. Idempotent.
    public func flush() {
        guard let path = config.storagePath else { return }
        let snapshot: [TrainingEvent]
        lock.lock()
        snapshot = events
        appendsSinceFlush = 0
        lock.unlock()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(snapshot) else { return }
        let url = URL(fileURLWithPath: path)
        try? data.write(to: url, options: .atomic)
    }

    /// Reload from disk, replacing in-memory state. Called from
    /// init; exposed for tests.
    public func load() {
        guard let path = config.storagePath else { return }
        let url = URL(fileURLWithPath: path)
        guard let data = try? Data(contentsOf: url) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let loaded = try? decoder.decode([TrainingEvent].self, from: data) else { return }
        lock.lock()
        events = loaded
        appendsSinceFlush = 0
        lock.unlock()
    }

    /// Remove every event. Flushes immediately.
    public func reset() {
        lock.lock()
        events.removeAll(keepingCapacity: true)
        appendsSinceFlush = 0
        lock.unlock()
        flush()
    }
}
