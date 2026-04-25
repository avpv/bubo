import Foundation
import os

// MARK: - Sharded LRU Cache
//
// Bounded LRU keyed on a 64-bit content hash, partitioned across N
// independent shards. Each shard owns its own `OSAllocatedUnfairLock`
// + `[Entry]` LRU list, so two threads hashing into different shards
// never contend.
//
// Why sharding matters:
//   The GA evaluates offspring in parallel via
//   `DispatchQueue.concurrentPerform`. With a single global lock per
//   cache, every concurrent evaluator that misses the cache serializes
//   on the LRU touch (a write under the same lock as the read). Eight
//   shards spread that contention so on average only ~12% of
//   concurrent calls touch the same shard.
//
// Why `OSAllocatedUnfairLock` over `NSLock`:
//   On macOS 13+, `OSAllocatedUnfairLock` is the cheapest mutex Apple
//   ships — uncontended acquire is ~10 ns vs ~30-50 ns for `NSLock`,
//   and contended acquire avoids the priority-inversion that
//   `os_unfair_lock` is named for. The `Sendable`-friendly wrapper
//   keeps Swift 6 strict concurrency happy without the
//   `@unchecked Sendable` escape hatch the old `NSLock` version
//   needed.
//
// The cache stores entries per shard in MRU-first order. Hits move to
// the front; tail entries evict on overflow. Per-shard capacity is
// `ceil(capacity / shards)` so the total never exceeds `capacity`
// (within rounding).

final class ShardedLRUCache<Value: Sendable>: Sendable {

    // MARK: Storage

    private struct Entry: Sendable {
        let key: UInt64
        let value: Value
    }

    /// One shard's protected state. The lock guards both `entries`
    /// and the per-shard hit/miss counters so a single critical
    /// section covers "look up + update LRU + bump telemetry".
    private struct Shard: Sendable {
        var entries: [Entry] = []
        var hits: Int = 0
        var misses: Int = 0
    }

    /// `OSAllocatedUnfairLock<Shard>` keeps the lock and its protected
    /// state physically together so Swift 6 strict concurrency can
    /// prove the access pattern is sound. `withLock { state in … }`
    /// hands a mutable reference to `Shard` exclusively for the
    /// duration of the closure.
    private let shards: [OSAllocatedUnfairLock<Shard>]

    private let perShardCapacity: Int
    private let shardCount: Int

    // MARK: Init

    /// `shards` defaults to 8 — covers a 4-island GA with 2-3
    /// parallel evaluators per island while keeping LRU lists short
    /// enough that linear scan stays cache-friendly.
    init(capacity: Int, shards shardCount: Int = 8) {
        precondition(capacity > 0, "Cache capacity must be positive.")
        precondition(shardCount > 0, "Shard count must be positive.")
        // Round up so the total cache size is at least `capacity`.
        let perShard = max(1, (capacity + shardCount - 1) / shardCount)
        self.perShardCapacity = perShard
        self.shardCount = shardCount
        self.shards = (0..<shardCount).map { _ in
            OSAllocatedUnfairLock(initialState: Shard())
        }
    }

    // MARK: Public API

    /// Lookup-or-compute. On a miss, `build` runs *outside* the lock
    /// so concurrent callers don't serialize on the build itself —
    /// two threads racing on the same key may build twice; the second
    /// store wins and both return logically identical values, which
    /// is exactly the same correctness window the original
    /// `ConflictGraphHolder` accepted.
    func value(forKey key: UInt64, build: () -> Value) -> Value {
        let shardIndex = Int(key % UInt64(shardCount))
        let shard = shards[shardIndex]

        // Fast path: hit.
        if let hit = shard.withLock({ state -> Value? in
            if let idx = state.entries.firstIndex(where: { $0.key == key }) {
                let hit = state.entries.remove(at: idx)
                state.entries.insert(hit, at: 0)
                state.hits += 1
                return hit.value
            }
            state.misses += 1
            return nil
        }) {
            return hit
        }

        // Miss path: build outside the lock, then store.
        let built = build()

        return shard.withLock { state in
            // Re-check inside the lock: another caller may have
            // populated the slot while we were building.
            if let idx = state.entries.firstIndex(where: { $0.key == key }) {
                let existing = state.entries.remove(at: idx)
                state.entries.insert(existing, at: 0)
                return existing.value
            }
            state.entries.insert(Entry(key: key, value: built), at: 0)
            if state.entries.count > self.perShardCapacity {
                state.entries.removeLast(state.entries.count - self.perShardCapacity)
            }
            return built
        }
    }

    /// Lookup-only variant. Returns `nil` on miss without inserting
    /// anything; pair with `store(forKey:value:)` for callers that
    /// want to compute conditionally based on hit/miss (e.g.
    /// `ComponentFitnessCache`, where the caller decides whether the
    /// computed score is worth caching).
    func lookup(forKey key: UInt64) -> Value? {
        let shardIndex = Int(key % UInt64(shardCount))
        return shards[shardIndex].withLock { state -> Value? in
            if let idx = state.entries.firstIndex(where: { $0.key == key }) {
                let hit = state.entries.remove(at: idx)
                state.entries.insert(hit, at: 0)
                state.hits += 1
                return hit.value
            }
            state.misses += 1
            return nil
        }
    }

    /// Insert or refresh the entry at `key`. Existing entries are
    /// re-inserted at the MRU position so a re-store acts like an
    /// LRU touch.
    func store(forKey key: UInt64, value: Value) {
        let shardIndex = Int(key % UInt64(shardCount))
        shards[shardIndex].withLock { state in
            if let idx = state.entries.firstIndex(where: { $0.key == key }) {
                state.entries.remove(at: idx)
            }
            state.entries.insert(Entry(key: key, value: value), at: 0)
            if state.entries.count > self.perShardCapacity {
                state.entries.removeLast(state.entries.count - self.perShardCapacity)
            }
        }
    }

    /// Drop everything across all shards. Safe to call from any
    /// thread; each shard is invalidated independently.
    func invalidateAll() {
        for shard in shards {
            shard.withLock { state in
                state.entries.removeAll()
                state.hits = 0
                state.misses = 0
            }
        }
    }

    // MARK: Telemetry

    /// Aggregate hit rate across all shards. Returns 0 when no
    /// lookups have happened yet (cold cache, not "ineffective").
    var hitRate: Double {
        var totalHits = 0
        var totalMisses = 0
        for shard in shards {
            let (h, m) = shard.withLock { state in (state.hits, state.misses) }
            totalHits += h
            totalMisses += m
        }
        let total = totalHits + totalMisses
        guard total > 0 else { return 0 }
        return Double(totalHits) / Double(total)
    }

    /// Total entries currently held (sum across shards). Used by
    /// tests to assert eviction behaviour.
    var count: Int {
        var sum = 0
        for shard in shards {
            sum += shard.withLock { state in state.entries.count }
        }
        return sum
    }
}
