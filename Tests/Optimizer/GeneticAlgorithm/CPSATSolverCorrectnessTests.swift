import Foundation
import Testing
@testable import BuboOptimizer

// MARK: - CP-SAT solver correctness pins (2026-07-16 core audit)
//
// Direct `CPSATRepairer.solve` tests for two defects the seeder-level
// tests couldn't see:
//   • the forward check only looked at PREDECESSORS of the variable
//     being assigned — with VSIDS/domain-size ordering a dependent is
//     routinely assigned before its prerequisite, and the prerequisite
//     could then land after the dependent while the completed
//     assignment scored as feasible;
//   • no-good clauses matched prior assignments by PRESENCE, not by
//     value, so a dead-end learned under one partial assignment
//     pruned feasible branches in unrelated contexts.

@Suite("CP-SAT solver correctness")
struct CPSATSolverCorrectnessTests {

    private func hour(_ h: Int, day: Int = 0) -> Date {
        let cal = Calendar.current
        let base = cal.startOfDay(for: Date(timeIntervalSinceReferenceDate: 800_000_000))
        let dayStart = cal.date(byAdding: .day, value: day, to: base)!
        return cal.date(bySettingHour: h, minute: 0, second: 0, of: dayStart)!
    }

    @Test("precedence holds when the dependent is assigned first")
    func precedenceBothDirections() throws {
        // B has the smaller domain, so the fail-first ordering assigns
        // it before its prerequisite A. The scorer prefers LATER
        // starts, which is exactly the pull that used to drag A past B.
        let a = CPVariable(geneIndex: 0, domain: [hour(9), hour(11)], duration: 3600)
        let b = CPVariable(geneIndex: 1, domain: [hour(10)], duration: 3600)

        let result = CPSATRepairer().solve(
            variables: [a, b],
            precedence: [(0, 1)],   // A must end before B starts
            fixedBlocks: [],
            scoreAssignment: { assignment in
                assignment.values.reduce(0) { $0 + $1.timeIntervalSinceReferenceDate }
            }
        )

        let aStart = try #require(result.assignments[0])
        let bStart = try #require(result.assignments[1])
        #expect(aStart.addingTimeInterval(3600) <= bStart)
    }

    @Test("value-scoped no-goods do not block feasible branches")
    func noGoodsAreValueScoped() {
        // Three variables over a tight day. The search necessarily
        // dead-ends on some prefixes; with presence-only no-good
        // matching those clauses fired for EVERY value of the pending
        // variable and the solver declared this trivially feasible
        // instance dead.
        let vars = [
            CPVariable(geneIndex: 0, domain: [hour(9), hour(10), hour(11)], duration: 3600),
            CPVariable(geneIndex: 1, domain: [hour(9), hour(10), hour(11)], duration: 3600),
            CPVariable(geneIndex: 2, domain: [hour(9), hour(10), hour(11)], duration: 3600),
        ]
        let result = CPSATRepairer().solve(
            variables: vars,
            precedence: [],
            fixedBlocks: [],
            scoreAssignment: { _ in 1.0 }
        )
        #expect(result.assignments.count == 3)
        // All three got distinct, non-overlapping hours.
        let starts = Set(result.assignments.values)
        #expect(starts.count == 3)
    }
}
