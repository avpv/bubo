import Foundation

// MARK: - #2 Pomodoro Fit Objective

/// Evaluates how well Pomodoro sessions fit into the schedule.
/// Rewards: uninterrupted Pomodoro blocks, correct timing, no overlap with meetings.
struct PomodoroFitObjective: FitnessObjective {
    let name = "PomodoroFit"
    var weight: Double

    init(weight: Double = 0.8) {
        self.weight = weight
    }

    func evaluate(chromosome: ScheduleChromosome, context: OptimizerContext) -> Double {
        let pomodoroEvents = context.movableEvents.filter { $0.pomodoroConfig != nil }
        guard !pomodoroEvents.isEmpty else { return 1.0 } // No pomodoro = perfect

        var totalScore = 0.0

        for pomEvent in pomodoroEvents {
            guard let gene = chromosome.genes.first(where: { $0.eventId == pomEvent.id }),
                  let config = pomEvent.pomodoroConfig else { continue }

            var score = 0.0

            // 1. Check that the full Pomodoro session fits without interruption
            let totalDuration = pomodoroTotalDuration(config)
            let sessionEnd = gene.startTime.addingTimeInterval(totalDuration)

            let interruptions = countInterruptions(
                from: gene.startTime,
                to: sessionEnd,
                gene: gene,
                chromosome: chromosome,
                context: context
            )

            // Fewer interruptions = better
            let interruptionScore = 1.0 / (1.0 + Double(interruptions))
            score += interruptionScore * 0.4

            // 2. Prefer morning/preferred hours for Pomodoro (high cognitive demand)
            let cal = context.calendar
            let hour = cal.component(.hour, from: gene.startTime)
            let peakHour = context.preferences.peakEnergyHour
            let hourDistance = abs(hour - peakHour)
            let timeScore = 1.0 / (1.0 + Double(hourDistance) * 0.15)
            score += timeScore * 0.3

            // 3. Check that break durations match the rhythm
            // (breaks should have enough buffer)
            let hasBuffer = !hasAdjacentEvent(at: sessionEnd, chromosome: chromosome, context: context, bufferMinutes: config.breakMinutes)
            score += hasBuffer ? 0.3 : 0.1

            totalScore += score
        }

        return totalScore / Double(pomodoroEvents.count)
    }

    // MARK: - Helpers

    private func pomodoroTotalDuration(_ config: PomodoroConfig) -> TimeInterval {
        let workTime = Double(config.workMinutes * config.rounds) * 60
        let breakTime = Double(config.breakMinutes * (config.rounds - 1)) * 60
        let longBreak = Double(config.longBreakMinutes) * 60
        return workTime + breakTime + longBreak
    }

    private func countInterruptions(
        from start: Date,
        to end: Date,
        gene: ScheduleGene,
        chromosome: ScheduleChromosome,
        context: OptimizerContext
    ) -> Int {
        var count = 0
        // Check fixed events
        for event in context.fixedEvents {
            if event.startDate < end && event.endDate > start {
                count += 1
            }
        }
        // Check other movable events
        for other in chromosome.genes where other.eventId != gene.eventId {
            if other.startTime < end && other.endTime > start {
                count += 1
            }
        }
        return count
    }

    private func hasAdjacentEvent(
        at time: Date,
        chromosome: ScheduleChromosome,
        context: OptimizerContext,
        bufferMinutes: Int
    ) -> Bool {
        let bufferWindow = TimeInterval(bufferMinutes * 60)
        for event in context.fixedEvents {
            if abs(event.startDate.timeIntervalSince(time)) < bufferWindow {
                return true
            }
        }
        for gene in chromosome.genes {
            if abs(gene.startTime.timeIntervalSince(time)) < bufferWindow {
                return true
            }
        }
        return false
    }
}
