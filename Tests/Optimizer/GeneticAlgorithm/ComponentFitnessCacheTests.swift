import Foundation
import Testing
@testable import Bubo
@testable import BuboDomain
@testable import BuboOptimizer

@Suite("Component Fitness Cache")
struct ComponentFitnessCacheTests {

    // MARK: - Helpers

    private func gene(
        id: String,
        startSeconds: Double = 1_000_000,
        duration: TimeInterval = 3600
    ) -> ScheduleGene {
        ScheduleGene(
            eventId: id,
            title: id,
            startTime: Date(timeIntervalSinceReferenceDate: startSeconds),
            duration: duration,
            context: nil,
            energyCost: 0.5,
            priority: 0.5,
            isFocusBlock: false
        )
    }

    // MARK: - Lookup

    @Test("Miss returns nil")
    func missReturnsNil() {
        let cache = ComponentFitnessCache()
        let key = ComponentFitnessCache.componentKey(
            componentId: 0,
            geneIds: ["a"],
            geneByEvent: ["a": gene(id: "a")]
        )
        #expect(cache.value(for: key) == nil)
        #expect(cache.hitRate == 0.0)
    }

    @Test("Store then lookup returns the cached score")
    func storeThenLookup() {
        let cache = ComponentFitnessCache()
        let key = ComponentFitnessCache.componentKey(
            componentId: 0,
            geneIds: ["a"],
            geneByEvent: ["a": gene(id: "a")]
        )
        cache.store(key, value: 1.5)
        #expect(cache.value(for: key) == 1.5)
        // One hit, no misses → hitRate = 1.0.
        #expect(cache.hitRate == 1.0)
    }

    // MARK: - Key Stability

    @Test("Same gene state and same geneIds order produces the same key")
    func keyIsStableForSameOrder() {
        let geneById: [String: ScheduleGene] = [
            "a": gene(id: "a"),
            "b": gene(id: "b", startSeconds: 1_003_600)
        ]
        let k1 = ComponentFitnessCache.componentKey(
            componentId: 0,
            geneIds: ["a", "b"],
            geneByEvent: geneById
        )
        let k2 = ComponentFitnessCache.componentKey(
            componentId: 0,
            geneIds: ["a", "b"],
            geneByEvent: geneById
        )
        #expect(k1 == k2)
    }

    @Test("Different geneIds order produces different keys (caller must provide stable order)")
    func keyDependsOnOrder() {
        // Since `componentKey` no longer sorts defensively, callers are
        // responsible for passing a deterministic order — typically
        // whatever `ScheduleConflictGraph.allComponents()` returns,
        // which is stable for the graph's lifetime. Two different
        // orderings of the same gene set intentionally miss each
        // other's cache slots now, trading a theoretical cache hit
        // (which real callers never triggered) for a measurable
        // O(N log N)-per-component saving on every evaluation.
        let geneById: [String: ScheduleGene] = [
            "a": gene(id: "a"),
            "b": gene(id: "b", startSeconds: 1_003_600)
        ]
        let k1 = ComponentFitnessCache.componentKey(
            componentId: 0,
            geneIds: ["a", "b"],
            geneByEvent: geneById
        )
        let k2 = ComponentFitnessCache.componentKey(
            componentId: 0,
            geneIds: ["b", "a"],
            geneByEvent: geneById
        )
        #expect(k1 != k2)
    }

    @Test("Different startTime produces a different key")
    func startTimeAffectsKey() {
        let g1: [String: ScheduleGene] = ["a": gene(id: "a", startSeconds: 1_000_000)]
        let g2: [String: ScheduleGene] = ["a": gene(id: "a", startSeconds: 1_000_500)]

        let k1 = ComponentFitnessCache.componentKey(componentId: 0, geneIds: ["a"], geneByEvent: g1)
        let k2 = ComponentFitnessCache.componentKey(componentId: 0, geneIds: ["a"], geneByEvent: g2)
        #expect(k1 != k2)
    }

    @Test("Missing gene produces a distinct key from any present-gene state")
    func missingGeneAffectsKey() {
        let present: [String: ScheduleGene] = ["a": gene(id: "a")]
        let absent: [String: ScheduleGene] = [:]

        let k1 = ComponentFitnessCache.componentKey(componentId: 0, geneIds: ["a"], geneByEvent: present)
        let k2 = ComponentFitnessCache.componentKey(componentId: 0, geneIds: ["a"], geneByEvent: absent)
        #expect(k1 != k2)
    }

    // MARK: - LRU

    @Test("LRU eviction kicks in past capacity")
    func lruEvicts() {
        // The cache is backed by a SHARDED LRU (8 shards, per-shard
        // capacity ⌈capacity/8⌉): `capacity` is a lower bound on the
        // total, not a global entry cap, so three keys usually land in
        // three different shards and nothing evicts. Flood the cache
        // instead: with 100 sequential keys over single-slot shards,
        // the first key's shard is guaranteed to receive later inserts
        // and its per-shard LRU keeps only the newest. Deterministic —
        // fixed keys, fixed shard function.
        let cache = ComponentFitnessCache(capacity: 2)
        let first = ComponentFitnessKey(value: 1)
        cache.store(first, value: 1.0)
        for i in 2...100 {
            cache.store(ComponentFitnessKey(value: UInt64(i)), value: Double(i))
        }

        #expect(cache.value(for: first) == nil)
        // The most recent key in its shard always survives.
        #expect(cache.value(for: ComponentFitnessKey(value: 100)) == 100.0)
    }

    @Test("invalidateAll clears entries and counters")
    func invalidateAllClears() {
        let cache = ComponentFitnessCache()
        let k = ComponentFitnessKey(value: 7)
        cache.store(k, value: 9.0)
        _ = cache.value(for: k)

        cache.invalidateAll()
        #expect(cache.value(for: k) == nil)
        // Hit rate after invalidate considers only the single
        // post-invalidate miss — counters reset on invalidate.
        #expect(cache.hitRate == 0.0)
    }

    // MARK: - Hit Rate

    @Test("hitRate is hits / (hits + misses)")
    func hitRateMath() {
        let cache = ComponentFitnessCache()
        let k = ComponentFitnessKey(value: 11)
        cache.store(k, value: 0.5)
        _ = cache.value(for: k)            // hit
        _ = cache.value(for: ComponentFitnessKey(value: 12))  // miss
        #expect(abs(cache.hitRate - 0.5) < 1e-9)
    }

    // MARK: - Time Bucketing

    @Test("Sub-bucket startTime jitter still hits the same key")
    func subBucketJitterCollides() {
        // Default bucket = 60s; 12:00:00.0 and 12:00:00.4 should
        // collide because they round to the same bucket index.
        let baseSeconds = 1_000_000.0
        let g1: [String: ScheduleGene] = ["a": gene(id: "a", startSeconds: baseSeconds)]
        let g2: [String: ScheduleGene] = ["a": gene(id: "a", startSeconds: baseSeconds + 0.4)]

        let k1 = ComponentFitnessCache.componentKey(componentId: 0, geneIds: ["a"], geneByEvent: g1)
        let k2 = ComponentFitnessCache.componentKey(componentId: 0, geneIds: ["a"], geneByEvent: g2)
        #expect(k1 == k2)
    }

    @Test("Cross-bucket startTime shift produces a different key")
    func crossBucketShiftDiverges() {
        let baseSeconds = 1_000_000.0
        let g1: [String: ScheduleGene] = ["a": gene(id: "a", startSeconds: baseSeconds)]
        let g2: [String: ScheduleGene] = ["a": gene(id: "a", startSeconds: baseSeconds + 90)]  // > 1 bucket

        let k1 = ComponentFitnessCache.componentKey(componentId: 0, geneIds: ["a"], geneByEvent: g1)
        let k2 = ComponentFitnessCache.componentKey(componentId: 0, geneIds: ["a"], geneByEvent: g2)
        #expect(k1 != k2)
    }
}
