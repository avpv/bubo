import Foundation

// MARK: - IntentCompiler horizon + pre-flight
//
// Date-math and feasibility checks that bracket the GA call: resolve a
// `Horizon` enum into a concrete `DateInterval` (with overflow-to-
// tomorrow when today has no room left), trim the backlog to what the
// remaining working hours can actually fit, run a pre-flight check that
// catches "no working days in horizon" / "no events to schedule" /
// "horizon is in the past" before the GA wastes a budget, and build the
// scheduling snapshot the reasoning surface compares against later.
//
// Extracted from `IntentCompiler.swift` so the compute-time decisions
// (horizon math, capacity check) live in one file separate from the
// intent-by-intent application logic in `+Apply` and the event
// materialisation in `+EventCollection`.

extension IntentCompiler {

    func resolveHorizon(_ horizon: Horizon, workingHours: ClosedRange<Int>, minRequiredMinutes: Double, overflowToNextDay: Bool = false) -> DateInterval {
        let cal = Calendar.current
        let now = Date()

        switch horizon {
        case .today:
            let todayEnd = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: now))!
            // Extend to tomorrow if explicitly requested or if not enough time left
            if overflowToNextDay {
                let tomorrowEnd = cal.date(byAdding: .day, value: 1, to: todayEnd)!
                return DateInterval(start: now, end: tomorrowEnd)
            }
            let workEndToday = cal.date(
                bySettingHour: workingHours.upperBound, minute: 0, second: 0, of: now
            ) ?? todayEnd
            let remainingMinutes = workEndToday.timeIntervalSince(now) / 60
            if remainingMinutes < minRequiredMinutes {
                let tomorrowEnd = cal.date(byAdding: .day, value: 1, to: todayEnd)!
                return DateInterval(start: now, end: tomorrowEnd)
            }
            return DateInterval(start: now, end: todayEnd)
        case .tomorrow:
            let tomorrowStart = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: now))!
            let tomorrowEnd = cal.date(byAdding: .day, value: 1, to: tomorrowStart)!
            return DateInterval(start: tomorrowStart, end: tomorrowEnd)
        case .week:
            let weekEnd = cal.date(byAdding: .day, value: 7, to: now)!
            return DateInterval(start: now, end: weekEnd)
        }
    }

    func preflightCheck(context: OptimizerContext) -> (reason: String, resolutions: [ActionableResolution])? {
        let cal = context.calendar
        let now = Date()
        var availableMinutes: Double = 0
        var largestGapMinutes: Double = 0
        var day = cal.startOfDay(for: context.planningHorizon.start)
        let horizonEnd = context.planningHorizon.end

        while day < horizonEnd {
            guard let workStart = cal.date(bySettingHour: context.workingHours.lowerBound, minute: 0, second: 0, of: day),
                  let workEnd = cal.date(bySettingHour: context.workingHours.upperBound, minute: 0, second: 0, of: day) else {
                day = cal.date(byAdding: .day, value: 1, to: day)!
                continue
            }

            let effectiveStart = max(workStart, max(now, context.planningHorizon.start))
            let effectiveEnd = min(workEnd, horizonEnd)

            if effectiveEnd > effectiveStart {
                var freeMinutes = effectiveEnd.timeIntervalSince(effectiveStart) / 60
                let overlapping = context.fixedEvents
                    .compactMap { fixed -> (start: Date, end: Date)? in
                        let oStart = max(fixed.startDate, effectiveStart)
                        let oEnd = min(fixed.endDate, effectiveEnd)
                        return oEnd > oStart ? (oStart, oEnd) : nil
                    }
                    .sorted { $0.start < $1.start }

                var cursor = effectiveStart
                for fixed in overlapping {
                    let gapMinutes = fixed.start.timeIntervalSince(cursor) / 60
                    if gapMinutes > 0 { largestGapMinutes = max(largestGapMinutes, gapMinutes) }
                    // Only subtract the portion not already covered by a previous event
                    let effectiveFixedStart = max(fixed.start, cursor)
                    if fixed.end > effectiveFixedStart {
                        freeMinutes -= fixed.end.timeIntervalSince(effectiveFixedStart) / 60
                    }
                    cursor = max(cursor, fixed.end)
                }
                let trailingGap = effectiveEnd.timeIntervalSince(cursor) / 60
                if trailingGap > 0 { largestGapMinutes = max(largestGapMinutes, trailingGap) }
                availableMinutes += max(0, freeMinutes)
            }
            day = cal.date(byAdding: .day, value: 1, to: day)!
        }

        // Only count non-droppable events as required; droppable tasks will
        // be excluded by the GA if they don't fit.
        let requiredEvents = context.movableEvents.filter { !$0.isDroppable }
        let requiredMinutes = requiredEvents.reduce(0.0) { $0 + $1.duration / 60 }
        let longestEventMinutes = requiredEvents.map { $0.duration / 60 }.max() ?? 0

        if availableMinutes < 1 {
            return ("No working time left — try tomorrow", [
                ActionableResolution(
                    title: "Schedule tomorrow",
                    modifier: OptimizationRequest(.horizon(.tomorrow))
                )
            ])
        }
        if requiredMinutes > availableMinutes {
            var resolutions: [ActionableResolution] = []
            
            if let taskToDrop = context.movableEvents.sorted(by: { $0.priority < $1.priority }).first {
                resolutions.append(ActionableResolution(
                    title: "Drop '\(taskToDrop.title)'",
                    modifier: OptimizationRequest(.exclude(eventIds: [taskToDrop.id]))
                ))
            }
            
            let needExtraMinutes = requiredMinutes - availableMinutes
            let extraHours = Int(ceil(needExtraMinutes / 60.0))
            let currentEnd = context.workingHours.upperBound
            
            if currentEnd + extraHours <= 24 {
                resolutions.append(ActionableResolution(
                    title: "Extend day to \(currentEnd + extraHours):00",
                    modifier: OptimizationRequest(.workingHours(start: context.workingHours.lowerBound, end: currentEnd + extraHours))
                ))
            }

            return ("Need \(Int(requiredMinutes)) min but only \(Int(availableMinutes)) min available", resolutions)
        }
        if longestEventMinutes > largestGapMinutes {
            var resolutions: [ActionableResolution] = []
            if largestGapMinutes >= 15 {
                resolutions.append(ActionableResolution(
                    title: "Split to fit \(Int(largestGapMinutes))m",
                    modifier: OptimizationRequest(.splitLong(maxMinutes: Int(largestGapMinutes)))
                ))
            }
            return ("Longest event (\(Int(longestEventMinutes)) min) doesn't fit in largest gap (\(Int(largestGapMinutes)) min)", resolutions)
        }
        return nil
    }

    /// Cap backlog tasks to fit within available time so the GA can find feasible solutions.
    /// Sorts by priority (highest first) and greedily includes tasks until time budget is reached.
    func capBacklogToAvailableTime(
        _ backlogTasks: [OptimizableEvent],
        coreEvents: [OptimizableEvent],
        fixedEvents: [CalendarEvent],
        workingHours: ClosedRange<Int>,
        horizon: DateInterval,
        maxExtraTasks: Int?
    ) -> [OptimizableEvent] {
        guard !backlogTasks.isEmpty else { return [] }

        let cal = Calendar.current
        let now = Date()
        var availableMinutes: Double = 0
        var day = cal.startOfDay(for: horizon.start)

        while day < horizon.end {
            guard let workStart = cal.date(bySettingHour: workingHours.lowerBound, minute: 0, second: 0, of: day),
                  let workEnd = cal.date(bySettingHour: workingHours.upperBound, minute: 0, second: 0, of: day) else {
                day = cal.date(byAdding: .day, value: 1, to: day)!
                continue
            }

            let effectiveStart = max(workStart, max(now, horizon.start))
            let effectiveEnd = min(workEnd, horizon.end)

            if effectiveEnd > effectiveStart {
                var freeMinutes = effectiveEnd.timeIntervalSince(effectiveStart) / 60
                let overlapping = fixedEvents
                    .compactMap { fixed -> (start: Date, end: Date)? in
                        let oStart = max(fixed.startDate, effectiveStart)
                        let oEnd = min(fixed.endDate, effectiveEnd)
                        return oEnd > oStart ? (oStart, oEnd) : nil
                    }
                for fixed in overlapping {
                    freeMinutes -= fixed.end.timeIntervalSince(fixed.start) / 60
                }
                availableMinutes += max(0, freeMinutes)
            }
            day = cal.date(byAdding: .day, value: 1, to: day)!
        }

        // Subtract time needed by core (non-backlog) events
        let coreMinutes = coreEvents.reduce(0.0) { $0 + $1.duration / 60 }
        let remainingMinutes = availableMinutes - coreMinutes

        // Allow 120% of remaining time — the GA will drop tasks that don't fit
        // via the isIncluded gene mechanism. Overshoot gives the GA room to
        // explore different task combinations and find the best subset.
        let usableMinutes = remainingMinutes * 1.2

        guard usableMinutes > 0 else { return [] }

        // Sort by priority (highest first) to keep most important tasks
        let sorted = backlogTasks.sorted { $0.priority > $1.priority }

        // Apply maxExtraTasks limit if set
        let maxCount = maxExtraTasks ?? sorted.count
        let limited = Array(sorted.prefix(maxCount))

        // Greedily add tasks until time budget is reached
        var totalMinutes: Double = 0
        var result: [OptimizableEvent] = []
        for task in limited {
            let taskMinutes = task.duration / 60
            if totalMinutes + taskMinutes <= usableMinutes {
                result.append(task)
                totalMinutes += taskMinutes
            }
        }

        return result
    }

    func buildSnapshot(fixedEvents: [CalendarEvent], workingHours: ClosedRange<Int>, horizon: DateInterval) -> ScheduleSnapshot {
        let cal = Calendar.current
        let now = Date()
        var gaps: [DateInterval] = []
        var day = cal.startOfDay(for: horizon.start)

        while day < horizon.end {
            guard let workStart = cal.date(bySettingHour: workingHours.lowerBound, minute: 0, second: 0, of: day),
                  let workEnd = cal.date(bySettingHour: workingHours.upperBound, minute: 0, second: 0, of: day) else {
                day = cal.date(byAdding: .day, value: 1, to: day)!
                continue
            }

            let effectiveStart = max(workStart, max(now, horizon.start))
            let effectiveEnd = min(workEnd, horizon.end)

            if effectiveEnd > effectiveStart {
                let overlapping = fixedEvents
                    .compactMap { fixed -> (start: Date, end: Date)? in
                        let oStart = max(fixed.startDate, effectiveStart)
                        let oEnd = min(fixed.endDate, effectiveEnd)
                        return oEnd > oStart ? (oStart, oEnd) : nil
                    }
                    .sorted { $0.start < $1.start }

                var cursor = effectiveStart
                for fixed in overlapping {
                    if fixed.start > cursor { gaps.append(DateInterval(start: cursor, end: fixed.start)) }
                    cursor = max(cursor, fixed.end)
                }
                if effectiveEnd > cursor { gaps.append(DateInterval(start: cursor, end: effectiveEnd)) }
            }
            day = cal.date(byAdding: .day, value: 1, to: day)!
        }

        return ScheduleSnapshot(freeGaps: gaps, workingHours: workingHours, planningHorizon: horizon)
    }
}
