import Foundation
import Testing
@testable import Bubo

@Suite("Contextual Crossover (Learned Linear Scorer)")
struct ContextualCrossoverTests {

    @Test("Attention head weights move under positive reward")
    func headWeightsUpdate() {
        let head = GeneAttentionHead(learningRate: 0.1)
        let initialWeights = head.currentWeights
        head.updateWeights(features: [1.0, 1.0, 1.0, 1.0, 1.0], rewardSign: 1.0)
        let updated = head.currentWeights
        #expect(updated != initialWeights)
        for (old, new) in zip(initialWeights, updated) {
            #expect(new > old)
        }
    }

    @Test("Crossover produces offspring with the same gene count")
    func offspringHasSameGeneCount() {
        let context = OptimizerTestFixtures.makeContext(
            movableEvents: [
                OptimizerTestFixtures.makeEvent(id: "t1"),
                OptimizerTestFixtures.makeEvent(id: "t2"),
                OptimizerTestFixtures.makeEvent(id: "t3")
            ]
        )
        let head = GeneAttentionHead()
        let p1 = ScheduleChromosome.random(context: context)
        let p2 = ScheduleChromosome.random(context: context)
        let (c1, c2) = ContextualCrossover.perform(p1, p2, context: context, head: head)
        #expect(c1.genes.count == p1.genes.count)
        #expect(c2.genes.count == p2.genes.count)
    }

    @Test("Default OptimizerContext auto-wires an attention head")
    func defaultContextWiresHead() {
        let context = OptimizerTestFixtures.makeContext(
            movableEvents: [
                OptimizerTestFixtures.makeEvent(id: "t1"),
                OptimizerTestFixtures.makeEvent(id: "t2")
            ]
        )
        let p1 = ScheduleChromosome.random(context: context)
        let p2 = ScheduleChromosome.random(context: context)
        let (c1, c2) = Crossover.perform(p1, p2, strategy: .contextual(temperature: 0.5), context: context)
        #expect(c1.genes.count == p1.genes.count)
        #expect(c2.genes.count == p2.genes.count)
    }
}
