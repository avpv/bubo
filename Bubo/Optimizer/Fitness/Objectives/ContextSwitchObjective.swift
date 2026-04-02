import Foundation

// MARK: - #22 Context Switch Objective

/// Penalizes frequent context switches between different projects/categories.
/// Rewards grouping events with the same context together.
struct ContextSwitchObjective: FitnessObjective {
    let name = "ContextSwitch"
    var weight: Double

    init(weight: Double = 0.7) {
        self.weight = weight
    }

    func evaluate(chromosome: ScheduleChromosome, context: OptimizerContext) -> Double {
        let cal = context.calendar

        // Group all events by day with their context
        var eventsByDay: [Date: [(start: Date, end: Date, context: String?)]] = [:]

        for event in context.fixedEvents {
            let day = cal.startOfDay(for: event.startDate)
            eventsByDay[day, default: []].append((event.startDate, event.endDate, event.resolvedContext()))
        }
        for gene in chromosome.genes {
            let day = cal.startOfDay(for: gene.startTime)
            eventsByDay[day, default: []].append((gene.startTime, gene.endTime, gene.context))
        }

        guard !eventsByDay.isEmpty else { return 1.0 }

        var totalScore = 0.0
        var dayCount = 0

        for (_, events) in eventsByDay {
            guard events.count > 1 else {
                totalScore += 1.0
                dayCount += 1
                continue
            }

            let sorted = events.sorted { $0.start < $1.start }

            // Count context switches
            var switches = 0
            for i in 0..<(sorted.count - 1) {
                let ctx1 = sorted[i].context ?? "__none__"
                let ctx2 = sorted[i + 1].context ?? "__none__"
                if ctx1 != ctx2 {
                    switches += 1
                }
            }

            // Maximum possible switches = events - 1
            let maxSwitches = sorted.count - 1
            let switchRatio = maxSwitches > 0 ? Double(switches) / Double(maxSwitches) : 0

            // Score: fewer switches = better
            // switchRatio 0 = 1.0, switchRatio 1 = ~0.37
            let dayScore = exp(-switchRatio * 1.5)

            // Bonus: check for context clusters (3+ same-context events in a row)
            let clusterBonus = contextClusterBonus(sorted)

            totalScore += min(1.0, dayScore + clusterBonus)
            dayCount += 1
        }

        return dayCount > 0 ? totalScore / Double(dayCount) : 0.5
    }

    /// Bonus for having clusters of same-context events.
    /// Scales with cluster size: 3 events → 0.05, 4 → 0.08, 5+ → 0.1.
    private func contextClusterBonus(
        _ events: [(start: Date, end: Date, context: String?)]
    ) -> Double {
        var maxRun = 1
        var currentRun = 1
        var clusterCount = 0

        for i in 1..<events.count {
            let prev = events[i - 1].context ?? "__none__"
            let curr = events[i].context ?? "__none__"
            if prev == curr {
                currentRun += 1
                maxRun = max(maxRun, currentRun)
            } else {
                if currentRun >= 3 { clusterCount += 1 }
                currentRun = 1
            }
        }
        if currentRun >= 3 { clusterCount += 1 }

        guard maxRun >= 3 else { return 0.0 }

        // Scaled bonus: larger clusters and more clusters = better
        let sizeBonus = min(0.1, Double(maxRun - 2) * 0.025)  // 3→0.025, 4→0.05, 6+→0.1
        let countBonus = min(0.05, Double(clusterCount - 1) * 0.025)  // extra clusters add up to 0.05
        return sizeBonus + countBonus
    }
}
