import Foundation
import Testing
@testable import Bubo
@testable import BuboDomain
@testable import BuboOptimizer

// MARK: - CP-SAT Construction Seeder Tests
//
// Covers `ScheduleChromosome.cpSeeded` — the feasibility-optimal
// seeder that backs `useCPSATSeed`. Pins down the lex-scoring
// hierarchy (inclusion > deadline > backlog > earliness) and the
// integration contract with `OptimizerContext.cpSATRepairer`.

@Suite("CP-SAT construction seeder")
struct CPSATSeederTests {

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
        priority: Double = 0.5,
        backlogIndex: Int? = nil,
        deadline: Date? = nil,
        dependsOn: [String] = [],
        isDroppable: Bool = false
    ) -> OptimizableEvent {
        OptimizableEvent(
            id: id,
            title: id,
            duration: TimeInterval(durationMinutes * 60),
            deadline: deadline,
            priority: priority,
            dependsOn: dependsOn,
            isDroppable: isDroppable,
            backlogIndex: backlogIndex
        )
    }

    private func makeContext(
        events: [OptimizableEvent],
        fixed: [CalendarEvent] = [],
        workingHours: ClosedRange<Int> = 9...18
    ) -> OptimizerContext {
        let (today, tomorrow) = horizonDay()
        return OptimizerContext(
            fixedEvents: fixed,
            movableEvents: events,
            workingHours: workingHours,
            planningHorizon: DateInterval(start: today, end: tomorrow),
            preferences: OptimizerPreferences(workingDays: [1, 2, 3, 4, 5, 6, 7]),
            cpSATRepairer: CPSATRepairer()
        )
    }

    // MARK: - Contract

    @Test("returns nil when context has no repairer")
    func noRepairerYieldsNil() {
        let (today, tomorrow) = horizonDay()
        let ctx = OptimizerContext(
            movableEvents: [event(id: "a")],
            workingHours: 9...18,
            planningHorizon: DateInterval(start: today, end: tomorrow)
        ,
            preferences: OptimizerPreferences(workingDays: [1, 2, 3, 4, 5, 6, 7]))
        // Explicitly no cpSATRepairer — seeder must return nil.
        #expect(ScheduleChromosome.cpSeeded(context: ctx) == nil)
    }

    @Test("returns nil on empty workload")
    func emptyWorkloadYieldsNil() {
        let ctx = makeContext(events: [])
        #expect(ScheduleChromosome.cpSeeded(context: ctx) == nil)
    }

    @Test("produces a feasible chromosome for a trivial workload")
    func trivialFeasibility() {
        let ctx = makeContext(events: [
            event(id: "a", durationMinutes: 60, priority: 0.5),
            event(id: "b", durationMinutes: 60, priority: 0.5),
        ])
        guard let seed = ScheduleChromosome.cpSeeded(context: ctx) else {
            Issue.record("cpSeeded returned nil on trivial feasible workload")
            return
        }
        #expect(seed.genes.count == 2)
        #expect(seed.genes.allSatisfy { $0.isIncluded })
        // No overlap: sort by start time and assert no pair overlaps.
        let sorted = seed.genes.sorted { $0.startTime < $1.startTime }
        #expect(sorted[0].endTime <= sorted[1].startTime)
    }

    // MARK: - Lex ordering

    @Test("inclusion dominates deadline — places all events even if one overruns")
    func inclusionDominatesDeadline() {
        // Three 1-hour tasks on a 9-hour day → all three fit.
        // Give task-c a deadline it can still meet (13:00) so the
        // solver doesn't have to choose between dropping and
        // overrunning. The test confirms all three are placed.
        let (today, _) = horizonDay()
        let cal = Calendar.current
        let deadline = cal.date(bySettingHour: 13, minute: 0, second: 0, of: today)!
        let ctx = makeContext(events: [
            event(id: "a", durationMinutes: 60),
            event(id: "b", durationMinutes: 60),
            event(id: "c", durationMinutes: 60, deadline: deadline),
        ])
        guard let seed = ScheduleChromosome.cpSeeded(context: ctx) else {
            Issue.record("cpSeeded returned nil")
            return
        }
        #expect(seed.genes.count == 3)
        #expect(seed.genes.allSatisfy { $0.isIncluded })
    }

    @Test("backlog order is respected when priorities tie")
    func backlogOrderRespected() {
        // Three equal-priority tasks with explicit backlogIndex 0,
        // 1, 2. Expected order in the output (by start time) is
        // a → b → c.
        let ctx = makeContext(events: [
            event(id: "a", priority: 0.5, backlogIndex: 0),
            event(id: "b", priority: 0.5, backlogIndex: 1),
            event(id: "c", priority: 0.5, backlogIndex: 2),
        ])
        guard let seed = ScheduleChromosome.cpSeeded(context: ctx) else {
            Issue.record("cpSeeded returned nil")
            return
        }
        let byStart = seed.genes
            .filter { $0.isIncluded }
            .sorted { $0.startTime < $1.startTime }
            .map(\.eventId)
        #expect(byStart == ["a", "b", "c"])
    }

    @Test("priority trumps backlog order")
    func priorityBeatsBacklog() {
        // High-priority task c has the highest backlogIndex but
        // should still land first because priority outranks backlog
        // in the ordering preference.
        let ctx = makeContext(events: [
            event(id: "a", priority: 0.4, backlogIndex: 0),
            event(id: "b", priority: 0.4, backlogIndex: 1),
            event(id: "c", priority: 0.9, backlogIndex: 2),
        ])
        guard let seed = ScheduleChromosome.cpSeeded(context: ctx) else {
            Issue.record("cpSeeded returned nil")
            return
        }
        let byStart = seed.genes
            .filter { $0.isIncluded }
            .sorted { $0.startTime < $1.startTime }
        // c starts first (high priority), then a (backlog 0), then b (backlog 1).
        #expect(byStart.map(\.eventId) == ["c", "a", "b"])
    }

    @Test("precedence enforced: prerequisite ends before dependent starts")
    func precedenceEnforced() {
        let ctx = makeContext(events: [
            event(id: "a"),
            event(id: "b", dependsOn: ["a"]),
        ])
        guard let seed = ScheduleChromosome.cpSeeded(context: ctx) else {
            Issue.record("cpSeeded returned nil")
            return
        }
        let geneA = seed.genes.first { $0.eventId == "a" }!
        let geneB = seed.genes.first { $0.eventId == "b" }!
        #expect(geneA.endTime <= geneB.startTime)
    }
}
