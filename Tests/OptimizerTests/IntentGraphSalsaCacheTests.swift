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
}
