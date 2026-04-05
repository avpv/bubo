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
        var evaluatedCount = 0

        for gene in chromosome.genes {
            guard let event = context.movableEvents.first(where: { $0.id == gene.eventId }) else {
                continue
            }
            evaluatedCount += 1

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
            // Higher priority tasks should be at peak energy times.
            // Story points boost the effective priority for slot placement:
            // high-SP tasks are pushed harder toward peak energy hours.
            let peakHour = context.preferences.peakEnergyHour
            let peakDistance = abs(hour - peakHour)
            let slotQuality = 1.0 / (1.0 + Double(peakDistance) * 0.1)
            let spBoost: Double = {
                guard let sp = gene.storyPoints, sp > 0 else { return 0.0 }
                return min(0.3, log(Double(sp)) / log(13.0) * 0.3)
            }()
            let effectivePriority = min(1.0, event.priority + spBoost)
            score += 0.3 * (slotQuality * effectivePriority + (1 - effectivePriority) * 0.5)

            // 3. Not fragmented — task has enough continuous time (0.3 weight)
            let hasEnoughRoom = !isInterrupted(gene: gene, chromosome: chromosome, context: context)
            score += hasEnoughRoom ? 0.3 : 0.05

            totalScore += score
        }

        return evaluatedCount > 0 ? totalScore / Double(evaluatedCount) : 1.0
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
