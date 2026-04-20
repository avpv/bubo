import Foundation
import Testing
@testable import Bubo

@Suite("ScheduleConflictGraph Salsa cache")
struct ScheduleConflictGraphSalsaCacheTests {

    // MARK: - Helpers

    private func eventSet() -> [OptimizableEvent] {
        [
            OptimizableEvent(
                id: "a", title: "a", duration: 3600,
                requiredParticipants: ["alice"]
            ),
            OptimizableEvent(
                id: "b", title: "b", duration: 3600,
                requiredParticipants: ["alice"],
                dependsOn: ["a"]
            ),
            OptimizableEvent(
                id: "c", title: "c", duration: 3600,
                preferredHourRange: 9...12
            )
        ]
    }

    // MARK: - Basic memoization

    @Test("Repeated graph(forMovableEvents:) returns identical content")
    func warmHitReturnsSameContent() {
        let cache = ScheduleConflictGraphSalsaCache()
        let events = eventSet()
        let g1 = cache.graph(forMovableEvents: events)
        let g2 = cache.graph(forMovableEvents: events)
        #expect(g1.eventIds == g2.eventIds)
        #expect(g1.componentCount == g2.componentCount)
    }

    @Test("Different event shape produces a fresh whole-graph entry")
    func differentShapeBuildsFresh() {
        let cache = ScheduleConflictGraphSalsaCache()
        _ = cache.graph(forMovableEvents: Array(eventSet().prefix(2)))
        _ = cache.graph(forMovableEvents: eventSet())
        #expect(cache.cachedGraphCount == 2)
    }

    // MARK: - Fine-grained per-event reuse

    @Test("Shared events retain their metadata entries across shape changes")
    func eventMetadataPersistsAcrossShapeEdit() {
        let cache = ScheduleConflictGraphSalsaCache()
        let initial = Array(eventSet().prefix(2))
        _ = cache.graph(forMovableEvents: initial)
        let metaAfterFirst = cache.cachedEventMetadataCount

        // Expand the shape by adding event "c". Existing metadata
        // for "a" and "b" must stay cached.
        _ = cache.graph(forMovableEvents: eventSet())
        #expect(
            cache.cachedEventMetadataCount >= metaAfterFirst,
            "Adding an event must not drop existing metadata entries"
        )
    }

    // MARK: - Per-pair queries

    @Test("pairOverlap correctly detects shared participants")
    func pairOverlapDetectsParticipants() {
        let cache = ScheduleConflictGraphSalsaCache()
        let events = eventSet()
        let decision = cache.pairOverlap(events[0], events[1])
        #expect(decision.shareParticipant)
        #expect(decision.hasOverlap)
    }

    @Test("pairOverlap canonicalises pair order")
    func pairOverlapCanonicalPairOrder() {
        let cache = ScheduleConflictGraphSalsaCache()
        let events = eventSet()
        _ = cache.pairOverlap(events[0], events[1])
        let countAfterFirst = cache.cachedPairCount
        _ = cache.pairOverlap(events[1], events[0])  // reversed
        // Reversed order must hit the same cache slot.
        #expect(cache.cachedPairCount == countAfterFirst)
    }

    @Test("pairOverlap detects non-overlapping events")
    func pairOverlapDetectsIndependent() {
        let cache = ScheduleConflictGraphSalsaCache()
        let events = eventSet()
        // (a, c): no shared participant (alice vs none), no hour range overlap
        // (c has 9-12 preferred; a has none).
        let decision = cache.pairOverlap(events[0], events[2])
        #expect(decision.shareParticipant == false)
        #expect(decision.hourRangesOverlap == false)
        #expect(decision.hasOverlap == false)
    }

    // MARK: - Whole-graph LRU cap

    @Test("Whole-graph entries evict past capacity")
    func wholeGraphLRUEvicts() {
        let cache = ScheduleConflictGraphSalsaCache(wholeGraphCapacity: 2)
        let events = eventSet()
        _ = cache.graph(forMovableEvents: Array(events.prefix(1)))
        _ = cache.graph(forMovableEvents: Array(events.prefix(2)))
        _ = cache.graph(forMovableEvents: events)   // forces eviction
        #expect(cache.cachedGraphCount <= 2)
    }

    // MARK: - invalidateAll

    @Test("invalidateAll clears every layer")
    func invalidateAllClears() {
        let cache = ScheduleConflictGraphSalsaCache()
        let events = eventSet()
        _ = cache.graph(forMovableEvents: events)
        _ = cache.pairOverlap(events[0], events[1])
        #expect(cache.cachedGraphCount > 0)
        #expect(cache.cachedEventMetadataCount > 0)
        #expect(cache.cachedPairCount > 0)

        cache.invalidateAll()
        #expect(cache.cachedGraphCount == 0)
        #expect(cache.cachedEventMetadataCount == 0)
        #expect(cache.cachedPairCount == 0)
    }

    // MARK: - Build correctness preserved

    @Test("Cached graph has the same structure as a direct build")
    func cachedMatchesDirectBuild() {
        let cache = ScheduleConflictGraphSalsaCache()
        let events = eventSet()
        let cached = cache.graph(forMovableEvents: events)
        let direct = ScheduleConflictGraph.build(fromMovableEvents: events)

        #expect(cached.eventIds == direct.eventIds)
        #expect(cached.componentCount == direct.componentCount)
        #expect(cached.conflictEdgeCount == direct.conflictEdgeCount)
        #expect(cached.precedenceEdgeCount == direct.precedenceEdgeCount)
    }

    @Test("Context overload delegates to the movable-events path")
    func contextOverloadDelegates() {
        let cache = ScheduleConflictGraphSalsaCache()
        let context = OptimizerTestFixtures.makeContext(movableEvents: eventSet())
        let byContext = cache.graph(for: context)
        let byEvents = cache.graph(forMovableEvents: eventSet())
        // Both paths share the same cache slot.
        #expect(byContext.componentCount == byEvents.componentCount)
        #expect(cache.cachedGraphCount == 1)
    }
}
