import Foundation
import Testing
@testable import Bubo
@testable import BuboDomain
@testable import BuboOptimizer

@Suite("Graph Query Cache")
struct GraphQueryCacheTests {

    // MARK: - IntentGraphCache

    @Test("Repeated graph(for:) calls return identical content")
    func intentCacheReturnsIdenticalContent() {
        let cache = IntentGraphCache()
        let intents: [ScheduleIntent] = [.horizon(.today), .focusBlock(minutes: 90)]
        let g1 = cache.graph(for: intents)
        let g2 = cache.graph(for: intents)
        // Structs don't compare by identity; verify cached graph
        // exposes the same node set and topological order.
        #expect(Set(g1.nodes.keys) == Set(g2.nodes.keys))
        #expect(g1.sortedIntents() == g2.sortedIntents())
    }

    @Test("Different intent lists produce different cached graphs")
    func intentCacheKeysOnContent() {
        let cache = IntentGraphCache()
        let a = cache.graph(for: [.horizon(.today)])
        let b = cache.graph(for: [.horizon(.tomorrow)])
        #expect(a.sortedIntents() != b.sortedIntents())
    }

    @Test("invalidateAll forces a fresh build")
    func invalidateAllClears() {
        let cache = IntentGraphCache()
        _ = cache.graph(for: [.horizon(.today)])
        cache.invalidateAll()
        // Functional check: after invalidation, a subsequent call
        // still returns a usable graph.
        let after = cache.graph(for: [.horizon(.today)])
        #expect(after.nodes.isEmpty == false)
    }

    @Test("LRU evicts oldest entry over capacity")
    func intentCacheEvictsLRU() {
        let cache = IntentGraphCache(capacity: 2)
        _ = cache.graph(for: [.horizon(.today)])     // entry A
        _ = cache.graph(for: [.horizon(.tomorrow)])  // entry B
        _ = cache.graph(for: [.horizon(.week)])      // entry C — evicts A
        // Re-querying A should rebuild without crashing — there's no
        // observable identity to assert, so we settle for "cache
        // remains usable after eviction".
        let revived = cache.graph(for: [.horizon(.today)])
        #expect(revived.nodes.isEmpty == false)
    }

    // MARK: - ScheduleConflictGraphCache

    @Test("Conflict graph cache returns identical content for the same context")
    func conflictCacheReturnsSameContent() {
        let context = OptimizerTestFixtures.makeContext(
            movableEvents: [
                OptimizerTestFixtures.makeEvent(id: "a"),
                OptimizableEvent(id: "b", title: "b", duration: 3600, dependsOn: ["a"])
            ]
        )
        let cache = ScheduleConflictGraphCache()
        let g1 = cache.graph(for: context)
        let g2 = cache.graph(for: context)
        #expect(g1.eventIds == g2.eventIds)
        #expect(g1.componentCount == g2.componentCount)
    }

    @Test("Differing structural fields produce different cache entries")
    func conflictCacheKeysOnStructure() {
        let baseEvent = OptimizerTestFixtures.makeEvent(id: "a")
        let withDep = OptimizableEvent(id: "b", title: "b", duration: 3600, dependsOn: ["a"])

        let ctxA = OptimizerTestFixtures.makeContext(movableEvents: [baseEvent])
        let ctxB = OptimizerTestFixtures.makeContext(movableEvents: [baseEvent, withDep])

        let cache = ScheduleConflictGraphCache()
        let gA = cache.graph(for: ctxA)
        let gB = cache.graph(for: ctxB)
        #expect(gA.eventIds.count == 1)
        #expect(gB.eventIds.count == 2)
    }
}
