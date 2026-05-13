import Foundation
import BuboDomain

// MARK: - Graph Query Cache (Salsa-lite)
//
// Memoizes the output of `IntentGraph.build(from:)` and
// `ScheduleConflictGraph.build(from:)` keyed on a content hash of the
// input. Adapted from the Salsa / Adapton query-engine pattern (cf.
// rustc, rust-analyzer): re-running a query with the same input
// returns the cached value instantly, without re-walking the input
// graph or re-running auto-resolution.
//
// Why this matters for Bubo:
//   * GA fitness loops touch the conflict graph many times per
//     generation. The existing `ConflictGraphHolder` already caches a
//     single graph per holder instance, but it doesn't help when the
//     user retries with a slightly different intent set or the
//     optimizer is re-invoked from a UI scenario panel.
//   * Intent compilation runs every time the user edits the chip
//     list. With ~65 known intents and the auto-resolver doing a
//     fixed number of passes, the rebuild is cheap individually but
//     visible across rapid-fire edits.
//
// Concurrency: backed by `ShardedLRUCache`, so concurrent GA
// evaluators that hash into different shards never contend on the
// lookup. See `ShardedLRUCache.swift` for the sharding model.

// MARK: - ScheduleConflictGraph Cache

/// Bounded LRU memoization wrapper over
/// `ScheduleConflictGraph.build`. Mirrors `IntentGraphCache` but keys
/// on the structural fields of `OptimizerContext.movableEvents` that
/// actually affect the graph (id, dependsOn, requiredParticipants,
/// preferredHourRange). Unrelated context (working hours, planning
/// horizon) is intentionally ignored so two contexts that differ only
/// in cosmetic fields share a cache slot.
public final class ScheduleConflictGraphCache: Sendable {

    private let cache: ShardedLRUCache<ScheduleConflictGraph>

    public init(capacity: Int = 8) {
        self.cache = ShardedLRUCache(capacity: capacity)
    }

    /// Cache by full context. Equivalent to `graph(forMovableEvents:)`
    /// — the cache key only inspects `context.movableEvents` since
    /// other context fields don't participate in conflict graph
    /// structure.
    public func graph(for context: OptimizerContext) -> ScheduleConflictGraph {
        graph(forMovableEvents: context.movableEvents)
    }

    /// Cache by movable-event list directly. Lets callers (e.g.
    /// `IntentCompiler`) warm the cache *before* constructing the
    /// final `OptimizerContext`, so the holder they pass through can
    /// be preloaded with the cached graph in one pass instead of
    /// constructing a throwaway context.
    public func graph(forMovableEvents events: [OptimizableEvent]) -> ScheduleConflictGraph {
        let key = Self.hashKey(events)
        return cache.value(forKey: key) {
            ScheduleConflictGraph.build(fromMovableEvents: events)
        }
    }

    public func invalidateAll() {
        cache.invalidateAll()
    }

    public var hitRate: Double { cache.hitRate }

    /// Hash only the fields that participate in graph structure. The
    /// goal is for two event lists that produce structurally
    /// identical conflict graphs to land in the same cache slot —
    /// adding a title or shifting a duration shouldn't bust the
    /// cache when neither affects the conflict layer.
    private static func hashKey(_ events: [OptimizableEvent]) -> UInt64 {
        var hasher = Hasher()
        hasher.combine(events.count)
        for event in events {
            hasher.combine(event.id)
            // dependsOn order matters because direct precedence edges
            // are emitted in array order; sort stabilises the hash so
            // two equivalent permutations collide.
            hasher.combine(event.dependsOn.sorted())
            hasher.combine(event.requiredParticipants.sorted())
            if let range = event.preferredHourRange {
                hasher.combine(range.lowerBound)
                hasher.combine(range.upperBound)
            } else {
                hasher.combine(Int.min)
            }
        }
        return UInt64(bitPattern: Int64(hasher.finalize()))
    }
}
