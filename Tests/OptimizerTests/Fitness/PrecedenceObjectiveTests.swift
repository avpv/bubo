import Foundation
import Testing
@testable import Bubo

@Suite("Precedence Objective")
struct PrecedenceObjectiveTests {

    private func geneFor(_ id: String, start: Date, minutes: Int = 60) -> ScheduleGene {
        ScheduleGene(
            eventId: id, title: id,
            startTime: start,
            duration: TimeInterval(minutes * 60),
            context: nil, energyCost: 0.5, priority: 0.5,
            isFocusBlock: false
        )
    }

    @Test("No precedence edges → neutral score 1.0")
    func noEdgesScoresNeutral() {
        let context = OptimizerTestFixtures.makeContext(
            movableEvents: [
                OptimizerTestFixtures.makeEvent(id: "a"),
                OptimizerTestFixtures.makeEvent(id: "b")
            ]
        )
        let chromo = ScheduleChromosome.random(context: context)
        let obj = PrecedenceObjective()
        let score = obj.evaluate(chromosome: chromo, context: context)
        #expect(score == 1.0)
    }

    @Test("Tightly-packed dependency scores near 1.0")
    func tightPackingScoresHigh() {
        let a = OptimizerTestFixtures.makeEvent(id: "a")
        let b = OptimizableEvent(id: "b", title: "b", duration: 3600, dependsOn: ["a"])
        let context = OptimizerTestFixtures.makeContext(movableEvents: [a, b])

        let base = Date(timeIntervalSinceReferenceDate: 1_000_000)
        let genes = [
            geneFor("a", start: base),
            geneFor("b", start: base.addingTimeInterval(3600)) // starts exactly when a ends
        ]
        let chromo = ScheduleChromosome(genes: genes, needsEvaluation: true)

        let obj = PrecedenceObjective()
        let score = obj.evaluate(chromosome: chromo, context: context)
        #expect(score > 0.95)
    }

    @Test("Wide gap decays score toward zero")
    func wideGapDecaysScore() {
        let a = OptimizerTestFixtures.makeEvent(id: "a")
        let b = OptimizableEvent(id: "b", title: "b", duration: 3600, dependsOn: ["a"])
        let context = OptimizerTestFixtures.makeContext(movableEvents: [a, b])

        let base = Date(timeIntervalSinceReferenceDate: 1_000_000)
        let genes = [
            geneFor("a", start: base),
            // 5 days later — far beyond target gap
            geneFor("b", start: base.addingTimeInterval(5 * 24 * 3600))
        ]
        let chromo = ScheduleChromosome(genes: genes, needsEvaluation: true)

        let obj = PrecedenceObjective()
        let score = obj.evaluate(chromosome: chromo, context: context)
        #expect(score < 0.01)
    }

    @Test("Violated precedence (dependent before prereq) scores zero")
    func violatedPrecedenceScoresZero() {
        let a = OptimizerTestFixtures.makeEvent(id: "a")
        let b = OptimizableEvent(id: "b", title: "b", duration: 3600, dependsOn: ["a"])
        let context = OptimizerTestFixtures.makeContext(movableEvents: [a, b])

        let base = Date(timeIntervalSinceReferenceDate: 1_000_000)
        let genes = [
            geneFor("a", start: base.addingTimeInterval(7200)), // a starts later
            geneFor("b", start: base)                            // b starts first (violation)
        ]
        let chromo = ScheduleChromosome(genes: genes, needsEvaluation: true)

        let obj = PrecedenceObjective()
        let score = obj.evaluate(chromosome: chromo, context: context)
        #expect(score == 0.0)
    }

    @Test("Dropped prerequisite doesn't tank the score")
    func droppedPrereqIsSkipped() {
        let a = OptimizableEvent(id: "a", title: "a", duration: 3600, isDroppable: true)
        let b = OptimizableEvent(id: "b", title: "b", duration: 3600, dependsOn: ["a"])
        let context = OptimizerTestFixtures.makeContext(movableEvents: [a, b])

        let base = Date(timeIntervalSinceReferenceDate: 1_000_000)
        var dropped = geneFor("a", start: base)
        dropped.isIncluded = false
        let genes = [
            dropped,
            geneFor("b", start: base.addingTimeInterval(3600))
        ]
        let chromo = ScheduleChromosome(genes: genes, needsEvaluation: true)

        let obj = PrecedenceObjective()
        let score = obj.evaluate(chromosome: chromo, context: context)
        // With the only prereq dropped, no pairs count → neutral 1.0.
        #expect(score == 1.0)
    }
}
