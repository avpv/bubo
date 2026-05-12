import Foundation

// MARK: - #1 Focus Block Objective

/// Rewards schedules that create long, uninterrupted focus blocks.
/// Longer continuous free/focus time scores higher than fragmented time.
///
/// The objective is naturally day-partitioned: each day's score is an
/// independent function of that day's events, combined via simple mean.
/// Conforming to `DayPartitionedObjective` lets the evaluator rescore only
/// the days touched by a mutation; on typical weekly schedules this cuts
/// evaluator cost by ~6× per mutation (1 day dirty out of 7).
public struct FocusBlockObjective: DayPartitionedObjective {
    public let name = "FocusBlock"
    public var weight: Double

    public init(weight: Double = 1.0) {
        self.weight = weight
    }

    public func evaluate(chromosome: ScheduleChromosome, context: OptimizerContext) -> Double {
        let perDay = evaluatePerDay(chromosome: chromosome, context: context)
        return combinePerDay(perDay)
    }

    public func evaluatePerDay(
        chromosome: ScheduleChromosome,
        context: OptimizerContext
    ) -> [Date: Double] {
        let cal = context.calendar
        var eventsByDay: [Date: [(start: Date, end: Date)]] = [:]

        for event in context.fixedEvents {
            let day = cal.startOfDay(for: event.startDate)
            eventsByDay[day, default: []].append((event.startDate, event.endDate))
        }
        for gene in chromosome.genes where gene.isIncluded {
            let day = cal.startOfDay(for: gene.startTime)
            eventsByDay[day, default: []].append((gene.startTime, gene.endTime))
        }

        var scores: [Date: Double] = [:]
        for (day, events) in eventsByDay {
            scores[day] = scoreDay(day, events: events, context: context)
        }
        return scores
    }

    public func evaluateOneDay(
        day: Date,
        chromosome: ScheduleChromosome,
        context: OptimizerContext
    ) -> Double {
        let cal = context.calendar
        var events: [(start: Date, end: Date)] = []
        for event in context.fixedEvents where cal.startOfDay(for: event.startDate) == day {
            events.append((event.startDate, event.endDate))
        }
        for gene in chromosome.genes where gene.isIncluded && cal.startOfDay(for: gene.startTime) == day {
            events.append((gene.startTime, gene.endTime))
        }
        return scoreDay(day, events: events, context: context)
    }

    /// Score a single day's events. Shared by bulk and single-day paths so
    /// the scoring logic stays in exactly one place — a correctness risk I
    /// keep flagging whenever I see a delta-eval objective with two
    /// separate scoring implementations.
    private func scoreDay(
        _ day: Date,
        events: [(start: Date, end: Date)],
        context: OptimizerContext
    ) -> Double {
        let cal = context.calendar
        let idealMinutes = Double(context.preferences.idealFocusBlockMinutes)
        let sorted = events.sorted { $0.start < $1.start }

        guard let workStart = cal.date(bySettingHour: context.workingHours.lowerBound, minute: 0, second: 0, of: day),
              let workEnd = cal.date(bySettingHour: context.workingHours.upperBound, minute: 0, second: 0, of: day)
        else { return 0.5 }

        var gaps: [TimeInterval] = []
        var cursor = workStart

        for event in sorted {
            let eventStart = max(event.start, workStart)
            let eventEnd = min(event.end, workEnd)
            guard eventStart < workEnd && eventEnd > workStart else { continue }

            if eventStart > cursor {
                gaps.append(eventStart.timeIntervalSince(cursor))
            }
            cursor = max(cursor, eventEnd)
        }
        if cursor < workEnd {
            gaps.append(workEnd.timeIntervalSince(cursor))
        }

        let focusGaps = gaps.filter { $0 >= 30 * 60 }
        guard !focusGaps.isEmpty else { return 0.0 }

        let longestBlock = (focusGaps.max() ?? 0) / 60.0
        let avgBlock = focusGaps.reduce(0, +) / Double(focusGaps.count) / 60.0

        let longestScore = min(1.0, longestBlock / idealMinutes)
        let fragmentationScore = 1.0 / (1.0 + Double(gaps.count - focusGaps.count) * 0.2)

        return longestScore * 0.6 + fragmentationScore * 0.2 + min(1.0, avgBlock / idealMinutes) * 0.2
    }
}
