import Foundation
import Testing
@testable import Bubo
@testable import BuboDomain
@testable import BuboOptimizer

// MARK: - AnchorSeeder Tests
//
// Covers the single-site anchor decision layer used by both
// `BuboOptimizer.optimize()` and `IncrementalReoptimizer.reoptimize()`.
// The seeder's contract:
//   • never returns nil (greedy is a feasibility-by-construction
//     fallback on our domain);
//   • tags every outcome with an attributable `AnchorSource`
//     (cpsat / cpsat+warm / greedy with a specific reason);
//   • passes warm-start hints through to CP-SAT on reopt;
//   • respects the `useCPSATSeed` flag and window threshold
//     identically across paths.

@Suite("AnchorSeeder decision table")
struct AnchorSeederTests {

    // MARK: - Helpers

    private func horizonDay() -> (today: Date, tomorrow: Date) {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let tomorrow = cal.date(byAdding: .day, value: 1, to: today)!
        return (today, tomorrow)
    }

    private func event(
        id: String,
        durationMinutes: Int = 60,
        priority: Double = 0.5
    ) -> OptimizableEvent {
        OptimizableEvent(
            id: id,
            title: id,
            duration: TimeInterval(durationMinutes * 60),
            priority: priority
        )
    }

    private func makeContext(
        events: [OptimizableEvent],
        withRepairer: Bool = true
    ) -> OptimizerContext {
        let (today, tomorrow) = horizonDay()
        return OptimizerContext(
            fixedEvents: [],
            movableEvents: events,
            workingHours: 9...18,
            planningHorizon: DateInterval(start: today, end: tomorrow),
            preferences: OptimizerPreferences(workingDays: [1, 2, 3, 4, 5, 6, 7]),
            cpSATRepairer: withRepairer ? CPSATRepairer() : nil
        )
    }

    // MARK: - Flag gating

    @Test("disabled flag → greedy(disabled), no solver invocation")
    func disabledFlagYieldsGreedy() {
        let ctx = makeContext(events: [event(id: "a"), event(id: "b")])
        let seeder = AnchorSeeder(gates: AnchorSeeder.Gates(
            cpsatEnabled: false,
            windowThreshold: 20
        ))
        let (_, source) = seeder.makeAnchor(context: ctx, mode: .firstRun)
        #expect(source == .greedy(reason: .disabled))
        #expect(source.cpsatDurationMs == 0)
        #expect(source.logLabel == "greedy(disabled)")
    }

    @Test("missing repairer → greedy(disabled)")
    func missingRepairerYieldsGreedy() {
        let ctx = makeContext(
            events: [event(id: "a"), event(id: "b")],
            withRepairer: false
        )
        let seeder = AnchorSeeder(gates: .enabled)
        let (_, source) = seeder.makeAnchor(context: ctx, mode: .firstRun)
        #expect(source == .greedy(reason: .disabled))
    }

    // MARK: - Window threshold

    @Test("workload past window threshold → greedy(windowExceeded)")
    func pastWindowYieldsWindowExceeded() {
        // Threshold 2, workload 3 → window exceeded. The solver is
        // not invoked; `cpsatDurationMs` stays at 0.
        let ctx = makeContext(events: [
            event(id: "a"), event(id: "b"), event(id: "c"),
        ])
        let seeder = AnchorSeeder(gates: AnchorSeeder.Gates(
            cpsatEnabled: true,
            windowThreshold: 2
        ))
        let (_, source) = seeder.makeAnchor(context: ctx, mode: .firstRun)
        #expect(source == .greedy(reason: .windowExceeded))
        #expect(source.cpsatDurationMs == 0)
    }

    // MARK: - CP-SAT success paths

    @Test("firstRun under window → cpsat, not warm-started")
    func firstRunProducesColdCPSAT() {
        let ctx = makeContext(events: [
            event(id: "a"), event(id: "b"), event(id: "c"),
        ])
        let seeder = AnchorSeeder(gates: .enabled)
        let (anchor, source) = seeder.makeAnchor(context: ctx, mode: .firstRun)
        #expect(anchor.genes.count == 3)
        #expect(anchor.genes.allSatisfy { $0.isIncluded })
        guard case let .cpsat(_, warmStarted) = source else {
            Issue.record("expected .cpsat, got \(source.logLabel)")
            return
        }
        #expect(warmStarted == false)
        #expect(source.logLabel == "cpsat")
    }

    @Test("reopt with valid current schedule → cpsat+warm")
    func reoptProducesWarmStartedCPSAT() {
        let ctx = makeContext(events: [
            event(id: "a"), event(id: "b"), event(id: "c"),
        ])
        // First produce a cold-start seed so we have realistic
        // gene start times lying exactly on the slot grid.
        guard let cold = ScheduleChromosome.cpSeeded(context: ctx) else {
            Issue.record("cold seed failed — fixture broken")
            return
        }

        let seeder = AnchorSeeder(gates: .enabled)
        let (anchor, source) = seeder.makeAnchor(
            context: ctx,
            mode: .reopt(currentSchedule: cold.genes)
        )
        #expect(anchor.genes.count == 3)
        guard case let .cpsat(_, warmStarted) = source else {
            Issue.record("expected .cpsat, got \(source.logLabel)")
            return
        }
        #expect(warmStarted == true)
        #expect(source.logLabel == "cpsat+warm")
    }

    @Test("reopt with empty current schedule → cpsat (not warm)")
    func reoptEmptyCurrentIsNotWarm() {
        // An empty `currentSchedule` carries no useful hint, so the
        // seeder reports a cold CP-SAT even in reopt mode.
        let ctx = makeContext(events: [event(id: "a"), event(id: "b")])
        let seeder = AnchorSeeder(gates: .enabled)
        let (_, source) = seeder.makeAnchor(
            context: ctx,
            mode: .reopt(currentSchedule: [])
        )
        if case let .cpsat(_, warmStarted) = source {
            #expect(warmStarted == false)
        } else {
            Issue.record("expected .cpsat, got \(source.logLabel)")
        }
    }

    // MARK: - AnchorSource helpers

    @Test("logLabel is stable and aggregation-friendly")
    func logLabelsCoverAllBranches() {
        #expect(AnchorSource.cpsat(durationMs: 0, warmStarted: false).logLabel == "cpsat")
        #expect(AnchorSource.cpsat(durationMs: 0, warmStarted: true).logLabel == "cpsat+warm")
        #expect(AnchorSource.greedy(reason: .disabled).logLabel == "greedy(disabled)")
        #expect(AnchorSource.greedy(reason: .windowExceeded).logLabel == "greedy(windowExceeded)")
        #expect(AnchorSource.greedy(reason: .timeout).logLabel == "greedy(timeout)")
        #expect(AnchorSource.greedy(reason: .infeasible).logLabel == "greedy(infeasible)")
        #expect(AnchorSource.greedy(reason: .reoptFallback).logLabel == "greedy(reoptFallback)")
    }

    @Test("isCPSAT flag distinguishes CP-SAT from greedy")
    func isCPSATDistinguishes() {
        #expect(AnchorSource.cpsat(durationMs: 10, warmStarted: false).isCPSAT)
        #expect(AnchorSource.cpsat(durationMs: 0, warmStarted: true).isCPSAT)
        #expect(!AnchorSource.greedy(reason: .disabled).isCPSAT)
        #expect(!AnchorSource.greedy(reason: .timeout).isCPSAT)
    }
}

// MARK: - Warm-start effect on solver

@Suite("CP-SAT warm-start hint")
struct CPSATWarmStartTests {

    @Test("feasible hint survives as the solver's result")
    func feasibleHintAccepted() {
        let t0 = Date(timeIntervalSinceReferenceDate: 0)
        let domain = (0..<10).map { t0.addingTimeInterval(Double($0) * 3600) }
        // Two variables, non-overlapping assignment in the hint.
        let v0 = CPVariable(geneIndex: 0, domain: domain, duration: 3600)
        let v1 = CPVariable(geneIndex: 1, domain: domain, duration: 3600)
        let hint: [Int: Date] = [
            0: domain[0],
            1: domain[2],
        ]
        let repairer = CPSATRepairer()
        let result = repairer.solve(
            variables: [v0, v1],
            precedence: [],
            fixedBlocks: [],
            // Constant scorer — any feasible assignment is equally
            // good, so the solver should return whatever comes first
            // (which is the hint when domain ordering + warm-start
            // prefer it).
            scoreAssignment: { _ in 0 },
            hint: hint
        )
        #expect(result.assignments.count == 2)
        #expect(result.assignments[0] == domain[0])
        // v1 may land at domain[1] (earlier, still non-overlapping
        // with v0) or domain[2] (the hint). Either is feasible;
        // the hint is only a starting incumbent, not a constraint.
        #expect(result.assignments[1] == domain[1] || result.assignments[1] == domain[2])
    }

    @Test("infeasible hint is ignored, solver still finds a valid assignment")
    func infeasibleHintIgnored() {
        let t0 = Date(timeIntervalSinceReferenceDate: 0)
        let domain = (0..<4).map { t0.addingTimeInterval(Double($0) * 3600) }
        let v0 = CPVariable(geneIndex: 0, domain: domain, duration: 3600)
        let v1 = CPVariable(geneIndex: 1, domain: domain, duration: 3600)
        // Overlapping hint (both at the same slot) — not feasible.
        let hint: [Int: Date] = [0: domain[0], 1: domain[0]]
        let repairer = CPSATRepairer()
        let result = repairer.solve(
            variables: [v0, v1],
            precedence: [],
            fixedBlocks: [],
            scoreAssignment: { _ in 0 },
            hint: hint
        )
        #expect(result.assignments.count == 2)
        // Must be a valid non-overlap assignment despite the bad hint.
        let starts = [result.assignments[0]!, result.assignments[1]!].sorted()
        #expect(starts[0].addingTimeInterval(3600) <= starts[1])
    }

    @Test("partial hint (fewer keys than variables) is ignored")
    func partialHintIgnored() {
        let t0 = Date(timeIntervalSinceReferenceDate: 0)
        let domain = (0..<4).map { t0.addingTimeInterval(Double($0) * 3600) }
        let v0 = CPVariable(geneIndex: 0, domain: domain, duration: 3600)
        let v1 = CPVariable(geneIndex: 1, domain: domain, duration: 3600)
        let hint: [Int: Date] = [0: domain[2]]  // v1 missing
        let repairer = CPSATRepairer()
        let result = repairer.solve(
            variables: [v0, v1],
            precedence: [],
            fixedBlocks: [],
            scoreAssignment: { _ in 0 },
            hint: hint
        )
        // Solver should still produce a two-variable assignment,
        // without crashing on the incomplete hint.
        #expect(result.assignments.count == 2)
    }

    @Test("hint carries through solveLexHierarchy")
    func hintThroughLexHierarchy() {
        let t0 = Date(timeIntervalSinceReferenceDate: 0)
        let domain = (0..<10).map { t0.addingTimeInterval(Double($0) * 3600) }
        let v0 = CPVariable(geneIndex: 0, domain: domain, duration: 3600)
        let v1 = CPVariable(geneIndex: 1, domain: domain, duration: 3600)
        let tier = CPSATRepairer.LexTier(
            name: "inclusion",
            extract: { assignment in Double(assignment.count) }
        )
        let hint: [Int: Date] = [0: domain[0], 1: domain[2]]
        let repairer = CPSATRepairer()
        let result = repairer.solveLexHierarchy(
            variables: [v0, v1],
            precedence: [],
            fixedBlocks: [],
            tiers: [tier],
            hint: hint
        )
        #expect(result.assignments.count == 2)
    }
}
