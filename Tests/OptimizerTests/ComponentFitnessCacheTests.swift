import Foundation
import Testing
@testable import Bubo

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

    @Test("Miss returns nil and bumps misses")
    func missReturnsNil() {
        let cache = ComponentFitnessCache()
        let key = ComponentFitnessCache.componentKey(
            componentId: 0,
            geneIds: ["a"],
            geneByEvent: ["a": gene(id: "a")]
        )
        #expect(cache.value(for: key) == nil)
        #expect(cache.hits == 0)
        #expect(cache.misses == 1)
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
        #expect(cache.hits == 1)
    }

    // MARK: - Key Stability

    @Test("Same gene state produces the same key regardless of array order")
    func keyIsOrderIndependent() {
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
        #expect(k1 == k2)
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
        let cache = ComponentFitnessCache(capacity: 2)
        let k1 = ComponentFitnessKey(value: 1)
        let k2 = ComponentFitnessKey(value: 2)
        let k3 = ComponentFitnessKey(value: 3)

        cache.store(k1, value: 1.0)
        cache.store(k2, value: 2.0)
        cache.store(k3, value: 3.0)  // evicts k1

        #expect(cache.value(for: k1) == nil)
        #expect(cache.value(for: k2) == 2.0)
        #expect(cache.value(for: k3) == 3.0)
    }

    @Test("invalidateAll clears entries and counters")
    func invalidateAllClears() {
        let cache = ComponentFitnessCache()
        let k = ComponentFitnessKey(value: 7)
        cache.store(k, value: 9.0)
        _ = cache.value(for: k)

        cache.invalidateAll()
        #expect(cache.value(for: k) == nil)
        // Lookup after invalidate counts as a fresh miss — `hits` was
        // reset, so the post-invalidate lookup is the only event.
        #expect(cache.hits == 0)
        #expect(cache.misses == 1)
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
}
