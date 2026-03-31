import Foundation

// MARK: - Mutation Strategy

enum MutationStrategy {
    case standard                  // random time shift per gene
    case adaptive(generation: Int) // decreasing rate over generations
    case guided(objectives: [any FitnessObjective]) // objective-aware
}

// MARK: - Mutation

/// Mutation operators for schedule chromosomes.
enum Mutation {

    /// Apply mutation to a chromosome.
    static func apply(
        to chromosome: inout ScheduleChromosome,
        rate: Double,
        strategy: MutationStrategy = .standard,
        context: OptimizerContext
    ) {
        switch strategy {
        case .standard:
            chromosome.mutate(rate: rate, context: context)

        case .adaptive(let generation):
            // Rate decreases as generations progress (simulated annealing flavor)
            let adaptiveRate = rate * max(0.1, 1.0 - Double(generation) / 500.0)
            chromosome.mutate(rate: adaptiveRate, context: context)

        case .guided(let objectives):
            guidedMutation(&chromosome, rate: rate, objectives: objectives, context: context)
        }
    }

    // MARK: - Guided Mutation

    /// Mutation that tries to improve the worst-scoring objective.
    private static func guidedMutation(
        _ chromosome: inout ScheduleChromosome,
        rate: Double,
        objectives: [any FitnessObjective],
        context: OptimizerContext
    ) {
        // Find the worst-scoring objective
        let scores = objectives.map { ($0.name, $0.evaluate(chromosome: chromosome, context: context)) }
        guard let worstObjective = scores.min(by: { $0.1 < $1.1 }) else {
            chromosome.mutate(rate: rate, context: context)
            return
        }

        let cal = context.calendar

        // Apply targeted mutation based on worst objective
        switch worstObjective.0 {
        case "FocusBlock":
            // Try to consolidate focus blocks into longer stretches
            mutateFocusBlocks(&chromosome, context: context, calendar: cal)

        case "Conflict":
            // Move conflicting events apart
            mutateResolveConflicts(&chromosome, context: context, calendar: cal)

        case "EnergyBalance":
            // Move high-energy tasks to peak hours
            mutateForEnergy(&chromosome, context: context, calendar: cal)

        default:
            chromosome.mutate(rate: rate, context: context)
        }
    }

    // MARK: - Targeted Mutations

    private static func mutateFocusBlocks(
        _ chromosome: inout ScheduleChromosome,
        context: OptimizerContext,
        calendar: Calendar
    ) {
        // Find focus block genes and try to group them
        let focusIndices = chromosome.genes.indices.filter { chromosome.genes[$0].isFocusBlock }
        guard focusIndices.count >= 2 else { return }

        // Move second focus block right after first
        let first = focusIndices[0]
        let second = focusIndices[1]
        let newStart = chromosome.genes[first].endTime

        chromosome.genes[second] = chromosome.genes[second].withStartTime(
            clampToWorkingHours(newStart, duration: chromosome.genes[second].duration, workingHours: context.workingHours, calendar: calendar)
        )
    }

    private static func mutateResolveConflicts(
        _ chromosome: inout ScheduleChromosome,
        context: OptimizerContext,
        calendar: Calendar
    ) {
        let allEvents = chromosome.genes.sorted { $0.startTime < $1.startTime }
        guard allEvents.count > 1 else { return }

        for i in 0..<(allEvents.count - 1) {
            if allEvents[i].endTime > allEvents[i + 1].startTime {
                // Conflict found — move the later event after the earlier one
                if let idx = chromosome.genes.firstIndex(where: { $0.eventId == allEvents[i + 1].eventId }) {
                    let newStart = allEvents[i].endTime.addingTimeInterval(Double(context.preferences.defaultBufferMinutes) * 60)
                    chromosome.genes[idx] = chromosome.genes[idx].withStartTime(
                        clampToWorkingHours(newStart, duration: chromosome.genes[idx].duration, workingHours: context.workingHours, calendar: calendar)
                    )
                }
            }
        }
    }

    private static func mutateForEnergy(
        _ chromosome: inout ScheduleChromosome,
        context: OptimizerContext,
        calendar: Calendar
    ) {
        // Move highest energy-cost tasks to peak hours
        guard let heaviestIdx = chromosome.genes.indices.max(by: {
            chromosome.genes[$0].energyCost < chromosome.genes[$1].energyCost
        }) else { return }

        let peakHour = context.preferences.peakEnergyHour
        let currentDay = calendar.startOfDay(for: chromosome.genes[heaviestIdx].startTime)
        if let newStart = calendar.date(bySettingHour: peakHour, minute: 0, second: 0, of: currentDay) {
            chromosome.genes[heaviestIdx] = chromosome.genes[heaviestIdx].withStartTime(newStart)
        }
    }
}
