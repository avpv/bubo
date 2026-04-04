import Foundation

// MARK: - Travel Time Objective

/// Penalizes scheduling events at distant locations with insufficient travel time between them.
/// Rewards sequences that leave adequate gaps for commuting.
/// Events without a location are treated as "remote/home" and incur zero travel cost.
struct TravelTimeObjective: FitnessObjective {
    let name = "TravelTime"
    var weight: Double

    init(weight: Double = 0.8) {
        self.weight = weight
    }

    func evaluate(chromosome: ScheduleChromosome, context: OptimizerContext) -> Double {
        let cal = context.calendar

        // Collect all events (fixed + movable) with location info, grouped by day
        var eventsByDay: [Date: [(start: Date, end: Date, location: EventLocation?)]] = [:]

        for event in context.fixedEvents {
            let day = cal.startOfDay(for: event.startDate)
            let loc = locationForFixedEvent(event, context: context)
            eventsByDay[day, default: []].append((event.startDate, event.endDate, loc))
        }
        for gene in chromosome.genes {
            let day = cal.startOfDay(for: gene.startTime)
            eventsByDay[day, default: []].append((gene.startTime, gene.endTime, gene.location))
        }

        guard !eventsByDay.isEmpty else { return 1.0 }

        var totalScore = 0.0
        var pairCount = 0

        for (_, events) in eventsByDay {
            let sorted = events.sorted { $0.start < $1.start }

            for i in 0..<(sorted.count - 1) {
                let current = sorted[i]
                let next = sorted[i + 1]

                guard let loc1 = current.location, let loc2 = next.location else {
                    // No location on one or both — no travel penalty
                    continue
                }

                let requiredTravel = loc1.travelMinutes(to: loc2)
                guard requiredTravel > 0 else {
                    // Same location — perfect
                    pairCount += 1
                    totalScore += 1.0
                    continue
                }

                let gapMinutes = next.start.timeIntervalSince(current.end) / 60

                let pairScore: Double
                if gapMinutes >= requiredTravel {
                    // Enough time to travel
                    pairScore = 1.0
                } else if gapMinutes < 0 {
                    // Overlap with travel needed — very bad
                    pairScore = 0.0
                } else {
                    // Partial: linear interpolation
                    pairScore = gapMinutes / requiredTravel
                }

                totalScore += pairScore
                pairCount += 1
            }
        }

        return pairCount > 0 ? totalScore / Double(pairCount) : 1.0
    }

    /// Try to find an EventLocation for a fixed CalendarEvent by matching it
    /// to a movable event with the same location name.
    private func locationForFixedEvent(
        _ event: CalendarEvent,
        context: OptimizerContext
    ) -> EventLocation? {
        guard let locationName = event.location, !locationName.isEmpty else { return nil }
        // Look up matching location from movable events that share the same location name
        return context.movableEvents
            .compactMap(\.location)
            .first { $0.name == locationName }
    }
}
