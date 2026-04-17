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
        // Continuation-synchronized cancellation: the evaluator
        // signals "first generation has begun" via a one-shot
        // continuation. The test waits on that signal *then* cancels.
        // This eliminates the timing race the sleep-based version
        // had — under heavy CI load, `Thread.sleep(50ms)` could
        // finish before `Task.detached` even started.
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
            maxGenerations: 100_000,       // huge so cancellation always fires first
            mutationRate: 0.1,
            crossoverRate: 0.8,
            eliteCount: 2,
            selectionStrategy: .tournament(size: 3),
            crossoverStrategy: .singlePoint,
            convergenceThreshold: 0.0,     // disable convergence shortcut
            convergencePatience: 100_000,
            adaptiveMutation: false,
            diversityThreshold: 0.01,
            immigrationRate: 0.0
        )

        // One-shot signal: the first evaluator call resumes the
        // continuation so the test knows evolution has begun.
        let firstEvalSignal = AsyncStream<Void>.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
        let signalSent = NSLock()
        nonisolated(unsafe) var alreadySignalled = false

        let ga = GeneticAlgorithm<ScheduleChromosome>(
            config: config,
            context: context,
            evaluate: { c in
                // Signal first call so the test cancels at a known
                // point (not before evolution has produced a
                // `bestEver`). All subsequent calls run normally.
                signalSent.lock()
                if !alreadySignalled {
                    alreadySignalled = true
                    firstEvalSignal.continuation.yield()
                }
                signalSent.unlock()
                c.rawFitness = Double.random(in: 0..<1)
                c.fitness = c.rawFitness
            }
        )

        let task = Task.detached(priority: .userInitiated) { () throws -> [ScheduleChromosome] in
            try ga.run()
        }

        // Wait for the GA to actually start producing evaluations
        // before we cancel.
        var iterator = firstEvalSignal.stream.makeAsyncIterator()
        _ = await iterator.next()

        // Give the GA a few more generations to populate `bestEver`
        // beyond the single first-evaluation snapshot.
        try await Task.sleep(nanoseconds: 30_000_000)
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
        // Fresh optimizer each call so head weights start at the
        // priors (well below the upper clamp). Otherwise repeated
        // accept calls could saturate the head and the assertion
        // `weightsBefore != weightsAfter` would mis-fire silently.
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
        // Sanity: priors are far enough below the upper clamp (3.0)
        // that a single positive update is observable.
        #expect(weightsBefore.allSatisfy { $0 < 2.5 })

        optimizer.acceptScenario(scenario)

        let weightsAfter = bundle.head.currentWeights
        // At least one weight must move up. If all four were already
        // at the clamp, nothing would change — `weightsBefore`
        // sanity check above rules that out.
        let anyIncreased = zip(weightsBefore, weightsAfter).contains { $1 > $0 }
        #expect(anyIncreased, "Positive reward must increase at least one head weight")
        for (old, new) in zip(weightsBefore, weightsAfter) {
            #expect(new >= old, "Positive reward should not decrease any weight")
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

        // recordManualEdit also routes through the bundle. Use the
        // scenario-typed overload that resolves the bundle via
        // `scenario.sourceSignature` — survives later optimizations
        // on different workloads, unlike the legacy lastRunSignature
        // path.
        let pullsBefore = bundle.bandit.snapshot.values.reduce(0) { $0 + $1.pulls }
        optimizer.recordManualEdit(scenario: scenario, edited: scenario.genes)
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

    @Test("Stale-scenario feedback routes to the original workload's bundle")
    @MainActor
    func feedbackRoutesByScenarioSignatureNotLastRun() async {
        let optimizer = BuboOptimizer()
        optimizer.gaConfig = .quick
        optimizer.islandConfig = .quick
        let workloadA = makeWorkload(eventCount: 5)
        let workloadB = makeWorkload(eventCount: 12)

        // Run A, capture its scenario, then run B (lastRunSignature
        // now points at B). Feedback on A's scenario must still find
        // A's bundle via `sourceSignature`.
        let resultA = await optimizer.optimize(context: workloadA)
        guard let scenarioA = resultA.scenarios.first else {
            Issue.record("Expected scenario from workload A")
            return
        }
        _ = await optimizer.optimize(context: workloadB)

        let bundleA = optimizer.learners(for: workloadA)
        let bundleB = optimizer.learners(for: workloadB)
        let banditAPullsBefore = bundleA.bandit.snapshot.values.reduce(0) { $0 + $1.pulls }
        let banditBPullsBefore = bundleB.bandit.snapshot.values.reduce(0) { $0 + $1.pulls }
        let headAWeightsBefore = bundleA.head.currentWeights
        let headBWeightsBefore = bundleB.head.currentWeights

        optimizer.acceptScenario(scenarioA)

        let banditAPullsAfter = bundleA.bandit.snapshot.values.reduce(0) { $0 + $1.pulls }
        let banditBPullsAfter = bundleB.bandit.snapshot.values.reduce(0) { $0 + $1.pulls }
        #expect(banditAPullsAfter > banditAPullsBefore, "A's bandit must absorb the feedback")
        #expect(banditBPullsAfter == banditBPullsBefore, "B's bandit must NOT see A's feedback")

        let headAWeightsAfter = bundleA.head.currentWeights
        let headBWeightsAfter = bundleB.head.currentWeights
        #expect(headAWeightsBefore != headAWeightsAfter, "A's head must absorb the feedback")
        #expect(headBWeightsBefore == headBWeightsAfter, "B's head must NOT see A's feedback")
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
