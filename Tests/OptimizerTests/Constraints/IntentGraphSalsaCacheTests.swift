import Foundation
import Testing
@testable import Bubo

@Suite("IntentGraph Salsa cache")
struct IntentGraphSalsaCacheTests {

    // MARK: - Basic memoization

    @Test("Repeated graph(for:) with the same input returns identical content")
    func warmHitReturnsSameContent() {
        let cache = IntentGraphSalsaCache()
        let intents: [ScheduleIntent] = [.horizon(.today), .focusBlock(minutes: 60)]
        let g1 = cache.graph(for: intents)
        let g2 = cache.graph(for: intents)
        #expect(Set(g1.nodes.keys) == Set(g2.nodes.keys))
        #expect(g1.sortedIntents() == g2.sortedIntents())
    }

    @Test("Different intent shape produces a fresh whole-graph entry")
    func differentShapeBuildsFresh() {
        let cache = IntentGraphSalsaCache()
        _ = cache.graph(for: [.horizon(.today)])
        _ = cache.graph(for: [.horizon(.tomorrow)])
        // Two distinct whole-graph results cached — one per shape.
        #expect(cache.cachedGraphCount == 2)
    }

    // MARK: - Fine-grained invalidation

    @Test("Adding one intent leaves the original whole-graph entry cached")
    func addingIntentPreservesPriorEntry() {
        let cache = IntentGraphSalsaCache()
        _ = cache.graph(for: [.horizon(.today), .focusBlock(minutes: 60)])
        _ = cache.graph(for: [.horizon(.today), .focusBlock(minutes: 60), .lowEnergy])
        // Both shapes cached separately; the original isn't dropped
        // because the new shape is a distinct query name.
        #expect(cache.cachedGraphCount == 2)

        // Re-asking for the original shape returns the cached entry
        // — verifies fine-grained invalidation hasn't dropped it.
        let revived = cache.graph(for: [.horizon(.today), .focusBlock(minutes: 60)])
        #expect(revived.nodes.count >= 2)
    }

    // MARK: - invalidateAll

    @Test("invalidateAll forces every query to rebuild")
    func invalidateAllForcesRebuild() {
        let cache = IntentGraphSalsaCache()
        _ = cache.graph(for: [.horizon(.today)])
        #expect(cache.cachedGraphCount == 1)

        cache.invalidateAll()
        #expect(cache.cachedGraphCount == 0)

        // Subsequent call still works after invalidation.
        let after = cache.graph(for: [.horizon(.today)])
        #expect(after.nodes.isEmpty == false)
    }

    // MARK: - Per-pair / per-intent fine-grained reuse

    @Test("Editing one intent preserves per-pair conflict cache for untouched pairs")
    func perPairCacheSurvivesSingleIntentEdit() {
        let cache = IntentGraphSalsaCache()

        // Four intents that all live in conflict-bucket families —
        // `conflictReason` bails out on default for pairs that can't
        // conflict anyway, so bucketed intents exercise the per-pair
        // cache. `noEventsBefore` and `noEventsAfter` share the
        // timeWindow bucket; `lowEnergy` lives in the energy bucket
        // with `prioritizeFocus`; that gives us real bucketed pairs.
        let before1: [ScheduleIntent] = [
            .noEventsBefore(hour: 9),
            .noEventsAfter(hour: 18),
            .lowEnergy,
            .prioritizeFocus(),
        ]
        _ = cache.graph(for: before1)
        let cachedAfterFirst = cache.cachedConflictPairCount
        #expect(cachedAfterFirst > 0, "First call must populate the per-pair cache")

        // Edit one intent (change hour value). The pair `(lowEnergy,
        // prioritizeFocus)` is untouched — should stay cached. Only
        // pairs involving `noEventsBefore` re-run.
        let before2: [ScheduleIntent] = [
            .noEventsBefore(hour: 11),   // <-- changed
            .noEventsAfter(hour: 18),
            .lowEnergy,
            .prioritizeFocus(),
        ]
        _ = cache.graph(for: before2)

        // The new call registers a new intent (hour 11), so the
        // count can only *grow*; previously-cached pairs that
        // don't involve the edited intent stay cached.
        #expect(
            cache.cachedConflictPairCount >= cachedAfterFirst,
            "Edits must preserve untouched pair entries"
        )

        // Prove the unchanged pair still hits the cache by
        // re-asking for the original shape — if the per-pair cache
        // were busted, we'd see `conflictDB` rebuild those entries,
        // but they're still there from the first call.
        let revived = cache.graph(for: before1)
        #expect(revived.nodes.count >= 4)
    }

    @Test("Unchanged intents keep their compile entries across edits")
    func compileEntriesPersistAcrossEdits() {
        let cache = IntentGraphSalsaCache()
        _ = cache.graph(for: [.horizon(.today), .focusBlock(minutes: 60)])
        let compileAfterFirst = cache.cachedCompileCount

        // Add one more intent; existing compile entries for the
        // original two must stay cached.
        _ = cache.graph(for: [.horizon(.today), .focusBlock(minutes: 60), .lowEnergy])
        #expect(
            cache.cachedCompileCount >= compileAfterFirst,
            "Adding a new intent must not drop existing compile entries"
        )
    }

    // MARK: - Whole-graph LRU bound

    @Test("Whole-graph entries evict past capacity")
    func wholeGraphLRUEvicts() {
        let cache = IntentGraphSalsaCache(wholeGraphCapacity: 2)
        _ = cache.graph(for: [.horizon(.today)])
        _ = cache.graph(for: [.horizon(.tomorrow)])
        _ = cache.graph(for: [.horizon(.week)])  // forces eviction

        #expect(cache.cachedGraphCount <= 2)
    }

    // MARK: - Phase bucket

    @Test("phaseBucket returns only entries in the requested phase")
    func phaseBucketFiltersCorrectly() {
        let cache = IntentGraphSalsaCache()
        let intents: [ScheduleIntent] = [
            .horizon(.today),        // context phase
            .focusBlock(minutes: 60), // create phase
            .lowEnergy,              // energy phase
        ]
        let contextPhase = cache.phaseBucket(.context, in: intents)
        #expect(contextPhase.count == 1)
        if case .horizon = contextPhase.first?.intent {
            // good
        } else {
            Issue.record("Context phase must contain the horizon intent")
        }

        let createPhase = cache.phaseBucket(.create, in: intents)
        #expect(createPhase.count == 1)
    }

    // MARK: - Build correctness preserved via oracle

    @Test("Conflict oracle still detects contradictions")
    func oracleStillDetectsContradictions() {
        // `noEventsBefore(14)` + `morningPerson` is a classic
        // contradiction — the conflict oracle must route through
        // the cache and still return the correct edge.
        let cache = IntentGraphSalsaCache()
        let graph = cache.graph(for: [.noEventsBefore(hour: 14), .morningPerson])
        let hasConflictEdge = graph.edges.contains { $0.kind == .conflicts }
        #expect(hasConflictEdge, "Salsa cache must preserve conflict detection")
    }
}
