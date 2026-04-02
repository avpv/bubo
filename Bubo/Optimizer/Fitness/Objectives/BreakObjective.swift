import Foundation

// MARK: - #18 Break Placement Objective

/// Ensures adequate breaks are present between consecutive meetings.
/// Penalizes long stretches without breaks and rewards lunch-time gaps.
struct BreakObjective: FitnessObjective {
    let name = "BreakPlacement"
    var weight: Double

    init(weight: Double = 1.2) {
        self.weight = weight
    }

    func evaluate(chromosome: ScheduleChromosome, context: OptimizerContext) -> Double {
        let cal = context.calendar
        let maxConsecutive = TimeInterval(context.preferences.maxConsecutiveMeetingMinutes * 60)
        let minBreak = TimeInterval(context.preferences.minBreakMinutes * 60)
        let lunchStart = context.preferences.lunchWindowStart
        let lunchEnd = context.preferences.lunchWindowEnd

        // Group all events by day
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

            var score = 0.0

            // 1. Check consecutive meeting duration (0.4 weight)
            var consecutiveTime: TimeInterval = 0
            var hasOverlong = false

            for i in 0..<sorted.count {
                let duration = sorted[i].end.timeIntervalSince(sorted[i].start)
                if i > 0 {
                    let gap = sorted[i].start.timeIntervalSince(sorted[i - 1].end)
                    if gap < minBreak {
                        consecutiveTime += duration
                    } else {
                        consecutiveTime = duration
                    }
                } else {
                    consecutiveTime = duration
                }

                if consecutiveTime > maxConsecutive {
                    hasOverlong = true
                }
            }
            // Gradient: schedules barely over the limit score better than those far over.
            // consecutiveTime at maxConsecutive → 0.4, at 2x maxConsecutive → ~0.13, at 3x → ~0.05
            if hasOverlong {
                let overage = max(0, consecutiveTime - maxConsecutive)
                score += 0.4 * exp(-overage / maxConsecutive)
            } else {
                score += 0.4
            }

            // 2. Adequate breaks between meetings (0.3 weight)
            var adequateBreaks = 0
            var totalGaps = 0
            for i in 0..<(sorted.count - 1) {
                let gap = sorted[i + 1].start.timeIntervalSince(sorted[i].end)
                totalGaps += 1
                if gap >= minBreak {
                    adequateBreaks += 1
                }
            }
            let breakRatio = totalGaps > 0 ? Double(adequateBreaks) / Double(totalGaps) : 1.0
            score += breakRatio * 0.3

            // 3. Lunch break available (0.3 weight)
            let lunchStartTime = cal.date(bySettingHour: lunchStart, minute: 0, second: 0, of: day)!
            let lunchEndTime = cal.date(bySettingHour: lunchEnd, minute: 0, second: 0, of: day)!

            let lunchConflicts = sorted.filter { event in
                event.start < lunchEndTime && event.end > lunchStartTime
            }
            // Find the largest gap during lunch window
            var lunchGap: TimeInterval = 0
            if lunchConflicts.isEmpty {
                lunchGap = lunchEndTime.timeIntervalSince(lunchStartTime)
            } else {
                let lunchSorted = lunchConflicts.sorted { $0.start < $1.start }
                var cursor = lunchStartTime
                for event in lunchSorted {
                    let gapStart = max(cursor, lunchStartTime)
                    let gapEnd = min(event.start, lunchEndTime)
                    if gapEnd > gapStart {
                        lunchGap = max(lunchGap, gapEnd.timeIntervalSince(gapStart))
                    }
                    cursor = max(cursor, event.end)
                }
                if cursor < lunchEndTime {
                    lunchGap = max(lunchGap, lunchEndTime.timeIntervalSince(cursor))
                }
            }
            let lunchScore = min(1.0, lunchGap / (30 * 60))  // at least 30 min for lunch
            score += lunchScore * 0.3

            totalScore += score
            dayCount += 1
        }

        return dayCount > 0 ? totalScore / Double(dayCount) : 0.5
    }
}
