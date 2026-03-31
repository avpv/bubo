import Foundation

// MARK: - #9 Week Balance Objective

/// Rewards even distribution of meetings/tasks across days of the week.
/// Penalizes days that are overloaded while others are empty.
struct WeekBalanceObjective: FitnessObjective {
    let name = "WeekBalance"
    var weight: Double

    init(weight: Double = 0.8) {
        self.weight = weight
    }

    func evaluate(chromosome: ScheduleChromosome, context: OptimizerContext) -> Double {
        let cal = context.calendar

        // Count meeting minutes per day
        var minutesByDay: [Date: Double] = [:]

        // Fixed events
        for event in context.fixedEvents {
            let day = cal.startOfDay(for: event.startDate)
            minutesByDay[day, default: 0] += event.endDate.timeIntervalSince(event.startDate) / 60
        }
        // Movable events
        for gene in chromosome.genes {
            let day = cal.startOfDay(for: gene.startTime)
            minutesByDay[day, default: 0] += gene.duration / 60
        }

        // Include all working days in the horizon (even empty ones)
        let daysInHorizon = context.calendar.dateComponents(
            [.day], from: context.planningHorizon.start, to: context.planningHorizon.end
        ).day ?? 1
        for dayOffset in 0..<daysInHorizon {
            guard let day = cal.date(byAdding: .day, value: dayOffset, to: context.planningHorizon.start) else { continue }
            // Exclude weekends using locale-safe check
            if !cal.isDateInWeekend(day) {
                let startOfDay = cal.startOfDay(for: day)
                if minutesByDay[startOfDay] == nil {
                    minutesByDay[startOfDay] = 0
                }
            }
        }

        guard minutesByDay.count > 1 else { return 1.0 }

        let values = Array(minutesByDay.values)
        let mean = values.reduce(0, +) / Double(values.count)
        guard mean > 0 else { return 1.0 }

        // Coefficient of variation (lower = more balanced)
        let variance = values.reduce(0.0) { $0 + pow($1 - mean, 2) } / Double(values.count)
        let cv = sqrt(variance) / mean

        // Score: cv=0 → 1.0 (perfect balance), cv=1 → ~0.37, cv=2 → ~0.14
        let balanceScore = exp(-cv)

        // Bonus: penalize any day with more than maxMeetingsPerDay * avgDuration
        let maxMinutes = Double(context.preferences.maxMeetingsPerDay) * 60.0
        let overloadPenalty = values.reduce(0.0) { total, dayMinutes in
            total + max(0, dayMinutes - maxMinutes) / maxMinutes * 0.1
        }

        return max(0, balanceScore - overloadPenalty)
    }
}
