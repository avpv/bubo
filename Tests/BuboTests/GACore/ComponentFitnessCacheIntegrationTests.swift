import Foundation
import Testing
@testable import Bubo
@testable import BuboDomain
@testable import BuboOptimizer

// MARK: - Cross-chromosome cache integration into FitnessEvaluator
//
// The unit-level `ComponentFitnessCacheTests` verifies the cache
// primitive in isolation. These tests cover the *integration*: when
// a `FitnessEvaluator` is built with a `componentFitnessCache`, two
// chromosomes whose component-C gene state hashes identically must
// produce one objective call, not two.

@Suite("ComponentFitnessCache integration with FitnessEvaluator")
struct ComponentFitnessCacheIntegrationTests {

    // MARK: - Probe objective
    //
    // Counts how many times `evaluateComponent` is called so the
    // tests can assert on cache hit/miss without needing GA-level
    // observability hooks.

    final class ProbeObjective: ComponentPartitionedObjective, @unchecked Sendable {
        let name = "Probe"
        var weight: Double = 1.0
        var callCount: Int = 0
        private let returnValue: Double

        init(returnValue: Double = 0.5) {
            self.returnValue = returnValue
        }

        func evaluateComponent(
            members: [String],
            chromosome: ScheduleChromosome,
            context: OptimizerContext
        ) -> Double {
            callCount += 1
            return returnValue
        }
    }

    // MARK: - Helpers

    private func makeContext() -> OptimizerContext {
        let events = [
            OptimizerTestFixtures.makeEvent(id: "a"),
            OptimizableEvent(id: "b", title: "b", duration: 3600, dependsOn: ["a"]),
            OptimizerTestFixtures.makeEvent(id: "c")
        ]
        return OptimizerTestFixtures.makeContext(movableEvents: events)
    }

    private func makeChromosome(context: OptimizerContext) -> ScheduleChromosome {
        let base = Date(timeIntervalSinceReferenceDate: 1_000_000)
        let genes = context.movableEvents.enumerated().map { (i, event) in
            ScheduleGene(
                eventId: event.id,
                title: event.title,
                startTime: base.addingTimeInterval(Double(i) * 3600),
                duration: event.duration,
                context: nil,
                energyCost: 0.5,
                priority: 0.5,
                isFocusBlock: false
            )
        }
        return ScheduleChromosome(genes: genes, needsEvaluation: true)
    }

    // MARK: - Cache reuse across chromosomes

    @Test("Two chromosomes with identical gene state share the cached score")
    func crossChromosomeCacheHit() {
        let context = makeContext()
        let probe = ProbeObjective()
        let cache = ComponentFitnessCache()
        let evaluator = FitnessEvaluator(
            objectives: [probe],
            constraintEngine: ConstraintEngine(constraints: []),
            componentFitnessCache: cache
        )

        var c1 = makeChromosome(context: context)
        var c2 = makeChromosome(context: context)

        evaluator.evaluateAndAssign(&c1, context: context)
        let firstCalls = probe.callCount
        #expect(firstCalls > 0, "First chromosome must trigger evaluation")

        evaluator.evaluateAndAssign(&c2, context: context)
        let secondCalls = probe.callCount

        // Second chromosome had identical gene state → every
        // component score returned from the cross-chromosome cache,
        // so the call count shouldn't have increased.
        #expect(secondCalls == firstCalls, "Identical gene state must hit the cache")
    }

    // MARK: - Cache misses on real changes

    @Test("Mutating a gene's startTime past the bucket boundary forces a recompute")
    func mutationMissesCache() {
        let context = makeContext()
        let probe = ProbeObjective()
        let cache = ComponentFitnessCache()
        let evaluator = FitnessEvaluator(
            objectives: [probe],
            constraintEngine: ConstraintEngine(constraints: []),
            componentFitnessCache: cache
        )

        var c1 = makeChromosome(context: context)
        evaluator.evaluateAndAssign(&c1, context: context)
        let firstCalls = probe.callCount

        // Shift gene "a" by > 60 seconds (default bucket) so the
        // cache key for the component containing it changes.
        var c2 = makeChromosome(context: context)
        if let idx = c2.genes.firstIndex(where: { $0.eventId == "a" }) {
            c2.genes[idx].startTime = c2.genes[idx].startTime.addingTimeInterval(120)
        }
        c2.needsEvaluation = true
        evaluator.evaluateAndAssign(&c2, context: context)

        // At least one component containing "a" had to recompute.
        #expect(probe.callCount > firstCalls, "Cross-bucket mutation must miss the cache")
    }

    // MARK: - Disabled cache

    @Test("Without a cache, every chromosome triggers a fresh evaluateComponent call")
    func noCacheRecomputesEveryTime() {
        let context = makeContext()
        let probe = ProbeObjective()
        // No componentFitnessCache supplied. Empty constraint engine
        // so synthetic genes pass the hard-constraint preflight and
        // actually reach `evaluatePerComponentWithDelta`.
        let evaluator = FitnessEvaluator(
            objectives: [probe],
            constraintEngine: ConstraintEngine(constraints: [])
        )

        var c1 = makeChromosome(context: context)
        var c2 = makeChromosome(context: context)
        evaluator.evaluateAndAssign(&c1, context: context)
        let firstCalls = probe.callCount

        evaluator.evaluateAndAssign(&c2, context: context)
        // Without the cache, c2 re-runs every component — call count
        // should at least double (one round per chromosome).
        #expect(probe.callCount >= firstCalls * 2)
    }

    // MARK: - Hit rate telemetry

    @Test("Cache hit rate reflects cross-chromosome reuse")
    func hitRateClimbsWithReuse() {
        let context = makeContext()
        let probe = ProbeObjective()
        let cache = ComponentFitnessCache()
        let evaluator = FitnessEvaluator(
            objectives: [probe],
            constraintEngine: ConstraintEngine(constraints: []),
            componentFitnessCache: cache
        )

        var c1 = makeChromosome(context: context)
        var c2 = makeChromosome(context: context)
        var c3 = makeChromosome(context: context)
        evaluator.evaluateAndAssign(&c1, context: context)
        evaluator.evaluateAndAssign(&c2, context: context)
        evaluator.evaluateAndAssign(&c3, context: context)

        // c1 misses on every component; c2 and c3 hit on every
        // component. Hit rate should be > 0.5 once two duplicates
        // have flowed through.
        #expect(cache.hitRate > 0.5)
    }
}
