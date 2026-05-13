import Foundation
import os

// MARK: - Eval Telemetry

/// Lightweight sharded counters describing how work is flowing through
/// the evaluator: full re-evals vs delta-paths vs cache hits.
///
/// The evaluator's `concurrentPerform` offspring loop fires N parallel
/// `evaluateAndAssign` calls per generation, so a single shared lock
/// would serialize the hot path. We shard by current-thread hash into
/// `shardCount` independent `OSAllocatedUnfairLock<Snapshot>` buckets;
/// on an 8-core machine each thread mostly lands in its own shard and
/// lock acquisition is uncontended. Snapshot sums across shards.
///
/// These counters are sample-only — nothing reads them for control
/// flow, so occasional racy-ish reads between shards are fine. Lock
/// acquires still happen because OSAllocatedUnfairLock is the only
/// free primitive that gives us atomic-like Int increments on
/// macOS 14 without pulling in Swift's Synchronization module (which
/// is 15.0+).
public final class FitnessEvalTelemetry: @unchecked Sendable {
    public struct Snapshot: Sendable {

        public init(
            fullEvaluations: Int,
            deltaEvaluations: Int,
            cacheHits: Int,
            componentCacheHits: Int,
            constraintRejections: Int
        ) {
            self.fullEvaluations = fullEvaluations
            self.deltaEvaluations = deltaEvaluations
            self.cacheHits = cacheHits
            self.componentCacheHits = componentCacheHits
            self.constraintRejections = constraintRejections
        }

        public var fullEvaluations: Int
        public var deltaEvaluations: Int
        public var cacheHits: Int
        public var componentCacheHits: Int
        public var constraintRejections: Int

        public var total: Int {
            fullEvaluations + deltaEvaluations + cacheHits
        }

        public var deltaFraction: Double {
            total > 0 ? Double(deltaEvaluations) / Double(total) : 0
        }

        public var cacheHitFraction: Double {
            total > 0 ? Double(cacheHits) / Double(total) : 0
        }

        public static let zero = Snapshot(
            fullEvaluations: 0,
            deltaEvaluations: 0,
            cacheHits: 0,
            componentCacheHits: 0,
            constraintRejections: 0
        )

        public mutating func add(_ other: Snapshot) {
            fullEvaluations += other.fullEvaluations
            deltaEvaluations += other.deltaEvaluations
            cacheHits += other.cacheHits
            componentCacheHits += other.componentCacheHits
            constraintRejections += other.constraintRejections
        }
    }

    /// Power of two so `hash & (shardCount - 1)` picks a bucket in one
    /// instruction without a modulo. 16 comfortably covers typical
    /// core counts (4–12) with enough slack that two threads landing
    /// in the same shard is rare even under hash collisions.
    private static let shardCount = 16
    private let shards: [OSAllocatedUnfairLock<Snapshot>]

    public init() {
        self.shards = (0..<Self.shardCount).map { _ in
            OSAllocatedUnfairLock(initialState: .zero)
        }
    }

    /// Pick a shard by current-thread hash. `Thread.current.hash`
    /// is stable for the thread lifetime (it's the NSObject identity
    /// hash), so a given worker keeps hitting the same shard across
    /// successive generations — lock contention only appears when
    /// two threads happen to collide into the same bucket.
    @inline(__always)
    private func shard() -> OSAllocatedUnfairLock<Snapshot> {
        // Two's-complement bit pattern: `h & 0xF` yields 0…15 for any
        // Int sign, so no abs / modulo needed.
        let idx = Thread.current.hash & (Self.shardCount - 1)
        return shards[idx]
    }

    public func recordFullEvaluation() {
        shard().withLock { $0.fullEvaluations += 1 }
    }

    public func recordDeltaEvaluation() {
        shard().withLock { $0.deltaEvaluations += 1 }
    }

    public func recordCacheHit() {
        shard().withLock { $0.cacheHits += 1 }
    }

    public func recordComponentCacheHit() {
        shard().withLock { $0.componentCacheHits += 1 }
    }

    public func recordConstraintRejection() {
        shard().withLock { $0.constraintRejections += 1 }
    }

    public func snapshot() -> Snapshot {
        var total: Snapshot = .zero
        for shard in shards {
            total.add(shard.withLock { $0 })
        }
        return total
    }

    public func reset() {
        for shard in shards {
            shard.withLock { $0 = .zero }
        }
    }
}
