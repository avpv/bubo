import Foundation
import Testing
@testable import Bubo

// MARK: - Helpers

/// Build a context whose bandit is pre-biased so `select()` returns `target`
/// deterministically. LinUCB picks the arm with the highest `mean + α·bonus`;
/// after ~60 clipped rewards of +0.5 on `target` and -0.5 on every other arm,
/// the mean gap (≈1.0) dominates any variance bonus, so selection stays
/// stable for the rest of the test.
private func contextForcingOperator(
    _ target: MutationOperator,
    movableEvents: [OptimizableEvent] = [],
    fixedEvents: [CalendarEvent] = [],
    workingHours: ClosedRange<Int> = 9...18,
    horizonDays: Int = 3,
    seed: UInt64 = 7777
) -> OptimizerContext {
    let cal = Calendar.current
    let today = cal.startOfDay(for: Date())
    let end = cal.date(byAdding: .day, value: horizonDays, to: today)!
    let bandit = MutationBandit()
    bandit.updateContext(.neutral)
    for _ in 0..<60 {
        for op in MutationOperator.allCases {
            bandit.record(op: op, reward: op == target ? 0.5 : -0.5)
        }
    }
    return OptimizerContext(
        fixedEvents: fixedEvents,
        movableEvents: movableEvents,
        workingHours: workingHours,
        planningHorizon: DateInterval(start: today, end: end),
        rng: GARandom(seed: seed),
        mutationBandit: bandit
    )
}

private func makeEvent(
    id: String,
    durationMinutes: Int = 60,
    priority: Double = 0.5,
    dependsOn: [String] = [],
    isDroppable: Bool = false
) -> OptimizableEvent {
    OptimizableEvent(
        id: id,
        title: id,
        duration: TimeInterval(durationMinutes * 60),
        priority: priority,
        dependsOn: dependsOn,
        isDroppable: isDroppable
    )
}

/// True iff two intervals overlap strictly (touching endpoints are OK).
private func overlaps(_ a: ScheduleGene, _ b: ScheduleGene) -> Bool {
    a.startTime < b.endTime && b.startTime < a.endTime
}

@Suite("LNS Mutation Operator")
struct LNSOperatorTests {

    @Test("Bandit can be biased so mutate() picks the LNS operator")
    func banditSelectsLNSWhenBiased() {
        let events = (0..<4).map { makeEvent(id: "e\($0)") }
        let context = contextForcingOperator(.lnsDay, movableEvents: events)

        var chrom = ScheduleChromosome.greedy(context: context)
        chrom.mutate(rate: 0.3, context: context)

        #expect(chrom.lastMutationOperator == .lnsDay)
    }

    @Test("LNS preserves feasibility starting from a greedy chromosome")
    func lnsPreservesFeasibility() {
        // Greedy seed is overlap-free. LNS destroys a subset and re-inserts
        // with `findFirstFreeSlot`, which avoids every occupied interval,
        // so the result must remain overlap-free.
        let events = (0..<5).map { makeEvent(id: "e\($0)", durationMinutes: 60) }
        let context = contextForcingOperator(.lnsDay, movableEvents: events)

        var chrom = ScheduleChromosome.greedy(context: context)
        chrom.mutate(rate: 0.4, context: context)

        let placed = chrom.genes.filter { $0.isIncluded }
        for i in 0..<placed.count {
            for j in (i + 1)..<placed.count {
                #expect(!overlaps(placed[i], placed[j]),
                        "genes \(placed[i].eventId) and \(placed[j].eventId) overlap after LNS")
            }
        }
    }

    @Test("LNS-placed genes do not overlap fixed events")
    func lnsRespectsFixedEvents() {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let fixStart = cal.date(bySettingHour: 10, minute: 0, second: 0, of: today)!
        let fixEnd = fixStart.addingTimeInterval(3600)
        let fixed = CalendarEvent(
            id: "meeting",
            title: "Standup",
            startDate: fixStart,
            endDate: fixEnd,
            location: nil,
            description: nil,
            calendarName: "Work",
            eventType: .standard
        )
        let events = (0..<3).map { makeEvent(id: "e\($0)", durationMinutes: 60) }
        let context = contextForcingOperator(
            .lnsDay,
            movableEvents: events,
            fixedEvents: [fixed]
        )

        var chrom = ScheduleChromosome.greedy(context: context)
        chrom.mutate(rate: 0.5, context: context)

        for g in chrom.genes where g.isIncluded {
            let overlapsFixed = g.startTime < fixEnd && g.endTime > fixStart
            #expect(!overlapsFixed, "gene \(g.eventId) overlaps the fixed meeting")
        }
    }

    @Test("LNS sets lastMutationOperator and needsEvaluation")
    func lnsUpdatesBookkeeping() {
        let events = (0..<4).map { makeEvent(id: "e\($0)") }
        let context = contextForcingOperator(.lnsDay, movableEvents: events, seed: 123)

        var chrom = ScheduleChromosome.greedy(context: context)
        // Flip needsEvaluation false so we can confirm mutate sets it.
        chrom.needsEvaluation = false
        chrom.mutate(rate: 0.4, context: context)

        #expect(chrom.lastMutationOperator == .lnsDay)
        #expect(chrom.needsEvaluation)
    }

    @Test("LNS is a no-op on empty chromosomes")
    func lnsHandlesEmptyChromosome() {
        let context = contextForcingOperator(.lnsDay, movableEvents: [])
        var chrom = ScheduleChromosome.random(context: context)
        chrom.mutate(rate: 0.5, context: context)
        #expect(chrom.genes.isEmpty)
        #expect(chrom.lastMutationOperator == .lnsDay)
        #expect(chrom.mutatedGeneIndices == nil)
    }

    @Test("LNS drops a droppable gene when no feasible slot exists")
    func lnsDropsWhenInfeasible() {
        // Fill every working hour of a 2-day horizon with fixed events.
        // The droppable task has nowhere to land, so LNS must set
        // isIncluded = false rather than leave it overlapping.
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let horizonDays = 2
        var fixedEvents: [CalendarEvent] = []
        for d in 0..<horizonDays {
            let day = cal.date(byAdding: .day, value: d, to: today)!
            let start = cal.date(bySettingHour: 9, minute: 0, second: 0, of: day)!
            let end = cal.date(bySettingHour: 18, minute: 0, second: 0, of: day)!
            fixedEvents.append(CalendarEvent(
                id: "block\(d)",
                title: "Blocker",
                startDate: start,
                endDate: end,
                location: nil,
                description: nil,
                calendarName: "Test",
                eventType: .standard
            ))
        }
        let droppable = makeEvent(id: "drop", durationMinutes: 60, isDroppable: true)
        let context = contextForcingOperator(
            .lnsDay,
            movableEvents: [droppable],
            fixedEvents: fixedEvents,
            horizonDays: horizonDays
        )

        // Force the gene to be included initially so LNS sees a live gene
        // to (eventually) drop.
        var chrom = ScheduleChromosome.random(context: context)
        if let idx = chrom.genes.firstIndex(where: { $0.eventId == "drop" }) {
            chrom.genes[idx].isIncluded = true
        }
        chrom.mutate(rate: 0.5, context: context)

        let gene = chrom.genes.first { $0.eventId == "drop" }
        #expect(gene?.isIncluded == false)
    }

    @Test("LNS preserves dependsOn ordering when both genes are destroyed")
    func lnsPreservesDependsOn() {
        let e0 = makeEvent(id: "e0", priority: 0.5)
        let e1 = makeEvent(id: "e1", priority: 0.5, dependsOn: ["e0"])

        // Iterate over seeds so every destroy strategy gets a turn.
        // Each strategy destroys ≥1 gene; reverse-dependency handling
        // (for the destroyed/non-destroyed case) and in-degree topology
        // (for the both-destroyed case) must both keep e1 after e0.
        for seed in UInt64(1)...UInt64(10) {
            let context = contextForcingOperator(
                .lnsDay,
                movableEvents: [e0, e1],
                horizonDays: 2,
                seed: seed
            )
            var chrom = ScheduleChromosome.greedy(context: context)
            chrom.mutate(rate: 1.0, context: context)

            let byId = Dictionary(uniqueKeysWithValues: chrom.genes.map { ($0.eventId, $0) })
            guard let g0 = byId["e0"], let g1 = byId["e1"],
                  g0.isIncluded, g1.isIncluded else { continue }
            #expect(g1.startTime >= g0.endTime,
                    "seed \(seed): e1 (\(g1.startTime)) must not start before e0 ends (\(g0.endTime))")
        }
    }

    @Test("LNS respects reverse dependencies — destroyed predecessor ends before non-destroyed dependent")
    func lnsRespectsReverseDependencies() {
        // Three genes in a chain: e0 ← e1 ← e2. With destroySize=2 each
        // strategy rips out the top two by various orderings; whenever
        // the chain is partially destroyed, the reverseDeadline logic
        // must kick in to keep e0.end ≤ e1.start and e1.end ≤ e2.start.
        let e0 = makeEvent(id: "e0", priority: 0.5)
        let e1 = makeEvent(id: "e1", priority: 0.5, dependsOn: ["e0"])
        let e2 = makeEvent(id: "e2", priority: 0.5, dependsOn: ["e1"])

        for seed in UInt64(11)...UInt64(20) {
            let context = contextForcingOperator(
                .lnsDay,
                movableEvents: [e0, e1, e2],
                horizonDays: 2,
                seed: seed
            )
            var chrom = ScheduleChromosome.greedy(context: context)
            chrom.mutate(rate: 1.0, context: context)

            let byId = Dictionary(uniqueKeysWithValues: chrom.genes.map { ($0.eventId, $0) })
            if let g0 = byId["e0"], let g1 = byId["e1"], g0.isIncluded, g1.isIncluded {
                #expect(g1.startTime >= g0.endTime, "seed \(seed): e0→e1 violated")
            }
            if let g1 = byId["e1"], let g2 = byId["e2"], g1.isIncluded, g2.isIncluded {
                #expect(g2.startTime >= g1.endTime, "seed \(seed): e1→e2 violated")
            }
        }
    }

    @Test("Adaptive K: high stagnation widens the neighbourhood without breaking feasibility")
    func lnsHandlesHighStagnation() {
        // Crank stagnation to 1.0 so destroySize is amplified by ~2.5×.
        // Feasibility must still hold — the regret insertion doesn't skip
        // checks under pressure.
        let events = (0..<6).map { makeEvent(id: "e\($0)") }
        let context = contextForcingOperator(.lnsDay, movableEvents: events, seed: 999)
        context.mutationBandit.updateContext(
            BanditContext(diversity: 0.2, stagnation: 1.0, imbalance: 0.0)
        )

        var chrom = ScheduleChromosome.greedy(context: context)
        chrom.mutate(rate: 0.3, context: context)

        let placed = chrom.genes.filter { $0.isIncluded }
        for i in 0..<placed.count {
            for j in (i + 1)..<placed.count {
                #expect(!overlaps(placed[i], placed[j]))
            }
        }
    }

    @Test("Related-context destroy groups genes by context tag")
    func lnsRelatedContextClusters() {
        // Two context clusters of 3 events each. Run many seeds; some
        // strategies will fire `relatedContext` and cluster-destroy. The
        // result must stay overlap-free regardless of which cluster got
        // hit.
        func makeEventWithContext(_ id: String, _ ctx: String) -> OptimizableEvent {
            OptimizableEvent(id: id, title: id, duration: 3600, context: ctx)
        }
        let events = [
            makeEventWithContext("a1", "work"),
            makeEventWithContext("a2", "work"),
            makeEventWithContext("a3", "work"),
            makeEventWithContext("b1", "personal"),
            makeEventWithContext("b2", "personal"),
            makeEventWithContext("b3", "personal"),
        ]

        for seed in UInt64(30)...UInt64(40) {
            let context = contextForcingOperator(
                .lnsDay,
                movableEvents: events,
                horizonDays: 3,
                seed: seed
            )
            var chrom = ScheduleChromosome.greedy(context: context)
            chrom.mutate(rate: 0.5, context: context)

            let placed = chrom.genes.filter { $0.isIncluded }
            for i in 0..<placed.count {
                for j in (i + 1)..<placed.count {
                    #expect(!overlaps(placed[i], placed[j]),
                            "seed \(seed): overlap after related-context LNS")
                }
            }
        }
    }

    @Test("LNS keeps placed genes inside the planning horizon and working hours")
    func lnsRespectsHorizonAndHours() {
        let events = (0..<4).map { makeEvent(id: "e\($0)", durationMinutes: 60) }
        let context = contextForcingOperator(
            .lnsDay,
            movableEvents: events,
            workingHours: 9...18,
            horizonDays: 3
        )

        var chrom = ScheduleChromosome.greedy(context: context)
        chrom.mutate(rate: 0.5, context: context)

        let cal = context.calendar
        for g in chrom.genes where g.isIncluded {
            #expect(g.startTime >= context.planningHorizon.start)
            #expect(g.endTime <= context.planningHorizon.end)
            let startHour = cal.component(.hour, from: g.startTime)
            #expect(startHour >= context.workingHours.lowerBound)
            #expect(startHour <= context.workingHours.upperBound)
        }
    }
}
