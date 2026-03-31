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
struct ScheduleChromosome: Chromosome, Sendable {
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
                title: event.title,
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

        // Fill remaining genes from the other parent — swap time slots
        for i in point..<genes.count {
            child1Genes.append(genes[i].withStartTime(other.genes[i].startTime))
            child2Genes.append(other.genes[i].withStartTime(genes[i].startTime))
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
                genes[i] = genes[i].withStartTime(
                    clampToWorkingHours(newStart, duration: genes[i].duration, workingHours: context.workingHours, calendar: cal)
                )
            case 1:
                // Move to different day within horizon
                let daysInHorizon = context.calendar.dateComponents(
                    [.day], from: context.planningHorizon.start, to: context.planningHorizon.end
                ).day ?? 1
                guard daysInHorizon > 0 else { break }
                let dayOffset = Int.random(in: 0..<daysInHorizon)
                let newDay = cal.date(byAdding: .day, value: dayOffset, to: context.planningHorizon.start)!
                let hour = event?.preferredHourRange?.randomElement() ?? Int.random(in: context.workingHours)
                let rawStart = cal.date(bySettingHour: hour, minute: Int.random(in: 0...3) * 15, second: 0, of: newDay)!
                genes[i] = genes[i].withStartTime(
                    clampToWorkingHours(rawStart, duration: genes[i].duration, workingHours: context.workingHours, calendar: cal)
                )
            default:
                // Snap to nearest half-hour
                let timeInterval = genes[i].startTime.timeIntervalSinceReferenceDate
                let rounded = (timeInterval / 1800).rounded() * 1800
                let snapped = Date(timeIntervalSinceReferenceDate: rounded)
                genes[i] = genes[i].withStartTime(
                    clampToWorkingHours(snapped, duration: genes[i].duration, workingHours: context.workingHours, calendar: cal)
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
        let daysInHorizon = max(1, calendar.dateComponents([.day], from: horizon.start, to: horizon.end).day ?? 1)
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
    let day = calendar.startOfDay(for: date)
    guard let workStart = calendar.date(bySettingHour: workingHours.lowerBound, minute: 0, second: 0, of: day),
          let workEnd = calendar.date(bySettingHour: workingHours.upperBound, minute: 0, second: 0, of: day) else {
        return date
    }

    // Clamp start so event doesn't begin before working hours
    var clamped = max(date, workStart)

    // Clamp start so event doesn't end after working hours
    let latestStart = workEnd.addingTimeInterval(-duration)
    if latestStart >= workStart {
        clamped = min(clamped, latestStart)
    } else {
        // Duration exceeds working hours — start at workStart
        clamped = workStart
    }

    return clamped
}
