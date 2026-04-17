import Foundation
import Testing
@testable import Bubo

// MARK: - Full-Pipeline Integration Tests
//
// End-to-end tests that exercise the wired stack (BuboOptimizer →
// IslandModelGA → GeneticAlgorithm → schedule hooks) with a
// realistic synthetic workload and verify properties module-level
// tests cannot observe.
//
// Cancellation correctness is tested at the `GeneticAlgorithm`
// level for determinism: timing-based cancellation against
// `BuboOptimizer.optimize` is unreliable on CI (a `.quick` run can
// finish in <50ms), so we use a fixture evaluator with a
// controlled delay and assert the cancellation point precisely.

@Suite("Full Pipeline Integration")
struct FullPipelineIntegrationTests {

    // MARK: Fixture

    @MainActor
    private func makeWorkload(eventCount: Int = 8) -> OptimizerContext {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let end = cal.date(byAdding: .day, value: 2, to: today)!

        let events = (0..<eventCount).map { i in
            OptimizableEvent(
                id: "task-\(i)",
                title: "Task \(i)",
                duration: TimeInterval((30 + i * 15) * 60),
                priority: Double(i) / Double(eventCount),
                energyCost: 0.5,
                isFocusBlock: i.isMultiple(of: 3),
                storyPoints: i + 1
            )
        }

        return OptimizerContext(
            fixedEvents: [],
            movableEvents: events,
            workingHours: 9...18,
            planningHorizon: DateInterval(start: today, end: end),
            preferences: OptimizerPreferences(),
            rng: GARandom(seed: 0xBEE_F_42)
        )
    }

    // MARK: Tests

    @Test("optimize() completes and returns non-empty scenarios on .quick")
    @MainActor
    func quickRunCompletes() async {
        let optimizer = BuboOptimizer()
        optimizer.gaConfig = .quick
        optimizer.islandConfig = .quick
        let context = makeWorkload()
        let result = await optimizer.optimize(context: context)
        #expect(!result.scenarios.isEmpty)
        #expect(result.metadata.generations >= 0)
        #expect(result.scenarios[0].fitness > 0)
    }

    @Test("Top scenario fitness dominates siblings (sorted descending)")
    @MainActor
    func topScenarioDominatesSiblings() async {
        let optimizer = BuboOptimizer()
        optimizer.gaConfig = .quick
        optimizer.islandConfig = .quick
        optimizer.scenarioCount = 3
        let context = makeWorkload()
        let result = await optimizer.optimize(context: context)
        guard result.scenarios.count > 1 else { return }
        let top = result.scenarios[0].fitness
        for other in result.scenarios.dropFirst() {
            #expect(top >= other.fitness)
        }
    }

    @Test("Cancellation throws CancellationError mid-evolution; bestEver survives")
    func cooperativeCancellationDeterministic() async throws {
        // Stand up a GA with a slow synthetic evaluator so the
        // cancellation race is deterministic.
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let context = OptimizerContext(
            movableEvents: (0..<6).map { i in
                OptimizableEvent(
                    id: "t\(i)",
                    title: "t\(i)",
                    duration: 1800,
                    priority: 0.5
                )
            },
            workingHours: 9...18,
            planningHorizon: DateInterval(start: today, duration: 86400),
            rng: GARandom(seed: 1)
        )
        let config = GAConfiguration(
            populationSize: 30,
            maxGenerations: 1_000,    // huge so cancellation always fires first
            mutationRate: 0.1,
            crossoverRate: 0.8,
            eliteCount: 2,
            selectionStrategy: .tournament(size: 3),
            crossoverStrategy: .singlePoint,
            convergenceThreshold: 0.0001,
            convergencePatience: 1000,
            adaptiveMutation: false,
            diversityThreshold: 0.01,
            immigrationRate: 0.0
        )
        let ga = GeneticAlgorithm<ScheduleChromosome>(
            config: config,
            context: context,
            evaluate: { c in
                // Slow evaluator: ~1ms each, 30 individuals × 1000
                // generations = 30s if uninterrupted.
                Thread.sleep(forTimeInterval: 0.001)
                c.rawFitness = Double.random(in: 0..<1)
                c.fitness = c.rawFitness
            }
        )

        let task = Task.detached(priority: .userInitiated) { () throws -> [ScheduleChromosome] in
            try ga.run()
        }
        // Yield, give the GA a moment to run a few generations, then
        // cancel. ~50ms is plenty for 30-individual evaluations to
        // produce a `bestEver` before we stop.
        try await Task.sleep(nanoseconds: 50_000_000)
        task.cancel()

        do {
            _ = try await task.value
            Issue.record("Expected CancellationError to propagate")
        } catch is CancellationError {
            #expect(ga.bestEver != nil, "Cancellation must surface the in-flight best individual")
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test("acceptScenario nudges the run's attention head weights up")
    @MainActor
    func acceptanceNudgesHeadWeights() async {
        let optimizer = BuboOptimizer()
        optimizer.gaConfig = .quick
        optimizer.islandConfig = .quick
        let context = makeWorkload()

        let result = await optimizer.optimize(context: context)
        guard let scenario = result.scenarios.first else {
            Issue.record("Expected a scenario")
            return
        }

        let bundle = optimizer.learners(for: context)
        let weightsBefore = bundle.head.currentWeights

        optimizer.acceptScenario(scenario)

        let weightsAfter = bundle.head.currentWeights
        #expect(weightsBefore != weightsAfter, "acceptScenario must change head weights")
        // All four features were used with positive reward → all weights should
        // have moved up (or stayed at the upper clamp 3.0).
        for (old, new) in zip(weightsBefore, weightsAfter) {
            #expect(new >= old, "positive reward should not decrease any weight")
        }
    }

    @Test("rejectScenario nudges weights down; recordManualEdit also updates")
    @MainActor
    func rejectionAndEditUpdateLearners() async {
        let optimizer = BuboOptimizer()
        optimizer.gaConfig = .quick
        optimizer.islandConfig = .quick
        let context = makeWorkload()

        let result = await optimizer.optimize(context: context)
        guard let scenario = result.scenarios.first else {
            Issue.record("Expected a scenario")
            return
        }
        let bundle = optimizer.learners(for: context)
        let weightsBefore = bundle.head.currentWeights

        optimizer.rejectScenario(scenario)
        let weightsAfterReject = bundle.head.currentWeights
        #expect(weightsBefore != weightsAfterReject)
        for (old, new) in zip(weightsBefore, weightsAfterReject) {
            #expect(new <= old, "negative reward should not increase any weight")
        }

        // recordManualEdit also routes through the bundle; verify the
        // bandit pull count moves.
        let pullsBefore = bundle.bandit.snapshot.values.reduce(0) { $0 + $1.pulls }
        optimizer.recordManualEdit(original: scenario.genes, edited: scenario.genes)
        let pullsAfter = bundle.bandit.snapshot.values.reduce(0) { $0 + $1.pulls }
        #expect(pullsAfter > pullsBefore)
    }

    @Test("Identical workload reuses the same learner bundle by signature")
    @MainActor
    func signatureReusesBundleAcrossRuns() async {
        let optimizer = BuboOptimizer()
        optimizer.gaConfig = .quick
        optimizer.islandConfig = .quick
        let context = makeWorkload()

        _ = await optimizer.optimize(context: context)
        let firstBundle = optimizer.learners(for: context)
        let firstBanditPulls = firstBundle.bandit.snapshot.values.reduce(0) { $0 + $1.pulls }

        _ = await optimizer.optimize(context: context)
        let secondBundle = optimizer.learners(for: context)
        let secondBanditPulls = secondBundle.bandit.snapshot.values.reduce(0) { $0 + $1.pulls }

        #expect(firstBundle.bandit === secondBundle.bandit, "Same signature must yield same bandit")
        #expect(firstBundle.head === secondBundle.head, "Same signature must yield same head")
        #expect(firstBundle.surrogate === secondBundle.surrogate, "Same signature must yield same surrogate")
        #expect(secondBanditPulls > firstBanditPulls, "Second run must accumulate further pulls on the same bandit")
    }

    @Test("Different workloads get distinct learner bundles")
    @MainActor
    func differentWorkloadsGetDistinctBundles() async {
        let optimizer = BuboOptimizer()
        optimizer.gaConfig = .quick
        optimizer.islandConfig = .quick
        let smallWorkload = makeWorkload(eventCount: 4)
        let largeWorkload = makeWorkload(eventCount: 16)

        _ = await optimizer.optimize(context: smallWorkload)
        let smallBundle = optimizer.learners(for: smallWorkload)

        _ = await optimizer.optimize(context: largeWorkload)
        let largeBundle = optimizer.learners(for: largeWorkload)

        #expect(smallBundle.bandit !== largeBundle.bandit)
        #expect(smallBundle.head !== largeBundle.head)
        #expect(smallBundle.surrogate !== largeBundle.surrogate)
    }
}
