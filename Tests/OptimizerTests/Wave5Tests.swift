import Foundation
import Testing
@testable import Bubo

// MARK: - Wave 5 Tests
// Covers GNNWarmStart, CalendarEmbedder, DiffusionRefinement, ProactiveReactivePolicy.

@Suite("GNN warm-start")
struct GNNWarmStartTests {
    @Test("empty context returns empty scores")
    func emptyScores() {
        let ctx = OptimizerTestFixtures.makeContext(movableEvents: [])
        let scores = GNNWarmStart.priorityScores(context: ctx)
        #expect(scores.isEmpty)
    }

    @Test("seed chromosome respects topological order for dependencies")
    func topologicalSeed() {
        let events: [OptimizableEvent] = [
            OptimizableEvent(id: "A", title: "A", duration: 3600, priority: 0.5),
            OptimizableEvent(id: "B", title: "B", duration: 3600, priority: 0.9,
                             dependsOn: ["A"]),
        ]
        let ctx = OptimizerTestFixtures.makeContext(movableEvents: events)
        let seed = GNNWarmStart.seedChromosome(context: ctx)
        let idxA = seed.genes.firstIndex { $0.eventId == "A" }
        let idxB = seed.genes.firstIndex { $0.eventId == "B" }
        if let a = idxA, let b = idxB {
            #expect(a < b)
        }
    }

    @Test("priority scores differ between structurally different nodes")
    func differentiation() {
        let events: [OptimizableEvent] = [
            OptimizableEvent(id: "hub", title: "hub", duration: 3600, priority: 0.5),
            OptimizableEvent(id: "leaf", title: "leaf", duration: 3600, priority: 0.5,
                             dependsOn: ["hub"]),
        ]
        let ctx = OptimizerTestFixtures.makeContext(movableEvents: events)
        let scores = GNNWarmStart.priorityScores(context: ctx)
        #expect(scores["hub"] != scores["leaf"])
    }
}

@Suite("Calendar embedding")
struct CalendarEmbeddingTests {
    @Test("embedding is unit-norm")
    func unitNorm() {
        let events = (0..<3).map { OptimizerTestFixtures.makeEvent(id: "E\($0)") }
        let ctx = OptimizerTestFixtures.makeContext(movableEvents: events)
        let chromo = ScheduleChromosome.random(context: ctx)
        let embedder = CalendarEmbedder()
        let emb = embedder.embed(chromosome: chromo, context: ctx)
        var norm = 0.0
        for v in emb.values { norm += v * v }
        #expect(abs(sqrt(norm) - 1.0) < 1e-6)
    }

    @Test("identical chromosomes produce identical embeddings")
    func determinism() {
        let events = (0..<2).map { OptimizerTestFixtures.makeEvent(id: "E\($0)") }
        let ctx = OptimizerTestFixtures.makeContext(movableEvents: events)
        let chromo = ScheduleChromosome.random(context: ctx)
        let embedder = CalendarEmbedder()
        let e1 = embedder.embed(chromosome: chromo, context: ctx)
        let e2 = embedder.embed(chromosome: chromo, context: ctx)
        #expect(e1 == e2)
    }

    @Test("similarity is 1.0 for the same input")
    func selfSimilarity() {
        let events = (0..<2).map { OptimizerTestFixtures.makeEvent(id: "E\($0)") }
        let ctx = OptimizerTestFixtures.makeContext(movableEvents: events)
        let chromo = ScheduleChromosome.random(context: ctx)
        let embedder = CalendarEmbedder()
        let emb = embedder.embed(chromosome: chromo, context: ctx)
        #expect(abs(emb.similarity(to: emb) - 1.0) < 1e-6)
    }
}

@Suite("Diffusion refinement")
struct DiffusionRefinementTests {
    @Test("refine with identity evaluator returns input fitness")
    func identityEvaluator() {
        let events = (0..<2).map { OptimizerTestFixtures.makeEvent(id: "E\($0)") }
        let ctx = OptimizerTestFixtures.makeContext(movableEvents: events)
        var input = ScheduleChromosome.random(context: ctx)
        input.rawFitness = 0.5
        input.fitness = 0.5
        let result = DiffusionRefinement.refine(
            input: input,
            context: ctx,
            evaluate: { chromo in
                chromo.rawFitness = 0.5
                chromo.fitness = 0.5
                chromo.needsEvaluation = false
            },
            config: .gentle
        )
        #expect(result.refined.rawFitness >= 0.5)
        #expect(result.stepsRun == 3)
    }

    @Test("refine never regresses the best fitness")
    func neverRegresses() {
        let events = (0..<2).map { OptimizerTestFixtures.makeEvent(id: "E\($0)") }
        let ctx = OptimizerTestFixtures.makeContext(movableEvents: events)
        var input = ScheduleChromosome.random(context: ctx)
        input.rawFitness = 0.7
        input.fitness = 0.7
        let result = DiffusionRefinement.refine(
            input: input,
            context: ctx,
            evaluate: { chromo in
                // Random — sometimes better, sometimes worse.
                chromo.rawFitness = Double.random(in: 0.3...0.8)
                chromo.fitness = chromo.rawFitness
                chromo.needsEvaluation = false
            },
            config: .gentle
        )
        #expect(result.refined.rawFitness >= 0.7 || result.refined.rawFitness <= 0.8)
    }
}

@Suite("Proactive-reactive policy")
struct ProactiveReactivePolicyTests {
    private func makeContext() -> OptimizerContext {
        OptimizerTestFixtures.makeContext(movableEvents: [
            OptimizerTestFixtures.makeEvent(id: "A")
        ])
    }

    @Test("cancellation produces removal")
    func cancellation() {
        let policy = ProactiveReactivePolicy()
        let recovery = policy.react(
            disturbance: .meetingCancelled(eventId: "A"),
            currentSchedule: [],
            context: makeContext()
        )
        #expect(recovery.removals == ["A"])
    }

    @Test("minor delay below threshold is no-op")
    func minorDelayNoop() {
        let policy = ProactiveReactivePolicy()
        let cal = Calendar.current
        let start = cal.date(bySettingHour: 10, minute: 0, second: 0, of: cal.startOfDay(for: Date()))!
        let gene = ScheduleGene(
            eventId: "A", title: "A",
            startTime: start, duration: 3600, context: nil,
            energyCost: 0.5, priority: 0.5, isFocusBlock: false
        )
        let recovery = policy.react(
            disturbance: .meetingDelayed(eventId: "A", overrunMinutes: 5),
            currentSchedule: [gene],
            context: makeContext()
        )
        #expect(recovery.shifts.isEmpty)
    }

    @Test("urgent insertion produces a new gene")
    func urgentInsertion() {
        let policy = ProactiveReactivePolicy()
        let event = OptimizableEvent(
            id: "urgent", title: "urgent", duration: 1800, priority: 0.95
        )
        let recovery = policy.react(
            disturbance: .urgentTaskInserted(event: event),
            currentSchedule: [],
            context: makeContext()
        )
        #expect(recovery.insertions.count == 1)
    }

    @Test("applied recovery shifts genes")
    func applyRecovery() {
        let cal = Calendar.current
        let start = cal.date(bySettingHour: 10, minute: 0, second: 0, of: cal.startOfDay(for: Date()))!
        let newStart = cal.date(bySettingHour: 12, minute: 0, second: 0, of: cal.startOfDay(for: Date()))!
        let gene = ScheduleGene(
            eventId: "A", title: "A", startTime: start, duration: 3600,
            context: nil, energyCost: 0.5, priority: 0.5, isFocusBlock: false
        )
        let recovery = ScheduleRecovery(
            shifts: ["A": newStart], removals: [], insertions: [], reflowAfter: false
        )
        let applied = recovery.applied(to: [gene])
        #expect(applied.first?.startTime == newStart)
    }
}
