import Foundation

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

/// Bounded LRU memoization wrapper over `IntentGraph.build`.
final class IntentGraphCache: Sendable {

    private let cache: ShardedLRUCache<IntentGraph>

    /// `capacity = 8` matches the typical "current intent set + a
    /// handful of recent edits / what-if scenarios" working set
    /// observed in interactive editing sessions. Bump for batch
    /// pipelines that page through many distinct intent lists.
    init(capacity: Int = 8) {
        self.cache = ShardedLRUCache(capacity: capacity)
    }

    /// Return the graph built from `intents`, building once and
    /// caching by content hash. The hash is order-sensitive
    /// (different orderings of the same intents produce different
    /// graphs because dependency resolution is order-aware).
    func graph(for intents: [ScheduleIntent]) -> IntentGraph {
        let key = Self.hashKey(intents)
        return cache.value(forKey: key) {
            IntentGraph.build(from: intents)
        }
    }

    /// Drop everything in the cache. Called from app-level lifecycle
    /// hooks (sign-out, calendar disconnect) where retained intent
    /// graphs would leak the previous session's data.
    func invalidateAll() {
        cache.invalidateAll()
    }

    /// Aggregate hit rate, useful for telemetry. 0 means cold (no
    /// lookups yet), not "ineffective".
    var hitRate: Double { cache.hitRate }

    /// Compose a single 64-bit content hash over an intent array.
    /// `Hasher.finalize()` returns an `Int` whose top bits are the
    /// platform-randomized seed; we widen to `UInt64` so equality
    /// comparisons stay portable.
    private static func hashKey(_ intents: [ScheduleIntent]) -> UInt64 {
        var hasher = Hasher()
        hasher.combine(intents.count)
        for intent in intents { hasher.combine(intent) }
        return UInt64(bitPattern: Int64(hasher.finalize()))
    }
}

// MARK: - ScheduleConflictGraph Cache

/// Bounded LRU memoization wrapper over
/// `ScheduleConflictGraph.build`. Mirrors `IntentGraphCache` but keys
/// on the structural fields of `OptimizerContext.movableEvents` that
/// actually affect the graph (id, dependsOn, requiredParticipants,
/// preferredHourRange). Unrelated context (working hours, planning
/// horizon) is intentionally ignored so two contexts that differ only
/// in cosmetic fields share a cache slot.
final class ScheduleConflictGraphCache: Sendable {

    private let cache: ShardedLRUCache<ScheduleConflictGraph>

    init(capacity: Int = 8) {
        self.cache = ShardedLRUCache(capacity: capacity)
    }

    /// Cache by full context. Equivalent to `graph(forMovableEvents:)`
    /// — the cache key only inspects `context.movableEvents` since
    /// other context fields don't participate in conflict graph
    /// structure.
    func graph(for context: OptimizerContext) -> ScheduleConflictGraph {
        graph(forMovableEvents: context.movableEvents)
    }

    /// Cache by movable-event list directly. Lets callers (e.g.
    /// `IntentCompiler`) warm the cache *before* constructing the
    /// final `OptimizerContext`, so the holder they pass through can
    /// be preloaded with the cached graph in one pass instead of
    /// constructing a throwaway context.
    func graph(forMovableEvents events: [OptimizableEvent]) -> ScheduleConflictGraph {
        let key = Self.hashKey(events)
        return cache.value(forKey: key) {
            ScheduleConflictGraph.build(fromMovableEvents: events)
        }
    }

    func invalidateAll() {
        cache.invalidateAll()
    }

    var hitRate: Double { cache.hitRate }

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
