import Foundation

// MARK: - #5 Conflict Objective

/// Penalizes schedules where movable events overlap with fixed or other movable events.
/// This is a soft objective complement to the hard NoOverlapConstraint —
/// it provides gradient information even for near-conflicts.
struct ConflictObjective: FitnessObjective {
    let name = "Conflict"
    var weight: Double

    init(weight: Double = 10.0) {
        self.weight = weight
    }

    func evaluate(chromosome: ScheduleChromosome, context: OptimizerContext) -> Double {
        var allEvents: [(id: String, start: Date, end: Date)] = []

        for event in context.fixedEvents {
            allEvents.append((event.id, event.startDate, event.endDate))
        }
        for gene in chromosome.genes {
            allEvents.append((gene.eventId, gene.startTime, gene.endTime))
        }

        allEvents.sort { $0.start < $1.start }

        var totalOverlapMinutes = 0.0
        var nearMissMinutes = 0.0

        for i in 0..<allEvents.count {
            for j in (i + 1)..<allEvents.count {
                guard allEvents[j].start < allEvents[i].end else { break }

                // Direct overlap
                let overlapEnd = min(allEvents[i].end, allEvents[j].end)
                let overlapDuration = overlapEnd.timeIntervalSince(allEvents[j].start) / 60
                totalOverlapMinutes += max(0, overlapDuration)
            }

            // Near-miss: events within 5 minutes (creates stress)
            if i + 1 < allEvents.count {
                let gap = allEvents[i + 1].start.timeIntervalSince(allEvents[i].end) / 60
                if gap > 0 && gap < 5 {
                    nearMissMinutes += (5 - gap)
                }
            }
        }

        // Score: 1.0 = no conflicts, approaches 0.0 with more overlap
        let overlapPenalty = totalOverlapMinutes * 0.1
        let nearMissPenalty = nearMissMinutes * 0.02

        return max(0, 1.0 - overlapPenalty - nearMissPenalty)
    }
}
