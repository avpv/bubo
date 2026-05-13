import Foundation
import Testing
@testable import Bubo
@testable import BuboDomain
@testable import BuboOptimizer

// MARK: - Multi-Fidelity Evaluator Tests (Wave 1 / item 15)

@Suite("Multi-fidelity evaluation funnel")
struct MultiFidelityEvaluatorTests {

    private func makeBatchContext() -> (OptimizerContext, [OptimizableEvent]) {
        let events = (0..<8).map { i in
            OptimizerTestFixtures.makeEvent(
                id: "E\(i)",
                durationMinutes: 60,
                priority: Double(i) / 10.0
            )
        }
        return (OptimizerTestFixtures.makeContext(movableEvents: events), events)
    }

    @Test("empty batch is a no-op")
    func emptyBatch() {
        let (ctx, _) = makeBatchContext()
        let evaluator = FitnessEvaluator.standard(preferences: ctx.preferences)
        let funnel = MultiFidelityEvaluator(
            surrogate: RBFSurrogate(),
            evaluator: evaluator
        )
        var batch: [ScheduleChromosome] = []
        let result = funnel.evaluateBatch(&batch, context: ctx)
        #expect(result.tier1 == 0)
        #expect(result.tier2 == 0)
    }

    @Test("warm-up sends every candidate to tier 2")
    func warmupPromotesAll() {
        let (ctx, _) = makeBatchContext()
        let evaluator = FitnessEvaluator.standard(preferences: ctx.preferences)
        let funnel = MultiFidelityEvaluator(
            surrogate: RBFSurrogate(),
            evaluator: evaluator,
            config: .default
        )
        var batch = (0..<6).map { _ in ScheduleChromosome.random(context: ctx) }
        let result = funnel.evaluateBatch(&batch, context: ctx)
        // With an untrained surrogate every chromosome falls through
        // to tier 2 because `surrogate.screen` returns
        // `.realEvaluate(reason: "warmup", ...)`.
        #expect(result.tier2 == batch.count)
        #expect(result.tier1 == 0)
        for chromo in batch {
            #expect(!chromo.needsEvaluation)
        }
    }

    @Test("already-evaluated chromosomes are skipped")
    func skipsAlreadyEvaluated() {
        let (ctx, _) = makeBatchContext()
        let evaluator = FitnessEvaluator.standard(preferences: ctx.preferences)
        let funnel = MultiFidelityEvaluator(
            surrogate: RBFSurrogate(),
            evaluator: evaluator
        )
        var batch = (0..<4).map { _ in ScheduleChromosome.random(context: ctx) }
        for i in batch.indices {
            batch[i].needsEvaluation = false
            batch[i].fitness = 0.5
            batch[i].rawFitness = 0.5
        }
        let result = funnel.evaluateBatch(&batch, context: ctx)
        #expect(result.skipped == 4)
    }
}
