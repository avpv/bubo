import Foundation
import Testing
@testable import Bubo
@testable import BuboDomain
@testable import BuboOptimizer

@Suite("Sharded LRU Cache")
struct ShardedLRUCacheTests {

    // MARK: - Lookup-or-build

    @Test("First call builds; second call returns the cached value without rebuilding")
    func valueForKeyCachesBuild() {
        let cache = ShardedLRUCache<Int>(capacity: 8)
        var builds = 0
        let v1 = cache.value(forKey: 42) { builds += 1; return 100 }
        let v2 = cache.value(forKey: 42) { builds += 1; return 999 }
        #expect(v1 == 100)
        #expect(v2 == 100, "Cached value must be returned, not the new build")
        #expect(builds == 1)
    }

    // MARK: - Lookup-only / Store

    @Test("lookup returns nil on miss without inserting")
    func lookupReturnsNil() {
        let cache = ShardedLRUCache<Int>(capacity: 4)
        #expect(cache.lookup(forKey: 7) == nil)
        #expect(cache.count == 0)
    }

    @Test("store then lookup returns the stored value")
    func storeThenLookup() {
        let cache = ShardedLRUCache<String>(capacity: 4)
        cache.store(forKey: 1, value: "one")
        #expect(cache.lookup(forKey: 1) == "one")
    }

    // MARK: - Eviction

    @Test("Per-shard capacity caps total entries within rounding")
    func capacityCapEnforced() {
        // 8 capacity / 8 shards = 1 entry per shard. Inserting more
        // than that into a single shard evicts the LRU tail.
        let cache = ShardedLRUCache<Int>(capacity: 8, shards: 8)

        // Pick keys that hash into the same shard (key % 8 == 0).
        cache.store(forKey: 0, value: 0)
        cache.store(forKey: 8, value: 8)
        cache.store(forKey: 16, value: 16)

        // Per-shard cap = 1, so the older entries (0 and 8) evicted.
        #expect(cache.lookup(forKey: 0) == nil)
        #expect(cache.lookup(forKey: 8) == nil)
        #expect(cache.lookup(forKey: 16) == 16)
    }

    // MARK: - Telemetry

    @Test("hitRate reflects hits / (hits + misses)")
    func hitRateMath() {
        let cache = ShardedLRUCache<Int>(capacity: 4)
        cache.store(forKey: 1, value: 100)

        _ = cache.lookup(forKey: 1)  // hit
        _ = cache.lookup(forKey: 2)  // miss
        _ = cache.lookup(forKey: 3)  // miss

        // 1 hit / 3 total = 0.333…
        #expect(abs(cache.hitRate - (1.0 / 3.0)) < 1e-9)
    }

    @Test("invalidateAll resets entries and counters across every shard")
    func invalidateAllClears() {
        let cache = ShardedLRUCache<Int>(capacity: 8)
        for i in 0..<8 { cache.store(forKey: UInt64(i), value: Int(i)) }
        _ = cache.lookup(forKey: 0)

        cache.invalidateAll()
        #expect(cache.count == 0)
        #expect(cache.hitRate == 0)
    }
}
