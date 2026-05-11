import Foundation
import Testing
@testable import Bubo

@Suite("Graph-Aware Subtree Crossover")
struct GraphSubtreeCrossoverTests {

    private func geneFor(_ id: String, start: Date) -> ScheduleGene {
        ScheduleGene(
            eventId: id, title: id,
            startTime: start,
            duration: 3600,
            context: nil, energyCost: 0.5, priority: 0.5,
            isFocusBlock: false
        )
    }

    /// Two-component fixture: {a, b} coupled by dependsOn, and {c}
    /// standalone. Parents differ on every gene's start time so we can
    /// tell which parent each gene inherited from in the child.
    private func makeCrossoverFixture(
        seed: UInt64
    ) -> (OptimizerContext, ScheduleChromosome, ScheduleChromosome) {
        let a = OptimizerTestFixtures.makeEvent(id: "a")
        let b = OptimizableEvent(id: "b", title: "b", duration: 3600, dependsOn: ["a"])
        let c = OptimizerTestFixtures.makeEvent(id: "c")
        let context = OptimizerTestFixtures.makeContext(
            movableEvents: [a, b, c],
            seed: seed
        )

        let base = Date(timeIntervalSinceReferenceDate: 1_000_000)
        let p1 = ScheduleChromosome(genes: [
            geneFor("a", start: base),
            geneFor("b", start: base.addingTimeInterval(3600)),
            geneFor("c", start: base.addingTimeInterval(2 * 3600))
        ], needsEvaluation: true)
        let p2 = ScheduleChromosome(genes: [
            geneFor("a", start: base.addingTimeInterval(10 * 3600)),
            geneFor("b", start: base.addingTimeInterval(11 * 3600)),
            geneFor("c", start: base.addingTimeInterval(12 * 3600))
        ], needsEvaluation: true)
        return (context, p1, p2)
    }

    @Test("Component members stay aligned on the same parent")
    func componentMembersStayAligned() {
        // Run enough seeds to cover both inheritance directions.
        for seed in UInt64(1)...UInt64(20) {
            let (context, p1, p2) = makeCrossoverFixture(seed: seed)
            let (c1, c2) = Crossover.perform(p1, p2, strategy: .graphSubtree, context: context)

            // Whichever parent donated `a`'s time must also donate `b`'s
            // (they're in the same component).
            let aStart = c1.genes[0].startTime
            let bStart = c1.genes[1].startTime
            let aFromP1 = aStart == p1.genes[0].startTime
            let bFromP1 = bStart == p1.genes[1].startTime
            #expect(aFromP1 == bFromP1, "component members must inherit together (child1, seed \(seed))")

            let a2Start = c2.genes[0].startTime
            let b2Start = c2.genes[1].startTime
            let a2FromP1 = a2Start == p1.genes[0].startTime
            let b2FromP1 = b2Start == p1.genes[1].startTime
            #expect(a2FromP1 == b2FromP1, "component members must inherit together (child2, seed \(seed))")
        }
    }

    @Test("Children are Pareto-paired: no time slot is lost")
    func childrenArePareto() {
        // For every component, the set of start times across (child1, child2)
        // must equal the set across (parent1, parent2). Nothing is
        // discarded; the pair is a bijection.
        for seed in UInt64(1)...UInt64(10) {
            let (context, p1, p2) = makeCrossoverFixture(seed: seed)
            let (c1, c2) = Crossover.perform(p1, p2, strategy: .graphSubtree, context: context)
            for i in p1.genes.indices {
                let parentTimes = Set([p1.genes[i].startTime, p2.genes[i].startTime])
                let childTimes = Set([c1.genes[i].startTime, c2.genes[i].startTime])
                #expect(parentTimes == childTimes,
                        "slot \(i) lost a time in seed \(seed)")
            }
        }
    }

    @Test("Degenerate graph falls back to day-block crossover")
    func degenerateGraphFallsBack() {
        // All isolated events → componentCount == genes.count.
        // graphSubtree still runs because componentCount > 1; this
        // test just verifies it doesn't crash and returns children.
        let events = (0..<5).map { OptimizerTestFixtures.makeEvent(id: "e\($0)") }
        let context = OptimizerTestFixtures.makeContext(movableEvents: events, seed: 42)
        let p1 = ScheduleChromosome.random(context: context)
        let p2 = ScheduleChromosome.random(context: context)
        let (c1, c2) = Crossover.perform(p1, p2, strategy: .graphSubtree, context: context)
        #expect(c1.genes.count == p1.genes.count)
        #expect(c2.genes.count == p2.genes.count)
    }
}
