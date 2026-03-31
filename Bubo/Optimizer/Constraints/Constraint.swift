import Foundation

// MARK: - Schedule Constraint Protocol

/// A constraint that evaluates a schedule chromosome.
/// Hard constraints return 0 on violation (infeasible).
/// Soft constraints return a penalty score (0 = no penalty, higher = worse).
protocol ScheduleConstraint {
    var name: String { get }
    var isHard: Bool { get }

    /// Evaluate the constraint. Returns 0.0 for no violation, positive for violations.
    func penalty(for chromosome: ScheduleChromosome, context: OptimizerContext) -> Double
}

// MARK: - No Overlap Constraint (Hard)

/// Events must not overlap with each other or with fixed events.
struct NoOverlapConstraint: ScheduleConstraint {
    let name = "NoOverlap"
    let isHard = true

    func penalty(for chromosome: ScheduleChromosome, context: OptimizerContext) -> Double {
        var allEvents: [(start: Date, end: Date)] = []

        // Add fixed events
        for event in context.fixedEvents {
            allEvents.append((event.startDate, event.endDate))
        }
        // Add movable events from chromosome
        for gene in chromosome.genes {
            allEvents.append((gene.startTime, gene.endTime))
        }

        allEvents.sort { $0.start < $1.start }

        var overlapMinutes = 0.0
        for i in 0..<(allEvents.count - 1) {
            for j in (i + 1)..<allEvents.count {
                guard allEvents[j].start < allEvents[i].end else { break }
                let overlapEnd = min(allEvents[i].end, allEvents[j].end)
                let overlapStart = allEvents[j].start
                overlapMinutes += max(0, overlapEnd.timeIntervalSince(overlapStart)) / 60.0
            }
        }
        return overlapMinutes
    }
}

// MARK: - Working Hours Constraint (Hard)

/// Events must fall within working hours.
struct WorkingHoursConstraint: ScheduleConstraint {
    let name = "WorkingHours"
    let isHard = true

    func penalty(for chromosome: ScheduleChromosome, context: OptimizerContext) -> Double {
        let cal = context.calendar
        var totalViolation = 0.0

        for gene in chromosome.genes {
            let startHour = cal.component(.hour, from: gene.startTime)
            let endHour = cal.component(.hour, from: gene.endTime)
            let endMinute = cal.component(.minute, from: gene.endTime)
            let effectiveEndHour = endMinute > 0 ? endHour + 1 : endHour

            if startHour < context.workingHours.lowerBound {
                totalViolation += Double(context.workingHours.lowerBound - startHour) * 60
            }
            if effectiveEndHour > context.workingHours.upperBound {
                totalViolation += Double(effectiveEndHour - context.workingHours.upperBound) * 60
            }
        }
        return totalViolation
    }
}

// MARK: - Planning Horizon Constraint (Hard)

/// Events must fall within the planning horizon.
struct PlanningHorizonConstraint: ScheduleConstraint {
    let name = "PlanningHorizon"
    let isHard = true

    func penalty(for chromosome: ScheduleChromosome, context: OptimizerContext) -> Double {
        var totalViolation = 0.0
        for gene in chromosome.genes {
            if gene.startTime < context.planningHorizon.start {
                totalViolation += context.planningHorizon.start.timeIntervalSince(gene.startTime) / 60
            }
            if gene.endTime > context.planningHorizon.end {
                totalViolation += gene.endTime.timeIntervalSince(context.planningHorizon.end) / 60
            }
        }
        return totalViolation
    }
}

// MARK: - Deadline Constraint (Hard)

/// Events with deadlines must be scheduled before their deadline.
struct DeadlineConstraint: ScheduleConstraint {
    let name = "Deadline"
    let isHard = true

    func penalty(for chromosome: ScheduleChromosome, context: OptimizerContext) -> Double {
        var totalViolation = 0.0
        for gene in chromosome.genes {
            guard let event = context.movableEvents.first(where: { $0.id == gene.eventId }),
                  let deadline = event.deadline else { continue }
            if gene.endTime > deadline {
                totalViolation += gene.endTime.timeIntervalSince(deadline) / 60
            }
        }
        return totalViolation
    }
}

// MARK: - Max Meetings Per Day Constraint (Soft)

/// Soft limit on the number of meetings per day.
struct MaxMeetingsPerDayConstraint: ScheduleConstraint {
    let name = "MaxMeetingsPerDay"
    let isHard = false

    func penalty(for chromosome: ScheduleChromosome, context: OptimizerContext) -> Double {
        let cal = context.calendar
        var eventsByDay: [Date: Int] = [:]

        // Count fixed events per day
        for event in context.fixedEvents {
            let day = cal.startOfDay(for: event.startDate)
            eventsByDay[day, default: 0] += 1
        }
        // Count movable events per day
        for gene in chromosome.genes {
            let day = cal.startOfDay(for: gene.startTime)
            eventsByDay[day, default: 0] += 1
        }

        let maxPerDay = context.preferences.maxMeetingsPerDay
        var penalty = 0.0
        for (_, count) in eventsByDay {
            if count > maxPerDay {
                penalty += Double(count - maxPerDay) * 10
            }
        }
        return penalty
    }
}

// MARK: - Lunch Window Constraint (Soft)

/// Prefer to keep the lunch window free.
struct LunchWindowConstraint: ScheduleConstraint {
    let name = "LunchWindow"
    let isHard = false

    func penalty(for chromosome: ScheduleChromosome, context: OptimizerContext) -> Double {
        let cal = context.calendar
        let lunchStart = context.preferences.lunchWindowStart
        let lunchEnd = context.preferences.lunchWindowEnd
        var penalty = 0.0

        for gene in chromosome.genes {
            let startHour = cal.component(.hour, from: gene.startTime)
            let endHour = cal.component(.hour, from: gene.endTime)

            // Check if event overlaps with lunch window
            if startHour < lunchEnd && endHour > lunchStart {
                let overlapStart = max(startHour, lunchStart)
                let overlapEnd = min(endHour, lunchEnd)
                penalty += Double(overlapEnd - overlapStart) * 5
            }
        }
        return penalty
    }
}
