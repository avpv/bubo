import Foundation
@testable import Bubo

// MARK: - Benchmark Scenarios
//
// Canonical workloads covering distinct stress axes of the scheduler. Each
// scenario is deterministic given its base seed so cross-variant comparison
// is paired by workload (not by fresh random draws).
//
// Five families, mapped to failure modes the 14 objectives expose:
//
//   weekly-light    — 12 events, 5 days, generous slack. Baseline case;
//                     most objectives should saturate high. Variants that
//                     improve here earn confidence they don't regress on
//                     the easy distribution.
//
//   busy-week       — 35 events, 5 days, near-saturation. Stresses
//                     ConflictObjective, BufferObjective, BreakObjective.
//                     The surface where repair operators should shine.
//
//   multi-person    — 18 events, 3 days, 3 participants with limited
//                     availability windows. Exercises MultiPersonObjective
//                     and participant-availability constraints — an axis
//                     invisible in single-user scenarios.
//
//   deadline-heavy  — 20 events, 5 days, 60% carry a deadline. Puts
//                     DeadlineObjective and PrecedenceObjective under
//                     explicit pressure; naive LNS that drops droppables
//                     early regresses here.
//
//   sparse-week     — 6 events, 5 days. Tests that a variant doesn't
//                     over-optimize the empty landscape — sparse is where
//                     "improvements" often evaporate in the noise floor
//                     and reveal measurement-theatre claims.

enum BenchmarkScenario: String, CaseIterable, Sendable {
    case weeklyLight    = "weekly-light"
    case busyWeek       = "busy-week"
    case multiPerson    = "multi-person"
    case deadlineHeavy  = "deadline-heavy"
    case sparseWeek     = "sparse-week"

    /// Build the context for this scenario with the given base seed.
    /// The seed drives both the GA's RNG and the deterministic event
    /// generation below, so `(scenario, seed)` fully identifies a workload.
    @MainActor
    func makeContext(seed: UInt64) -> OptimizerContext {
        switch self {
        case .weeklyLight:   return makeWeeklyLight(seed: seed)
        case .busyWeek:      return makeBusyWeek(seed: seed)
        case .multiPerson:   return makeMultiPerson(seed: seed)
        case .deadlineHeavy: return makeDeadlineHeavy(seed: seed)
        case .sparseWeek:    return makeSparseWeek(seed: seed)
        }
    }
}

// MARK: - Scenario Builders

@MainActor
private func makeWeeklyLight(seed: UInt64) -> OptimizerContext {
    let (start, end) = weekRange(days: 5)
    let events = (0..<12).map { i -> OptimizableEvent in
        OptimizableEvent(
            id: "wl-\(i)",
            title: "Task \(i)",
            duration: TimeInterval((30 + (i % 4) * 15) * 60),
            priority: 0.3 + Double(i % 5) * 0.15,
            energyCost: 0.4 + Double(i % 3) * 0.15,
            isFocusBlock: i % 4 == 0,
            storyPoints: 1 + (i % 5)
        )
    }
    return OptimizerContext(
        fixedEvents: [],
        movableEvents: events,
        workingHours: 9...18,
        planningHorizon: DateInterval(start: start, end: end),
        preferences: OptimizerPreferences(),
        rng: GARandom(seed: seed)
    )
}

@MainActor
private func makeBusyWeek(seed: UInt64) -> OptimizerContext {
    let (start, end) = weekRange(days: 5)
    // 35 events ≈ 7/day over 9h window ≈ ~75min each is saturating once
    // overhead (break, buffer, context-switch) is counted.
    let events = (0..<35).map { i -> OptimizableEvent in
        OptimizableEvent(
            id: "bw-\(i)",
            title: "Task \(i)",
            duration: TimeInterval((45 + (i % 6) * 10) * 60),
            priority: Double((i * 31 + 7) % 100) / 100.0,
            energyCost: 0.3 + Double((i * 13) % 7) / 10.0,
            isFocusBlock: i % 5 == 0,
            storyPoints: 1 + (i % 8),
            isDroppable: i >= 28                 // last 7 can be dropped if needed
        )
    }
    return OptimizerContext(
        fixedEvents: [],
        movableEvents: events,
        workingHours: 9...18,
        planningHorizon: DateInterval(start: start, end: end),
        preferences: OptimizerPreferences(),
        rng: GARandom(seed: seed)
    )
}

@MainActor
private func makeMultiPerson(seed: UInt64) -> OptimizerContext {
    let (start, end) = weekRange(days: 3)
    let participants = ["alice", "bob", "carol"]
    let events = (0..<18).map { i -> OptimizableEvent in
        // Every 3rd event requires 2 participants; others are solo.
        let required: [String] = i % 3 == 0
            ? [participants[i % participants.count], participants[(i + 1) % participants.count]]
            : []
        return OptimizableEvent(
            id: "mp-\(i)",
            title: "Meeting \(i)",
            duration: TimeInterval((30 + (i % 3) * 30) * 60),
            priority: 0.5 + Double(i % 4) * 0.1,
            energyCost: 0.45,
            requiredParticipants: required,
            isFocusBlock: false,
            storyPoints: 2
        )
    }

    // Limited availability: each participant is free only for specific
    // windows per day. Squeezes the scheduler into a narrow feasible region
    // so MultiPersonObjective has teeth.
    let cal = Calendar.current
    var availability: [String: [DateInterval]] = [:]
    for (pIdx, p) in participants.enumerated() {
        var windows: [DateInterval] = []
        for dayOffset in 0..<3 {
            let dayStart = cal.date(byAdding: .day, value: dayOffset, to: start)!
            let windowStart = cal.date(bySettingHour: 9 + pIdx * 2, minute: 0, second: 0, of: dayStart)!
            let windowEnd = cal.date(byAdding: .hour, value: 5, to: windowStart)!
            windows.append(DateInterval(start: windowStart, end: windowEnd))
        }
        availability[p] = windows
    }

    return OptimizerContext(
        fixedEvents: [],
        movableEvents: events,
        workingHours: 9...18,
        planningHorizon: DateInterval(start: start, end: end),
        preferences: OptimizerPreferences(),
        participantAvailability: availability,
        rng: GARandom(seed: seed)
    )
}

@MainActor
private func makeDeadlineHeavy(seed: UInt64) -> OptimizerContext {
    let (start, end) = weekRange(days: 5)
    let cal = Calendar.current
    let events = (0..<20).map { i -> OptimizableEvent in
        // 60% of events carry a deadline, staggered across days 1-4.
        // Deadlines deliberately overlap in density so DeadlineObjective
        // has to make hard trade-offs with TaskPlacement/Buffer.
        let hasDeadline = i % 5 != 0
        let deadline: Date? = hasDeadline
            ? cal.date(byAdding: .day, value: 1 + (i % 4), to: start)
            : nil
        // Chain: tasks 5-9 depend on tasks 0-4 respectively — forces
        // PrecedenceObjective to interact with deadlines.
        let deps: [String] = (i >= 5 && i < 10) ? ["dh-\(i - 5)"] : []
        return OptimizableEvent(
            id: "dh-\(i)",
            title: "Task \(i)",
            duration: TimeInterval((45 + (i % 4) * 15) * 60),
            deadline: deadline,
            priority: hasDeadline ? 0.7 : 0.3,
            energyCost: 0.5,
            isFocusBlock: i % 4 == 0,
            storyPoints: 2 + (i % 5),
            dependsOn: deps
        )
    }
    return OptimizerContext(
        fixedEvents: [],
        movableEvents: events,
        workingHours: 9...18,
        planningHorizon: DateInterval(start: start, end: end),
        preferences: OptimizerPreferences(),
        rng: GARandom(seed: seed)
    )
}

@MainActor
private func makeSparseWeek(seed: UInt64) -> OptimizerContext {
    let (start, end) = weekRange(days: 5)
    let events = (0..<6).map { i -> OptimizableEvent in
        OptimizableEvent(
            id: "sw-\(i)",
            title: "Task \(i)",
            duration: TimeInterval((30 + i * 15) * 60),
            priority: 0.5,
            energyCost: 0.4,
            isFocusBlock: i.isMultiple(of: 2)
        )
    }
    return OptimizerContext(
        fixedEvents: [],
        movableEvents: events,
        workingHours: 9...18,
        planningHorizon: DateInterval(start: start, end: end),
        preferences: OptimizerPreferences(),
        rng: GARandom(seed: seed)
    )
}

// MARK: - Helpers

@MainActor
private func weekRange(days: Int) -> (start: Date, end: Date) {
    let cal = Calendar.current
    let start = cal.startOfDay(for: Date())
    let end = cal.date(byAdding: .day, value: days, to: start)!
    return (start, end)
}
