import Foundation
import Testing
@testable import Bubo

// Covers CPSATRepairer (used today as construction-seeder backend).
// LearnedBranchingBandit and MigrationTopologyBandit were retired.

@Suite("CP-SAT repair")
struct CPSATRepairTests {
    @Test("empty problem returns empty assignment")
    func emptyProblem() {
        let repairer = CPSATRepairer()
        let result = repairer.solve(
            variables: [],
            precedence: [],
            fixedBlocks: [],
            scoreAssignment: { _ in 0 }
        )
        #expect(result.assignments.isEmpty)
        #expect(result.nodesExplored == 0)
    }

    @Test("two-variable problem without conflicts picks best")
    func twoVariables() {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let slot1 = cal.date(bySettingHour: 10, minute: 0, second: 0, of: today)!
        let slot2 = cal.date(bySettingHour: 14, minute: 0, second: 0, of: today)!
        let v1 = CPVariable(geneIndex: 0, domain: [slot1, slot2], duration: 3600)
        let v2 = CPVariable(geneIndex: 1, domain: [slot1, slot2], duration: 3600)

        let repairer = CPSATRepairer()
        let result = repairer.solve(
            variables: [v1, v2],
            precedence: [],
            fixedBlocks: [],
            // Score: prefer variable 0 at slot1.
            scoreAssignment: { assignment in
                var s = 0.0
                if assignment[0] == slot1 { s += 1 }
                if assignment[1] == slot2 { s += 1 }
                return s
            }
        )
        #expect(result.assignments[0] == slot1)
        #expect(result.assignments[1] == slot2)
    }

    @Test("precedence forces ordered placement")
    func precedenceEnforced() {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let slot1 = cal.date(bySettingHour: 10, minute: 0, second: 0, of: today)!
        let slot2 = cal.date(bySettingHour: 14, minute: 0, second: 0, of: today)!
        let v1 = CPVariable(geneIndex: 0, domain: [slot1, slot2], duration: 3600)
        let v2 = CPVariable(geneIndex: 1, domain: [slot1, slot2], duration: 3600)

        let repairer = CPSATRepairer()
        let result = repairer.solve(
            variables: [v1, v2],
            precedence: [(0, 1)],
            fixedBlocks: [],
            scoreAssignment: { _ in 1 }
        )
        if let s1 = result.assignments[0], let s2 = result.assignments[1] {
            #expect(s1.addingTimeInterval(3600) <= s2)
        }
    }
}

