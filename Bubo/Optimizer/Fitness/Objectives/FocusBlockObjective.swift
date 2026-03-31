import Foundation

// MARK: - #1 Focus Block Objective

/// Rewards schedules that create long, uninterrupted focus blocks.
/// Longer continuous free/focus time scores higher than fragmented time.
struct FocusBlockObjective: FitnessObjective {
    let name = "FocusBlock"
    var weight: Double

    init(weight: Double = 1.0) {
        self.weight = weight
    }

    func evaluate(chromosome: ScheduleChromosome, context: OptimizerContext) -> Double {
        let cal = context.calendar
        let idealMinutes = Double(context.preferences.idealFocusBlockMinutes)

        // Collect all events (fixed + movable) sorted by start time, grouped by day
        var eventsByDay: [Date: [(start: Date, end: Date)]] = [:]

        for event in context.fixedEvents {
            let day = cal.startOfDay(for: event.startDate)
            eventsByDay[day, default: []].append((event.startDate, event.endDate))
        }
        for gene in chromosome.genes {
            let day = cal.startOfDay(for: gene.startTime)
            eventsByDay[day, default: []].append((gene.startTime, gene.endTime))
        }

        guard !eventsByDay.isEmpty else { return 1.0 }

        var totalScore = 0.0
        var dayCount = 0

        for (day, events) in eventsByDay {
            let sorted = events.sorted { $0.start < $1.start }

            // Calculate free gaps between events within working hours
            let workStart = cal.date(bySettingHour: context.workingHours.lowerBound, minute: 0, second: 0, of: day)!
            let workEnd = cal.date(bySettingHour: context.workingHours.upperBound, minute: 0, second: 0, of: day)!

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
            // Gap after last event
            if cursor < workEnd {
                gaps.append(workEnd.timeIntervalSince(cursor))
            }

            // Score: reward long focus blocks, penalize fragmentation
            let focusGaps = gaps.filter { $0 >= 30 * 60 }  // at least 30 min counts as focus time
            if focusGaps.isEmpty {
                totalScore += 0.0
            } else {
                let longestBlock = focusGaps.max()! / 60.0  // in minutes
                let avgBlock = focusGaps.reduce(0, +) / Double(focusGaps.count) / 60.0

                // Score based on how close the longest block is to ideal
                let longestScore = min(1.0, longestBlock / idealMinutes)
                // Bonus for having fewer, longer blocks (anti-fragmentation)
                let fragmentationScore = 1.0 / (1.0 + Double(gaps.count - focusGaps.count) * 0.2)

                totalScore += (longestScore * 0.6 + fragmentationScore * 0.2 + min(1.0, avgBlock / idealMinutes) * 0.2)
            }
            dayCount += 1
        }

        return dayCount > 0 ? totalScore / Double(dayCount) : 0.5
    }
}
