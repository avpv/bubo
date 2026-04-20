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
//     list. With ~65 known intents and the auto-resolver doing a fixed
//     number of passes, the rebuild is cheap individually but visible
//     across rapid-fire edits.
//
// The cache uses a small bounded LRU so memory stays predictable —
// graphs aren't shared across test cases or scenarios. Capacity is
// configurable; default 8 covers "current + a few recent what-if
// branches" without growing unbounded.

/// Bounded LRU memoization wrapper over `IntentGraph.build`. Thread-
/// safe via a single internal `NSLock`; reads and writes both go
/// through the lock because the LRU recency update is a write even on
/// a cache hit.
final class IntentGraphCache: @unchecked Sendable {

    // MARK: Storage

    private struct Entry {
        let key: UInt64
        let graph: IntentGraph
    }

    private let lock = NSLock()
    private var entries: [Entry] = []
    private let capacity: Int

    // MARK: Init

    /// `capacity = 8` matches the typical "current intent set + a
    /// handful of recent edits / what-if scenarios" working set
    /// observed in interactive editing sessions. Bump for batch
    /// pipelines that page through many distinct intent lists.
    init(capacity: Int = 8) {
        precondition(capacity > 0, "Cache capacity must be positive.")
        self.capacity = capacity
    }

    // MARK: Public API

    /// Return the graph built from `intents`, building once and
    /// caching by content hash. The hash is order-sensitive (different
    /// orderings of the same intents produce different graphs because
    /// dependency resolution is order-aware).
    func graph(for intents: [ScheduleIntent]) -> IntentGraph {
        let key = Self.hashKey(intents)

        lock.lock()
        if let idx = entries.firstIndex(where: { $0.key == key }) {
            // LRU touch: move the hit to the front so older entries
            // get evicted first under capacity pressure.
            let hit = entries.remove(at: idx)
            entries.insert(hit, at: 0)
            lock.unlock()
            return hit.graph
        }
        lock.unlock()

        // Build outside the lock so concurrent callers don't serialize
        // on the build itself. Two threads racing on the same input
        // will both build (cheap, microseconds) and the second store
        // wins — both return logically identical graphs.
        let built = IntentGraph.build(from: intents)

        lock.lock()
        // Re-check inside the lock: another caller may have populated
        // the entry while we were building.
        if let idx = entries.firstIndex(where: { $0.key == key }) {
            let existing = entries.remove(at: idx)
            entries.insert(existing, at: 0)
            lock.unlock()
            return existing.graph
        }
        entries.insert(Entry(key: key, graph: built), at: 0)
        if entries.count > capacity {
            entries.removeLast(entries.count - capacity)
        }
        lock.unlock()
        return built
    }

    /// Drop everything in the cache. Called from app-level lifecycle
    /// hooks (sign-out, calendar disconnect) where retained intent
    /// graphs would leak the previous session's data.
    func invalidateAll() {
        lock.lock()
        entries.removeAll()
        lock.unlock()
    }

    // MARK: Hashing

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

/// Bounded LRU memoization wrapper over `ScheduleConflictGraph.build`.
/// Mirrors `IntentGraphCache` but keys on the structural fields of
/// `OptimizerContext.movableEvents` that actually affect the graph
/// (id, dependsOn, requiredParticipants, preferredHourRange).
/// Unrelated context (working hours, planning horizon) is intentionally
/// ignored so two contexts that differ only in cosmetic fields share a
/// cache slot.
final class ScheduleConflictGraphCache: @unchecked Sendable {

    private struct Entry {
        let key: UInt64
        let graph: ScheduleConflictGraph
    }

    private let lock = NSLock()
    private var entries: [Entry] = []
    private let capacity: Int

    init(capacity: Int = 8) {
        precondition(capacity > 0, "Cache capacity must be positive.")
        self.capacity = capacity
    }

    func graph(for context: OptimizerContext) -> ScheduleConflictGraph {
        let key = Self.hashKey(context.movableEvents)

        lock.lock()
        if let idx = entries.firstIndex(where: { $0.key == key }) {
            let hit = entries.remove(at: idx)
            entries.insert(hit, at: 0)
            lock.unlock()
            return hit.graph
        }
        lock.unlock()

        let built = ScheduleConflictGraph.build(from: context)

        lock.lock()
        if let idx = entries.firstIndex(where: { $0.key == key }) {
            let existing = entries.remove(at: idx)
            entries.insert(existing, at: 0)
            lock.unlock()
            return existing.graph
        }
        entries.insert(Entry(key: key, graph: built), at: 0)
        if entries.count > capacity {
            entries.removeLast(entries.count - capacity)
        }
        lock.unlock()
        return built
    }

    func invalidateAll() {
        lock.lock()
        entries.removeAll()
        lock.unlock()
    }

    /// Hash only the fields that participate in graph structure. The
    /// goal is for two event lists that produce structurally identical
    /// conflict graphs to land in the same cache slot — adding a
    /// title or shifting a duration shouldn't bust the cache when
    /// neither affects the conflict layer.
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
