import Foundation

// MARK: - #18 Break Placement Objective

/// Ensures adequate breaks are present between consecutive meetings.
/// Penalizes long stretches without breaks and rewards lunch-time gaps.
///
/// Day-partitioned: every component (consecutive-time penalty, break ratio,
/// lunch gap) is defined strictly within a single day, so the top-level
/// aggregation is already an unweighted mean across days. Delta evaluation
/// drops to O(dirty_days) instead of O(horizon_days) for single-gene
/// mutations, which is the common case on weekly plans.
struct BreakObjective: DayPartitionedObjective {
    let name = "BreakPlacement"
    var weight: Double

    init(weight: Double = 1.2) {
        self.weight = weight
    }

    func evaluate(chromosome: ScheduleChromosome, context: OptimizerContext) -> Double {
        let perDay = evaluatePerDay(chromosome: chromosome, context: context)
        // Preserve the pre-partitioning default: no events on the horizon
        // returns 1.0; combinePerDay already does this.
        return combinePerDay(perDay)
    }

    func evaluatePerDay(
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

        var perDay: [Date: Double] = [:]
        perDay.reserveCapacity(eventsByDay.count)
        for (day, events) in eventsByDay {
            perDay[day] = scoreDay(day: day, events: events, preferences: context.preferences, calendar: cal)
        }
        includeDroppedGeneDays(&perDay, chromosome: chromosome, calendar: cal)
        return perDay
    }

    func evaluateOneDay(
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
        return scoreDay(day: day, events: events, preferences: context.preferences, calendar: cal)
    }

    /// Day-level scoring core shared between full and delta paths. Moving the
    /// three sub-score pieces here keeps the per-day math identical; any
    /// future tweak applies to both evaluation entry points.
    private func scoreDay(
        day: Date,
        events: [(start: Date, end: Date)],
        preferences: OptimizerPreferences,
        calendar cal: Calendar
    ) -> Double {
        let maxConsecutive = TimeInterval(preferences.maxConsecutiveMeetingMinutes * 60)
        let minBreak = TimeInterval(preferences.minBreakMinutes * 60)
        let lunchStart = preferences.lunchWindowStart
        let lunchEnd = preferences.lunchWindowEnd

        let sorted = events.sorted { $0.start < $1.start }
        var score = 0.0

        // 1. Consecutive meeting duration (0.4 weight)
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
            if gap >= minBreak { adequateBreaks += 1 }
        }
        let breakRatio = totalGaps > 0 ? Double(adequateBreaks) / Double(totalGaps) : 1.0
        score += breakRatio * 0.3

        // 3. Lunch break available (0.3 weight)
        let lunchStartTime = cal.date(bySettingHour: lunchStart, minute: 0, second: 0, of: day)!
        let lunchEndTime = cal.date(bySettingHour: lunchEnd, minute: 0, second: 0, of: day)!
        let lunchConflicts = sorted.filter { event in
            event.start < lunchEndTime && event.end > lunchStartTime
        }
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
        let lunchScore = min(1.0, lunchGap / (30 * 60))
        score += lunchScore * 0.3

        return score
    }
}
