import Foundation

// MARK: - #21 Deadline Objective

/// Rewards scheduling tasks well before their deadlines (no cramming).
/// Higher priority tasks get larger early-completion bonuses.
struct DeadlineObjective: FitnessObjective {
    let name = "Deadline"
    var weight: Double

    init(weight: Double = 3.0) {
        self.weight = weight
    }

    func evaluate(chromosome: ScheduleChromosome, context: OptimizerContext) -> Double {
        let eventsWithDeadlines = context.movableEvents.filter { $0.deadline != nil }
        guard !eventsWithDeadlines.isEmpty else { return 1.0 }

        var totalScore = 0.0
        var evaluatedCount = 0

        for event in eventsWithDeadlines {
            guard let gene = chromosome.genes.first(where: { $0.eventId == event.id }),
                  let deadline = event.deadline else { continue }
            evaluatedCount += 1

            let timeUntilDeadline = deadline.timeIntervalSince(gene.endTime)

            if timeUntilDeadline < 0 {
                // Past deadline — zero score (hard fail for this event)
                totalScore += 0.0
                continue
            }

            // Total window from event start to deadline
            let totalWindow = deadline.timeIntervalSince(gene.startTime)
            guard totalWindow > 0 else {
                totalScore += 0.0
                continue
            }

            // Fraction of buffer remaining: 1.0 = scheduled at the very start, 0.0 = at deadline
            let bufferFraction = timeUntilDeadline / totalWindow

            // Smooth reward curve: more buffer = higher score
            // bufferFraction 0.0 → score ~0.0 (cramming)
            // bufferFraction 0.5 → score ~0.78
            // bufferFraction 0.9 → score ~0.93
            let earlyScore = 1.0 - exp(-bufferFraction * 3.0)

            // Priority multiplier: high priority tasks benefit more from early scheduling
            let priorityBonus = earlyScore * event.priority * 0.2

            // Penalty for cramming: if multiple deadline tasks on same day
            let crammingPenalty = crammingFactor(for: gene, chromosome: chromosome, context: context)

            totalScore += max(0, min(1.0, earlyScore + priorityBonus - crammingPenalty))
        }

        return evaluatedCount > 0 ? max(0, totalScore / Double(evaluatedCount)) : 1.0
    }

    /// Returns a penalty if too many deadline tasks are scheduled on the same day.
    private func crammingFactor(
        for gene: ScheduleGene,
        chromosome: ScheduleChromosome,
        context: OptimizerContext
    ) -> Double {
        let cal = context.calendar
        let day = cal.startOfDay(for: gene.startTime)

        let deadlineTasksOnSameDay = chromosome.genes.filter { other in
            guard other.eventId != gene.eventId else { return false }
            let otherDay = cal.startOfDay(for: other.startTime)
            guard otherDay == day else { return false }
            // Check if this event has a deadline
            return context.movableEvents.first { $0.id == other.eventId }?.deadline != nil
        }

        // Penalty increases with number of deadline tasks on same day
        return Double(deadlineTasksOnSameDay.count) * 0.05
    }
}
