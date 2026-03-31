import Foundation

// MARK: - #16 Multi-Person Objective

/// Rewards scheduling events when all required participants are available.
/// Uses participant availability data from the context.
struct MultiPersonObjective: FitnessObjective {
    let name = "MultiPerson"
    var weight: Double

    init(weight: Double = 5.0) {
        self.weight = weight
    }

    func evaluate(chromosome: ScheduleChromosome, context: OptimizerContext) -> Double {
        let eventsWithParticipants = context.movableEvents.filter { !$0.requiredParticipants.isEmpty }
        guard !eventsWithParticipants.isEmpty else { return 1.0 }

        var totalScore = 0.0

        for event in eventsWithParticipants {
            guard let gene = chromosome.genes.first(where: { $0.eventId == event.id }) else {
                continue
            }

            let eventInterval = DateInterval(start: gene.startTime, duration: gene.duration)
            var participantScore = 0.0

            for participant in event.requiredParticipants {
                if let freeSlots = context.participantAvailability[participant] {
                    // Check if any free slot covers the event
                    let isAvailable = freeSlots.contains { slot in
                        slot.start <= eventInterval.start && slot.end >= eventInterval.end
                    }
                    if isAvailable {
                        participantScore += 1.0
                    } else {
                        // Partial credit: how much of the event overlaps with free time
                        let overlapMinutes = freeSlots.reduce(0.0) { total, slot in
                            let overlapStart = max(slot.start, eventInterval.start)
                            let overlapEnd = min(slot.end, eventInterval.end)
                            return total + max(0, overlapEnd.timeIntervalSince(overlapStart)) / 60
                        }
                        let eventMinutes = event.duration / 60
                        guard eventMinutes > 0 else { participantScore += 0.5; continue }
                        participantScore += min(1.0, overlapMinutes / eventMinutes) * 0.5
                    }
                } else {
                    // No availability data — assume available (don't penalize)
                    participantScore += 0.8
                }
            }

            // Average across all participants
            let avgScore = participantScore / Double(event.requiredParticipants.count)

            // Bonus for reasonable meeting times (not too early/late)
            let cal = context.calendar
            let hour = cal.component(.hour, from: gene.startTime)
            let reasonableHours = context.workingHours
            let timeBonus: Double = reasonableHours.contains(hour) ? 0.1 : 0.0

            totalScore += min(1.0, avgScore + timeBonus)
        }

        return totalScore / Double(eventsWithParticipants.count)
    }
}
