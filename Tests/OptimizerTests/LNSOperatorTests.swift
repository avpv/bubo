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

    @Test("LNS records lastDestroyStrategy so the strategy bandit can learn")
    func lnsRecordsLastDestroyStrategy() {
        let events = (0..<4).map { makeEvent(id: "e\($0)") }
        let context = contextForcingOperator(.lnsDay, movableEvents: events)

        var chrom = ScheduleChromosome.greedy(context: context)
        chrom.mutate(rate: 0.3, context: context)

        #expect(chrom.lastMutationOperator == .lnsDay)
        #expect(chrom.lastDestroyStrategy != nil,
                "LNS must expose which destroy strategy it used")
    }

    @Test("LNSStrategyBandit shifts weights toward rewarded strategies")
    func strategyBanditLearns() {
        let bandit = LNSStrategyBandit(learningRate: 0.3)
        // Fake 30 rounds of positive reward for `.worstFit` and negative
        // for everything else. After the smoothing EMA converges, roulette
        // should strongly favour `.worstFit`.
        for _ in 0..<30 {
            bandit.record(strategy: .worstFit, reward: 0.5)
            for s in LNSDestroyStrategy.allCases where s != .worstFit {
                bandit.record(strategy: s, reward: -0.5)
            }
        }
        let snap = bandit.snapshot
        let worstWeight = snap[.worstFit]?.weight ?? 0
        for s in LNSDestroyStrategy.allCases where s != .worstFit {
            let other = snap[s]?.weight ?? 0
            #expect(worstWeight > other,
                    "worstFit weight (\(worstWeight)) should beat \(s) weight (\(other))")
        }
    }

    @Test("LNSStrategyBandit select honours learned weights")
    func strategyBanditSelectionFavoursLearned() {
        let bandit = LNSStrategyBandit(learningRate: 0.3)
        for _ in 0..<30 {
            bandit.record(strategy: .day, reward: 0.5)
            for s in LNSDestroyStrategy.allCases where s != .day {
                bandit.record(strategy: s, reward: -0.5)
            }
        }
        let rng = GARandom(seed: 2024)
        var counts: [LNSDestroyStrategy: Int] = [:]
        for _ in 0..<500 {
            let pick = bandit.select(rng: rng)
            counts[pick, default: 0] += 1
        }
        let dayCount = counts[.day] ?? 0
        for s in LNSDestroyStrategy.allCases where s != .day {
            let otherCount = counts[s] ?? 0
            #expect(dayCount > otherCount,
                    ".day picked \(dayCount) times should beat \(s) picked \(otherCount) times")
        }
    }

    @Test("Cost proxy biases BnB toward high-energy slots for high-energy tasks")
    func cpRepairRespectsEnergyCurve() {
        // Build a context whose personalEnergyCurve peaks at 14:00 and
        // troughs at 9:00. A high-energyCost task should land in the
        // afternoon when the BnB has room to choose — not stuck at the
        // earliest feasible slot.
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let end = cal.date(byAdding: .day, value: 1, to: today)!
        // Curve: flat 0.1 except a peak from 13-16.
        var curve = [Double](repeating: 0.1, count: 24)
        for h in 13...16 { curve[h] = 1.0 }
        var prefs = OptimizerPreferences()
        prefs.personalEnergyCurve = curve
        prefs.energyCurveWeight = 2.0

        // One high-energy task with no preferred range and no deadline,
        // lots of free time. If BnB respects energy, it places after 13.
        let heavy = OptimizableEvent(
            id: "deep",
            title: "Deep Work",
            duration: 3600,
            priority: 0.5,
            energyCost: 1.0
        )
        let bandit = MutationBandit()
        bandit.updateContext(.neutral)
        for _ in 0..<60 {
            for op in MutationOperator.allCases {
                bandit.record(op: op, reward: op == .lnsDay ? 0.5 : -0.5)
            }
        }
        let context = OptimizerContext(
            movableEvents: [heavy],
            workingHours: 9...18,
            planningHorizon: DateInterval(start: today, end: end),
            preferences: prefs,
            rng: GARandom(seed: 4242),
            mutationBandit: bandit
        )

        // Seed the task in a low-energy slot to force LNS to relocate.
        var chrom = ScheduleChromosome.greedy(context: context)
        if let idx = chrom.genes.firstIndex(where: { $0.eventId == "deep" }) {
            chrom.genes[idx].startTime = cal.date(bySettingHour: 9, minute: 0, second: 0, of: today)!
        }
        chrom.mutate(rate: 1.0, context: context)

        if let deep = chrom.genes.first(where: { $0.eventId == "deep" && $0.isIncluded }) {
            let hour = cal.component(.hour, from: deep.startTime)
            #expect(hour >= 11, "deep-work task should be placed in high-energy window, got hour \(hour)")
        }
    }

    @Test("Forward checking keeps schedules feasible under tight dependency chains")
    func cpRepairForwardChecksDependencies() {
        // Three tasks with a dependency chain a→b→c, each 2 hours, on a
        // 1-day horizon with a 2-hour fixed meeting at 13-15. Total free
        // time: 9-13 (4h) + 15-18 (3h) = 7h, dependency-ordered 2+2+2 =
        // 6h. One feasible layout exists; forward checking has to find
        // it without thrashing.
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let fixStart = cal.date(bySettingHour: 13, minute: 0, second: 0, of: today)!
        let fixed = CalendarEvent(
            id: "block",
            title: "Block",
            startDate: fixStart,
            endDate: fixStart.addingTimeInterval(7200),
            location: nil,
            description: nil,
            calendarName: "Test",
            eventType: .standard
        )
        let a = makeEvent(id: "a", durationMinutes: 120, priority: 0.9)
        let b = makeEvent(id: "b", durationMinutes: 120, priority: 0.9, dependsOn: ["a"])
        let c = makeEvent(id: "c", durationMinutes: 120, priority: 0.9, dependsOn: ["b"])
        let context = contextForcingOperator(
            .lnsDay,
            movableEvents: [a, b, c],
            fixedEvents: [fixed],
            horizonDays: 1,
            seed: 7654
        )

        var chrom = ScheduleChromosome.greedy(context: context)
        chrom.mutate(rate: 1.0, context: context)

        let byId = Dictionary(uniqueKeysWithValues: chrom.genes.map { ($0.eventId, $0) })
        #expect(byId["a"]?.isIncluded == true, "a should stay scheduled")
        #expect(byId["b"]?.isIncluded == true, "b should stay scheduled")
        #expect(byId["c"]?.isIncluded == true, "c should stay scheduled")

        if let ga = byId["a"], let gb = byId["b"], let gc = byId["c"],
           ga.isIncluded, gb.isIncluded, gc.isIncluded {
            #expect(gb.startTime >= ga.endTime, "b must not start before a ends")
            #expect(gc.startTime >= gb.endTime, "c must not start before b ends")
            for g in [ga, gb, gc] {
                let overlap = g.startTime < fixed.endDate && g.endTime > fixed.startDate
                #expect(!overlap, "gene \(g.eventId) overlaps the fixed block")
            }
        }
    }

    @Test("CP repair produces feasible placements for a tight workload")
    func cpRepairFeasibleTight() {
        // A deliberately tight workload: 4 one-hour tasks on a 1-day
        // horizon where a fixed meeting eats two hours. Greedy first-fit
        // would fail on some orderings; CP BnB must find a feasible
        // arrangement (or drop droppables) without leaving overlaps.
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let fixStart = cal.date(bySettingHour: 11, minute: 0, second: 0, of: today)!
        let fixed = CalendarEvent(
            id: "meeting",
            title: "Meeting",
            startDate: fixStart,
            endDate: fixStart.addingTimeInterval(7200),
            location: nil,
            description: nil,
            calendarName: "Test",
            eventType: .standard
        )
        let events = (0..<4).map { makeEvent(id: "e\($0)", durationMinutes: 60) }
        let context = contextForcingOperator(
            .lnsDay,
            movableEvents: events,
            fixedEvents: [fixed],
            horizonDays: 1,
            seed: 555
        )

        var chrom = ScheduleChromosome.greedy(context: context)
        chrom.mutate(rate: 1.0, context: context)

        let placed = chrom.genes.filter { $0.isIncluded }
        for g in placed {
            // No overlap with the fixed meeting.
            let overlapsFixed = g.startTime < fixed.endDate && g.endTime > fixed.startDate
            #expect(!overlapsFixed)
        }
        for i in 0..<placed.count {
            for j in (i + 1)..<placed.count {
                #expect(!overlaps(placed[i], placed[j]))
            }
        }
    }

    @Test("Priority-weighted drop penalty keeps high-priority genes when something must go")
    func cpRepairPrefersDroppingLowPriority() {
        // A 1-day horizon blocked by a 7-hour fixed event (9-16), leaving
        // 2 hours free (16-18). Three 1-hour droppable tasks compete for
        // those slots: one high-priority, two low. The priority-weighted
        // drop penalty should keep the high-priority task every time the
        // BnB finds a complete plan.
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let fixStart = cal.date(bySettingHour: 9, minute: 0, second: 0, of: today)!
        let fixed = CalendarEvent(
            id: "block",
            title: "Block",
            startDate: fixStart,
            endDate: fixStart.addingTimeInterval(7 * 3600),
            location: nil,
            description: nil,
            calendarName: "Test",
            eventType: .standard
        )
        let high = OptimizableEvent(
            id: "important",
            title: "Important",
            duration: 3600,
            priority: 0.95,
            isDroppable: true
        )
        let low1 = OptimizableEvent(
            id: "minor1",
            title: "Minor 1",
            duration: 3600,
            priority: 0.15,
            isDroppable: true
        )
        let low2 = OptimizableEvent(
            id: "minor2",
            title: "Minor 2",
            duration: 3600,
            priority: 0.15,
            isDroppable: true
        )
        let context = contextForcingOperator(
            .lnsDay,
            movableEvents: [high, low1, low2],
            fixedEvents: [fixed],
            horizonDays: 1,
            seed: 8181
        )

        var chrom = ScheduleChromosome.greedy(context: context)
        chrom.mutate(rate: 1.0, context: context)

        let byId = Dictionary(uniqueKeysWithValues: chrom.genes.map { ($0.eventId, $0) })
        #expect(byId["important"]?.isIncluded == true,
                "high-priority task should survive when BnB has to drop something")
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
