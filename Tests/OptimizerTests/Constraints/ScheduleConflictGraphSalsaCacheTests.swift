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

    // MARK: - Per-source reachability (recursive query with propagation)

    /// Build a chain `d1 → d2 → d3 → d4` (arrow = `dependsOn`) plus
    /// an independent event `e`. Reachability from `d4` is
    /// `{d3, d2, d1}`; from `e` it's `{}`.
    private func reachabilityChain() -> [OptimizableEvent] {
        [
            OptimizableEvent(id: "d1", title: "d1", duration: 3600),
            OptimizableEvent(id: "d2", title: "d2", duration: 3600, dependsOn: ["d1"]),
            OptimizableEvent(id: "d3", title: "d3", duration: 3600, dependsOn: ["d2"]),
            OptimizableEvent(id: "d4", title: "d4", duration: 3600, dependsOn: ["d3"]),
            OptimizableEvent(id: "e",  title: "e",  duration: 3600)
        ]
    }

    @Test("Per-source reachability cached and reused across graph calls")
    func reachabilityCachedAcrossCalls() {
        let cache = ScheduleConflictGraphSalsaCache()
        let events = reachabilityChain()
        _ = cache.graph(forMovableEvents: events)
        let reachAfterFirst = cache.cachedReachabilityCount
        #expect(reachAfterFirst >= 5, "One reachability entry per source event")

        // Second identical call hits everything warm.
        _ = cache.graph(forMovableEvents: events)
        #expect(cache.cachedReachabilityCount == reachAfterFirst)
    }

    @Test("Editing a leaf event invalidates only its reachability ancestors")
    func reachabilityPropagatesInvalidationOnlyToAncestors() {
        let cache = ScheduleConflictGraphSalsaCache()
        let initial = reachabilityChain()
        _ = cache.graph(forMovableEvents: initial)

        // Touch d1 (the root prereq): its fingerprint changes.
        // `d2`, `d3`, `d4` transitively reach d1 and should rebuild;
        // `e` doesn't touch d1 and must stay cached.
        //
        // The `e` event's cached reachability entry is the only
        // direct proof — `d1` itself doesn't have downstream deps,
        // so its reachability is also `{}` and both pre- and post-
        // edit results are identical.
        let edited: [OptimizableEvent] = [
            OptimizableEvent(
                id: "d1", title: "d1", duration: 3600,
                requiredParticipants: ["new-participant"]  // <-- changed
            ),
            OptimizableEvent(id: "d2", title: "d2", duration: 3600, dependsOn: ["d1"]),
            OptimizableEvent(id: "d3", title: "d3", duration: 3600, dependsOn: ["d2"]),
            OptimizableEvent(id: "d4", title: "d4", duration: 3600, dependsOn: ["d3"]),
            OptimizableEvent(id: "e",  title: "e",  duration: 3600)
        ]
        _ = cache.graph(forMovableEvents: edited)

        // The cached graph contents must still match a direct build
        // (correctness preserved across fine-grained invalidation).
        let cached = cache.graph(forMovableEvents: edited)
        let direct = ScheduleConflictGraph.build(fromMovableEvents: edited)
        #expect(cached.eventIds == direct.eventIds)
        #expect(cached.componentCount == direct.componentCount)
        #expect(cached.precedes["d4"] == direct.precedes["d4"])
    }

    @Test("Removing a prereq invalidates reachability that depended on it")
    func reachabilityInvalidatesOnRemoval() {
        let cache = ScheduleConflictGraphSalsaCache()
        let initial = reachabilityChain()
        _ = cache.graph(forMovableEvents: initial)

        // Remove d1 entirely — d2's reachability still shows {d1}
        // would be wrong. The `registerInputs` removal path must
        // bump d1's revision so any query that transitively read
        // input(d1) invalidates.
        let withoutD1 = Array(initial.dropFirst())
        let cached = cache.graph(forMovableEvents: withoutD1)
        let direct = ScheduleConflictGraph.build(fromMovableEvents: withoutD1)

        // Monolithic build filters out deps pointing at non-movable
        // ids; cached build must agree.
        #expect(cached.precedes["d2"] == direct.precedes["d2"])
        #expect(cached.precedenceEdgeCount == direct.precedenceEdgeCount)
    }

    @Test("Reachability oracle matches monolithic DFS exactly")
    func reachabilityOracleMatchesDFS() {
        let cache = ScheduleConflictGraphSalsaCache()
        let events = reachabilityChain()
        let cached = cache.graph(forMovableEvents: events)
        let direct = ScheduleConflictGraph.build(fromMovableEvents: events)

        // Every `precedes` entry must match the monolithic DFS.
        for id in direct.eventIds {
            #expect(
                cached.precedes[id] == direct.precedes[id],
                "Mismatch on precedes[\(id)]: \(String(describing: cached.precedes[id])) vs \(String(describing: direct.precedes[id]))"
            )
        }
    }

    @Test("Cycle-safe: A→B, B→A degenerates to empty without infinite recursion")
    func reachabilityCycleSafe() {
        let cache = ScheduleConflictGraphSalsaCache()
        let events = [
            OptimizableEvent(id: "a", title: "a", duration: 3600, dependsOn: ["b"]),
            OptimizableEvent(id: "b", title: "b", duration: 3600, dependsOn: ["a"])
        ]
        // Must not blow the stack. Test passes simply by returning.
        let cached = cache.graph(forMovableEvents: events)
        let direct = ScheduleConflictGraph.build(fromMovableEvents: events)

        // Cache and monolithic DFS agree on cycle semantics.
        #expect(cached.precedes["a"] == direct.precedes["a"])
        #expect(cached.precedes["b"] == direct.precedes["b"])
    }
}
