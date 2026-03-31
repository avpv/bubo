import Foundation

// MARK: - Chromosome Protocol

/// A generic chromosome for the genetic algorithm.
protocol Chromosome: Equatable {
    var fitness: Double { get set }

    /// Create a random chromosome within the given context.
    static func random(context: OptimizerContext) -> Self

    /// Produce two offspring via crossover with another chromosome.
    func crossover(with other: Self, context: OptimizerContext) -> (Self, Self)

    /// Apply random mutations at the given rate.
    mutating func mutate(rate: Double, context: OptimizerContext)
}

// MARK: - Schedule Chromosome

/// A chromosome representing a complete schedule assignment.
/// Each gene maps one movable event to a specific time slot.
struct ScheduleChromosome: Chromosome {
    var genes: [ScheduleGene]
    var fitness: Double = 0.0

    // MARK: - Random Initialization

    static func random(context: OptimizerContext) -> ScheduleChromosome {
        let cal = context.calendar
        let genes = context.movableEvents.map { event -> ScheduleGene in
            let start = randomStartTime(
                for: event,
                in: context.planningHorizon,
                workingHours: context.workingHours,
                calendar: cal
            )
            return ScheduleGene(
                eventId: event.id,
                startTime: start,
                duration: event.duration,
                context: event.context,
                energyCost: event.energyCost,
                priority: event.priority,
                isFocusBlock: event.isFocusBlock
            )
        }
        return ScheduleChromosome(genes: genes)
    }

    // MARK: - Crossover (Order-based)

    func crossover(with other: ScheduleChromosome, context: OptimizerContext) -> (ScheduleChromosome, ScheduleChromosome) {
        guard genes.count > 1 else { return (self, other) }

        let point = Int.random(in: 1..<genes.count)

        var child1Genes = Array(genes[..<point])
        var child2Genes = Array(other.genes[..<point])

        // Fill remaining genes from the other parent, matching by eventId
        for i in point..<genes.count {
            child1Genes.append(ScheduleGene(
                eventId: genes[i].eventId,
                startTime: other.genes[i].startTime,
                duration: genes[i].duration,
                context: genes[i].context,
                energyCost: genes[i].energyCost,
                priority: genes[i].priority,
                isFocusBlock: genes[i].isFocusBlock
            ))
            child2Genes.append(ScheduleGene(
                eventId: other.genes[i].eventId,
                startTime: genes[i].startTime,
                duration: other.genes[i].duration,
                context: other.genes[i].context,
                energyCost: other.genes[i].energyCost,
                priority: other.genes[i].priority,
                isFocusBlock: other.genes[i].isFocusBlock
            ))
        }

        return (
            ScheduleChromosome(genes: child1Genes),
            ScheduleChromosome(genes: child2Genes)
        )
    }

    // MARK: - Mutation

    mutating func mutate(rate: Double, context: OptimizerContext) {
        let cal = context.calendar
        for i in genes.indices {
            guard Double.random(in: 0...1) < rate else { continue }

            let event = context.movableEvents.first { $0.id == genes[i].eventId }
            let strategy = Int.random(in: 0...2)

            switch strategy {
            case 0:
                // Small time shift: +-30 min
                let shift = Double.random(in: -1800...1800)
                let newStart = genes[i].startTime.addingTimeInterval(shift)
                genes[i] = ScheduleGene(
                    eventId: genes[i].eventId,
                    startTime: clampToWorkingHours(newStart, duration: genes[i].duration, workingHours: context.workingHours, calendar: cal),
                    duration: genes[i].duration,
                    context: genes[i].context,
                    energyCost: genes[i].energyCost,
                    priority: genes[i].priority,
                    isFocusBlock: genes[i].isFocusBlock
                )
            case 1:
                // Move to different day within horizon
                let daysInHorizon = Int(context.planningHorizon.duration / 86400)
                guard daysInHorizon > 0 else { break }
                let dayOffset = Int.random(in: 0..<daysInHorizon)
                let newDay = cal.date(byAdding: .day, value: dayOffset, to: context.planningHorizon.start)!
                let hour = event?.preferredHourRange?.randomElement() ?? Int.random(in: context.workingHours)
                let newStart = cal.date(bySettingHour: hour, minute: Int.random(in: 0...3) * 15, second: 0, of: newDay)!
                genes[i] = ScheduleGene(
                    eventId: genes[i].eventId,
                    startTime: newStart,
                    duration: genes[i].duration,
                    context: genes[i].context,
                    energyCost: genes[i].energyCost,
                    priority: genes[i].priority,
                    isFocusBlock: genes[i].isFocusBlock
                )
            default:
                // Snap to nearest half-hour
                let timeInterval = genes[i].startTime.timeIntervalSinceReferenceDate
                let rounded = (timeInterval / 1800).rounded() * 1800
                genes[i] = ScheduleGene(
                    eventId: genes[i].eventId,
                    startTime: Date(timeIntervalSinceReferenceDate: rounded),
                    duration: genes[i].duration,
                    context: genes[i].context,
                    energyCost: genes[i].energyCost,
                    priority: genes[i].priority,
                    isFocusBlock: genes[i].isFocusBlock
                )
            }
        }
    }

    // MARK: - Helpers

    private static func randomStartTime(
        for event: OptimizableEvent,
        in horizon: DateInterval,
        workingHours: ClosedRange<Int>,
        calendar: Calendar
    ) -> Date {
        let daysInHorizon = max(1, Int(horizon.duration / 86400))
        let dayOffset = Int.random(in: 0..<daysInHorizon)
        let day = calendar.date(byAdding: .day, value: dayOffset, to: horizon.start)!

        let hourRange = event.preferredHourRange ?? workingHours
        let maxStartHour = max(hourRange.lowerBound, hourRange.upperBound - Int(event.duration / 3600))
        let hour = Int.random(in: hourRange.lowerBound...max(hourRange.lowerBound, maxStartHour))
        let minute = Int.random(in: 0...3) * 15

        return calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day)
            ?? horizon.start
    }
}

// MARK: - Free functions

func clampToWorkingHours(
    _ date: Date,
    duration: TimeInterval,
    workingHours: ClosedRange<Int>,
    calendar: Calendar
) -> Date {
    let hour = calendar.component(.hour, from: date)
    let endHour = hour + Int(duration / 3600)

    if hour < workingHours.lowerBound {
        return calendar.date(bySettingHour: workingHours.lowerBound, minute: 0, second: 0, of: date) ?? date
    }
    if endHour > workingHours.upperBound {
        let maxStart = workingHours.upperBound - Int(duration / 3600)
        let clampedHour = max(workingHours.lowerBound, maxStart)
        return calendar.date(bySettingHour: clampedHour, minute: 0, second: 0, of: date) ?? date
    }
    return date
}
