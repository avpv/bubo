import Foundation

// MARK: - Training Metrics
//
// Lightweight running statistics the trainers emit so the host UI
// can surface "training progress" without subscribing to fine-
// grained hooks. Each training pass produces a `TrainingRound`
// record that the coordinator timestamps and accumulates in an
// in-memory ring buffer.

struct TrainingRound: Codable, Sendable, Hashable {
    let timestamp: Date
    /// Which training target this round advanced.
    let target: Target
    /// Number of training examples consumed.
    let samplesConsumed: Int
    /// Loss before the update (mean over the batch).
    let preLoss: Double
    /// Loss after the update (mean over the batch).
    let postLoss: Double
    /// 0…1 optional accuracy metric — meaningful for DPO and
    /// branching bandit; nil for buffer fitter (not a classification
    /// task).
    let accuracy: Double?
    /// Free-form kv pairs for per-trainer internals (e.g. current
    /// mean sigma for CMA-ME, clause count for branching bandit).
    let auxiliary: [String: Double]

    enum Target: String, Codable, Sendable {
        case dpo
        case calendarEmbedder
        case branchingBandit
        case chanceBufferFit
        case objectiveCluster
    }

    var improvement: Double { preLoss - postLoss }
}

final class TrainingMetricsLog: @unchecked Sendable {
    struct Configuration: Sendable {
        let capacity: Int
        static let `default` = Configuration(capacity: 512)
    }

    let config: Configuration
    private let lock = NSLock()
    private var rounds: [TrainingRound] = []

    init(config: Configuration = .default) {
        self.config = config
    }

    func record(_ round: TrainingRound) {
        lock.lock()
        defer { lock.unlock() }
        rounds.append(round)
        if rounds.count > config.capacity {
            rounds.removeFirst(rounds.count - config.capacity)
        }
    }

    /// All rounds since `from`, in chronological order.
    func rounds(since from: Date) -> [TrainingRound] {
        lock.lock(); defer { lock.unlock() }
        return rounds.filter { $0.timestamp >= from }
    }

    /// Aggregate summary per target.
    func summaryByTarget() -> [TrainingRound.Target: Summary] {
        lock.lock()
        let snapshot = rounds
        lock.unlock()
        var result: [TrainingRound.Target: Summary] = [:]
        for round in snapshot {
            var cur = result[round.target] ?? Summary()
            cur.rounds += 1
            cur.samples += round.samplesConsumed
            cur.lossPreSum += round.preLoss
            cur.lossPostSum += round.postLoss
            if let a = round.accuracy {
                cur.accuracySum += a
                cur.accuracyCount += 1
            }
            result[round.target] = cur
        }
        return result
    }

    struct Summary: Sendable {
        var rounds: Int = 0
        var samples: Int = 0
        var lossPreSum: Double = 0
        var lossPostSum: Double = 0
        var accuracySum: Double = 0
        var accuracyCount: Int = 0

        var meanPreLoss: Double { rounds > 0 ? lossPreSum / Double(rounds) : 0 }
        var meanPostLoss: Double { rounds > 0 ? lossPostSum / Double(rounds) : 0 }
        var meanAccuracy: Double? {
            accuracyCount > 0 ? accuracySum / Double(accuracyCount) : nil
        }
        var meanImprovement: Double { meanPreLoss - meanPostLoss }
    }

    func reset() {
        lock.lock()
        defer { lock.unlock() }
        rounds.removeAll(keepingCapacity: true)
    }
}
