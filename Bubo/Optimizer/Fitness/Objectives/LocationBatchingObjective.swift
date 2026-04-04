import Foundation

// MARK: - Location Batching Objective

/// Rewards grouping events at the same physical location together in time,
/// minimizing the number of location transitions per day.
/// This is the spatial analog of ContextSwitchObjective.
struct LocationBatchingObjective: FitnessObjective {
    let name = "LocationBatching"
    var weight: Double

    init(weight: Double = 0.6) {
        self.weight = weight
    }

    func evaluate(chromosome: ScheduleChromosome, context: OptimizerContext) -> Double {
        let cal = context.calendar

        // Collect events with locations, grouped by day
        var eventsByDay: [Date: [(start: Date, location: EventLocation)]] = [:]

        for gene in chromosome.genes {
            guard let loc = gene.location else { continue }
            let day = cal.startOfDay(for: gene.startTime)
            eventsByDay[day, default: []].append((gene.startTime, loc))
        }
        for event in context.fixedEvents {
            guard let locationName = event.location, !locationName.isEmpty else { continue }
            if let loc = context.movableEvents.compactMap(\.location).first(where: { $0.name == locationName }) {
                let day = cal.startOfDay(for: event.startDate)
                eventsByDay[day, default: []].append((event.startDate, loc))
            }
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

            // Count location transitions (travel > 0.5 km)
            var transitions = 0
            for i in 0..<(sorted.count - 1) {
                let travel = sorted[i].location.travelMinutes(to: sorted[i + 1].location)
                if travel > 0 {
                    transitions += 1
                }
            }

            // Ideal: 0 transitions (all at same place) or 1 (go somewhere and come back)
            // Score degrades with more transitions
            let maxTransitions = sorted.count - 1
            let transitionRatio = maxTransitions > 0 ? Double(transitions) / Double(maxTransitions) : 0

            // 0 transitions → 1.0, all transitions → ~0.22
            let dayScore = exp(-transitionRatio * 1.5)

            // Bonus for location clusters (3+ consecutive events at same location)
            let clusterBonus = locationClusterBonus(sorted)

            totalScore += min(1.0, dayScore + clusterBonus)
            dayCount += 1
        }

        return dayCount > 0 ? totalScore / Double(dayCount) : 1.0
    }

    /// Bonus for having clusters of same-location events in sequence.
    private func locationClusterBonus(
        _ events: [(start: Date, location: EventLocation)]
    ) -> Double {
        var maxRun = 1
        var currentRun = 1

        for i in 1..<events.count {
            let travel = events[i - 1].location.travelMinutes(to: events[i].location)
            if travel == 0 {
                currentRun += 1
                maxRun = max(maxRun, currentRun)
            } else {
                currentRun = 1
            }
        }

        guard maxRun >= 3 else { return 0.0 }
        return min(0.1, Double(maxRun - 2) * 0.03)
    }
}
