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

        for event in eventsWithDeadlines {
            guard let gene = chromosome.genes.first(where: { $0.eventId == event.id }),
                  let deadline = event.deadline else { continue }

            let timeUntilDeadline = deadline.timeIntervalSince(gene.endTime)

            if timeUntilDeadline < 0 {
                // Past deadline — heavy penalty proportional to lateness
                let hoursLate = -timeUntilDeadline / 3600
                totalScore += max(0, -hoursLate * 0.1)  // negative contribution
                continue
            }

            // Time available from now to deadline
            let totalAvailable = deadline.timeIntervalSince(context.planningHorizon.start)
            guard totalAvailable > 0 else {
                totalScore += 0.5
                continue
            }

            // How early is the task scheduled relative to the deadline?
            let earlinessRatio = timeUntilDeadline / totalAvailable // 0 = at deadline, 1 = at start

            // Score: reward earlier scheduling (anti-procrastination)
            // Use a curve that rewards moderate earliness but doesn't over-reward very early
            let earlyScore = 1.0 - exp(-earlinessRatio * 3.0)

            // Priority multiplier: high priority tasks should be scheduled earlier
            let priorityBonus = earlyScore * event.priority * 0.2

            // Penalty for cramming: if multiple deadline tasks on same day
            let crammingPenalty = crammingFactor(for: gene, chromosome: chromosome, context: context)

            totalScore += min(1.0, earlyScore + priorityBonus - crammingPenalty)
        }

        return max(0, totalScore / Double(eventsWithDeadlines.count))
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
