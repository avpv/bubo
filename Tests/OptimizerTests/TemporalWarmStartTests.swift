import Foundation
import Testing
@testable import Bubo

// MARK: - Temporal Warm-Start Tests (Wave 1 / item 11)

@Suite("Temporal warm-start seeding")
struct TemporalWarmStartTests {

    @Test("seed returns nil when no prior saved")
    func emptyStoreReturnsNil() {
        let store = TemporalWarmStart()
        let ctx = OptimizerTestFixtures.makeContext(movableEvents: [
            OptimizerTestFixtures.makeEvent(id: "A")
        ])
        #expect(store.seed(context: ctx) == nil)
    }

    @Test("seed reuses prior gene placement for same event id")
    func exactIdMatch() {
        let store = TemporalWarmStart()
        let events = [
            OptimizerTestFixtures.makeEvent(id: "A", durationMinutes: 60),
            OptimizerTestFixtures.makeEvent(id: "B", durationMinutes: 30),
        ]
        let ctx = OptimizerTestFixtures.makeContext(movableEvents: events)
        let cal = ctx.calendar
        let day = cal.startOfDay(for: ctx.planningHorizon.start)
        let start10 = cal.date(bySettingHour: 10, minute: 0, second: 0, of: day)!
        let start14 = cal.date(bySettingHour: 14, minute: 0, second: 0, of: day)!
        let priorGenes = [
            ScheduleGene(eventId: "A", title: "A", startTime: start10,
                         duration: 3600, context: nil, energyCost: 0.5,
                         priority: 0.5, isFocusBlock: false),
            ScheduleGene(eventId: "B", title: "B", startTime: start14,
                         duration: 1800, context: nil, energyCost: 0.5,
                         priority: 0.5, isFocusBlock: false),
        ]
        store.record(genes: priorGenes, context: ctx)

        guard let seed = store.seed(context: ctx) else {
            Issue.record("expected a warm-start seed")
            return
        }
        let byId = Dictionary(uniqueKeysWithValues: seed.genes.map { ($0.eventId, $0) })
        #expect(byId["A"]?.startTime == start10)
        #expect(byId["B"]?.startTime == start14)
    }

    @Test("seed shifts placement by day delta on subsequent horizon")
    func shiftByDay() {
        let store = TemporalWarmStart()
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let tomorrow = cal.date(byAdding: .day, value: 1, to: today)!
        let dayAfter = cal.date(byAdding: .day, value: 2, to: today)!

        let yesterdayStart = cal.date(byAdding: .day, value: -1, to: today)!
        let priorCtx = OptimizerContext(
            fixedEvents: [],
            movableEvents: [OptimizerTestFixtures.makeEvent(id: "A")],
            workingHours: 9...18,
            planningHorizon: DateInterval(start: yesterdayStart, end: today),
            preferences: OptimizerPreferences(),
            rng: GARandom(seed: 1)
        )
        let priorStart = cal.date(bySettingHour: 10, minute: 0, second: 0, of: yesterdayStart)!
        let priorGene = ScheduleGene(eventId: "A", title: "A", startTime: priorStart,
                                     duration: 3600, context: nil, energyCost: 0.5,
                                     priority: 0.5, isFocusBlock: false)
        store.record(genes: [priorGene], context: priorCtx)

        let nextCtx = OptimizerContext(
            fixedEvents: [],
            movableEvents: [OptimizerTestFixtures.makeEvent(id: "A")],
            workingHours: 9...18,
            planningHorizon: DateInterval(start: today, end: tomorrow),
            preferences: OptimizerPreferences(),
            rng: GARandom(seed: 1)
        )
        _ = dayAfter

        guard let seed = store.seed(context: nextCtx) else {
            Issue.record("expected a seed")
            return
        }
        let gene = seed.genes.first { $0.eventId == "A" }
        let expected = cal.date(bySettingHour: 10, minute: 0, second: 0, of: today)!
        #expect(gene?.startTime == expected)
    }

    @Test("capacity evicts oldest workload")
    func capacityEviction() {
        let store = TemporalWarmStart(capacity: 2)
        let mkCtx: (String) -> OptimizerContext = { id in
            OptimizerTestFixtures.makeContext(movableEvents: [
                OptimizerTestFixtures.makeEvent(id: id)
            ])
        }
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let placeholder = ScheduleGene(eventId: "X", title: "X",
            startTime: today, duration: 3600, context: nil,
            energyCost: 0.5, priority: 0.5, isFocusBlock: false)
        let ctx1 = mkCtx("A")
        store.record(genes: [placeholder], context: ctx1)
        let ctx2 = mkCtx("B")
        store.record(genes: [placeholder], context: ctx2)
        let ctx3 = mkCtx("C")
        store.record(genes: [placeholder], context: ctx3)
        // ctx1 should be evicted.
        #expect(!store.hasEntry(for: TaskSignature(context: ctx1)))
        #expect(store.hasEntry(for: TaskSignature(context: ctx2)))
        #expect(store.hasEntry(for: TaskSignature(context: ctx3)))
    }
}
