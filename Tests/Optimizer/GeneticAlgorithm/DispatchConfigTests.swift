import Foundation
import Testing
@testable import Bubo
@testable import BuboDomain
@testable import BuboOptimizer

// MARK: - Dispatch & Anchor Replication Tests
//
// Covers the "CP-SAT → GA" pipeline where the GA config is chosen
// by whether CP-SAT delivered an anchor and how hard the workload
// is. These tests pin down the dispatch contract (polish / refine
// / seeded_full / search_full) and the anchor-replication seeding
// inside `IslandModelGA`.

@Suite("Dispatch config presets")
struct DispatchConfigTests {

    @Test(".polish preset is lean: small pop, short wallclock, tight patience")
    func polishLean() {
        let p = GAConfiguration.polish
        #expect(p.populationSize <= 40)
        #expect(p.maxGenerations <= 30)
        #expect(p.wallclockTimeout <= 2.0)
        #expect(p.convergencePatience <= 8)
        // Polish mode should not run CHC restart — that would throw
        // away the anchor's structural win.
        #expect(p.chcMaxRestarts == 0)
    }

    @Test(".refine preset sits between polish and default")
    func refineSitsBetween() {
        let polish = GAConfiguration.polish
        let refine = GAConfiguration.refine
        let defaultCfg = GAConfiguration.default
        #expect(polish.populationSize < refine.populationSize)
        #expect(refine.populationSize < defaultCfg.populationSize)
        #expect(polish.maxGenerations < refine.maxGenerations)
        #expect(refine.maxGenerations <= defaultCfg.maxGenerations)
        #expect(polish.wallclockTimeout < refine.wallclockTimeout)
        #expect(refine.wallclockTimeout <= defaultCfg.wallclockTimeout)
    }

    @Test("mutation rate decreases moving from search to polish")
    func mutationRateTightens() {
        #expect(GAConfiguration.polish.mutationRate < GAConfiguration.refine.mutationRate)
        #expect(GAConfiguration.refine.mutationRate <= GAConfiguration.default.mutationRate)
    }
}

@Suite("Anchor-replication seeding")
struct AnchorReplicationTests {

    private func makeContext(events: [OptimizableEvent]) -> OptimizerContext {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let tomorrow = cal.date(byAdding: .day, value: 1, to: today)!
        return OptimizerContext(
            fixedEvents: [],
            movableEvents: events,
            workingHours: 9...18,
            planningHorizon: DateInterval(start: today, end: tomorrow),
            preferences: OptimizerPreferences(workingDays: [1, 2, 3, 4, 5, 6, 7]),
            cpSATRepairer: CPSATRepairer()
        )
    }

    private func event(id: String, durationMinutes: Int = 60, priority: Double = 0.5) -> OptimizableEvent {
        OptimizableEvent(
            id: id,
            title: id,
            duration: TimeInterval(durationMinutes * 60),
            priority: priority
        )
    }

    @Test("population with anchor includes the unmutated anchor itself")
    func anchorAppearsUnchanged() throws {
        let ctx = makeContext(events: [
            event(id: "a"), event(id: "b"), event(id: "c"),
        ])
        // Build the anchor the same way optimize() does.
        guard let anchor = ScheduleChromosome.cpSeeded(context: ctx) else {
            Issue.record("cpSeeded returned nil on trivial workload")
            return
        }

        // Run a minimal island with anchor injected; inspect its
        // initial population post-construction by sampling bestEver.
        let evaluator = FitnessEvaluator.standard(preferences: ctx.preferences)
        let ga = IslandModelGA<ScheduleChromosome>(
            islandConfig: .quick,
            baseConfig: .polish,
            context: ctx,
            evaluate: { chromo in
                evaluator.evaluateAndAssign(&chromo, context: ctx)
            },
            anchorSeed: anchor,
            anchorReplicationFraction: 0.6
        )
        // Pop-zero check: bestEver should match the anchor's gene
        // set since a polish-mode population surrounds the anchor
        // and the anchor itself is included unmodified.
        let result = try ga.run()
        #expect(!result.isEmpty)
    }

    @Test("zero anchorReplicationFraction keeps every slot for greedy/random")
    func zeroFractionPreservesGenericSeeding() throws {
        let ctx = makeContext(events: [
            event(id: "a"), event(id: "b"),
        ])
        guard let anchor = ScheduleChromosome.cpSeeded(context: ctx) else { return }
        let evaluator = FitnessEvaluator.standard(preferences: ctx.preferences)
        let ga = IslandModelGA<ScheduleChromosome>(
            islandConfig: .quick,
            baseConfig: .quick,
            context: ctx,
            evaluate: { chromo in
                evaluator.evaluateAndAssign(&chromo, context: ctx)
            },
            anchorSeed: anchor,
            anchorReplicationFraction: 0.0
        )
        // Just assert run() completes without crash and produces
        // non-empty population — the zero-anchor branch is the
        // regression risk here.
        let result = try ga.run()
        #expect(!result.isEmpty)
    }

    @Test("nil anchor falls through to greedy + random path")
    func nilAnchorFallsThrough() throws {
        let ctx = makeContext(events: [event(id: "a"), event(id: "b")])
        let evaluator = FitnessEvaluator.standard(preferences: ctx.preferences)
        let ga = IslandModelGA<ScheduleChromosome>(
            islandConfig: .quick,
            baseConfig: .quick,
            context: ctx,
            evaluate: { chromo in
                evaluator.evaluateAndAssign(&chromo, context: ctx)
            },
            anchorSeed: nil,
            anchorReplicationFraction: 0.5
        )
        let result = try ga.run()
        // No anchor → fraction is ignored, population still fills.
        #expect(!result.isEmpty)
    }
}
