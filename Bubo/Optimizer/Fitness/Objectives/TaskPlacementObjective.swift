import Foundation

// MARK: - #6 Task Placement Objective

/// Rewards placing tasks in their preferred time slots and grouping similar tasks.
/// Higher priority tasks should get better (preferred) slots.
struct TaskPlacementObjective: FitnessObjective {
    let name = "TaskPlacement"
    var weight: Double

    init(weight: Double = 1.0) {
        self.weight = weight
    }

    func evaluate(chromosome: ScheduleChromosome, context: OptimizerContext) -> Double {
        guard !chromosome.genes.isEmpty else { return 1.0 }

        let cal = context.calendar
        var totalScore = 0.0

        for gene in chromosome.genes {
            guard let event = context.movableEvents.first(where: { $0.id == gene.eventId }) else {
                continue
            }

            var score = 0.0

            // 1. Preferred time range match (0.4 weight)
            let hour = cal.component(.hour, from: gene.startTime)
            if let preferredRange = event.preferredHourRange {
                if preferredRange.contains(hour) {
                    score += 0.4
                } else {
                    let distance = min(
                        abs(hour - preferredRange.lowerBound),
                        abs(hour - preferredRange.upperBound)
                    )
                    score += 0.4 * max(0, 1.0 - Double(distance) * 0.15)
                }
            } else {
                score += 0.3  // no preference = neutral
            }

            // 2. Priority-weighted slot quality (0.3 weight)
            // Higher priority tasks should be at peak energy times
            let peakHour = context.preferences.peakEnergyHour
            let peakDistance = abs(hour - peakHour)
            let slotQuality = 1.0 / (1.0 + Double(peakDistance) * 0.1)
            score += 0.3 * (slotQuality * event.priority + (1 - event.priority) * 0.5)

            // 3. Not fragmented — task has enough continuous time (0.3 weight)
            let hasEnoughRoom = !isInterrupted(gene: gene, chromosome: chromosome, context: context)
            score += hasEnoughRoom ? 0.3 : 0.05

            totalScore += score
        }

        return totalScore / Double(chromosome.genes.count)
    }

    private func isInterrupted(
        gene: ScheduleGene,
        chromosome: ScheduleChromosome,
        context: OptimizerContext
    ) -> Bool {
        for event in context.fixedEvents {
            if event.startDate > gene.startTime && event.startDate < gene.endTime {
                return true
            }
        }
        for other in chromosome.genes where other.eventId != gene.eventId {
            if other.startTime > gene.startTime && other.startTime < gene.endTime {
                return true
            }
        }
        return false
    }
}
