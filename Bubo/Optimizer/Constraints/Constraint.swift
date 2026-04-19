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
        // Only count overlaps where at least one side is a movable gene the
        // chromosome placed. Fixed-vs-fixed clashes come from the user's
        // calendar and are outside the GA's control — penalising them makes
        // `fitness < 0.1` unreachable for every chromosome (including "drop
        // all"), which surfaces as a false "Not enough room" modal.
        let movable = chromosome.genes
            .filter { $0.isIncluded }
            .map { (start: $0.startTime, end: $0.endTime) }

        guard !movable.isEmpty else { return 0 }

        var overlapMinutes = 0.0

        // movable vs fixed
        for m in movable {
            for f in context.fixedEvents {
                let overlapStart = max(m.start, f.startDate)
                let overlapEnd = min(m.end, f.endDate)
                overlapMinutes += max(0, overlapEnd.timeIntervalSince(overlapStart)) / 60.0
            }
        }

        // movable vs movable
        for i in 0..<movable.count {
            for j in (i + 1)..<movable.count {
                let a = movable[i]
                let b = movable[j]
                let overlapStart = max(a.start, b.start)
                let overlapEnd = min(a.end, b.end)
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

        for gene in chromosome.genes where gene.isIncluded {
            let day = cal.startOfDay(for: gene.startTime)
            guard let workStart = cal.date(bySettingHour: context.workingHours.lowerBound, minute: 0, second: 0, of: day),
                  let workEnd = cal.date(bySettingHour: context.workingHours.upperBound, minute: 0, second: 0, of: day) else {
                continue
            }

            // Minutes before working hours start
            if gene.startTime < workStart {
                totalViolation += workStart.timeIntervalSince(gene.startTime) / 60
            }
            // Minutes after working hours end
            if gene.endTime > workEnd {
                totalViolation += gene.endTime.timeIntervalSince(workEnd) / 60
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
        for gene in chromosome.genes where gene.isIncluded {
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
        for gene in chromosome.genes where gene.isIncluded {
            guard let event = context.movableEvents.first(where: { $0.id == gene.eventId }),
                  let deadline = event.deadline else { continue }
            if gene.endTime > deadline {
                totalViolation += gene.endTime.timeIntervalSince(deadline) / 60
            }
        }
        return totalViolation
    }
}

// MARK: - Earliest Start Constraint (Hard)

/// Events with an earliestStart must not be scheduled before that time.
struct EarliestStartConstraint: ScheduleConstraint {
    let name = "EarliestStart"
    let isHard = true

    func penalty(for chromosome: ScheduleChromosome, context: OptimizerContext) -> Double {
        var totalViolation = 0.0
        for gene in chromosome.genes where gene.isIncluded {
            guard let event = context.movableEvents.first(where: { $0.id == gene.eventId }),
                  let earliest = event.earliestStart else { continue }
            if gene.startTime < earliest {
                totalViolation += earliest.timeIntervalSince(gene.startTime) / 60
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
        for gene in chromosome.genes where gene.isIncluded {
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

        for gene in chromosome.genes where gene.isIncluded {
            let day = cal.startOfDay(for: gene.startTime)
            guard let lunchStartTime = cal.date(bySettingHour: lunchStart, minute: 0, second: 0, of: day),
                  let lunchEndTime = cal.date(bySettingHour: lunchEnd, minute: 0, second: 0, of: day) else {
                continue
            }

            // Calculate actual overlap in minutes
            let overlapStart = max(gene.startTime, lunchStartTime)
            let overlapEnd = min(gene.endTime, lunchEndTime)
            let overlapMinutes = max(0, overlapEnd.timeIntervalSince(overlapStart)) / 60

            if overlapMinutes > 0 {
                penalty += overlapMinutes * 0.1
            }
        }
        return penalty
    }
}

// MARK: - Task Dependency Constraint (Hard)

/// Tasks with dependencies must be scheduled after all their prerequisites finish.
struct TaskDependencyConstraint: ScheduleConstraint {
    let name = "TaskDependency"
    let isHard = true

    func penalty(for chromosome: ScheduleChromosome, context: OptimizerContext) -> Double {
        var totalViolation = 0.0

        for gene in chromosome.genes where gene.isIncluded {
            guard let event = context.movableEvents.first(where: { $0.id == gene.eventId }),
                  !event.dependsOn.isEmpty else { continue }

            for depId in event.dependsOn {
                // Dependency may be in movable genes or in fixed events
                if let depGene = chromosome.genes.first(where: { $0.eventId == depId && $0.isIncluded }) {
                    // Movable dependency: this task must start after dependency ends
                    if gene.startTime < depGene.endTime {
                        totalViolation += depGene.endTime.timeIntervalSince(gene.startTime) / 60
                    }
                } else if let depFixed = context.fixedEvents.first(where: { $0.id == depId }) {
                    // Fixed dependency: this task must start after fixed event ends
                    if gene.startTime < depFixed.endDate {
                        totalViolation += depFixed.endDate.timeIntervalSince(gene.startTime) / 60
                    }
                }
                // If dependency not found in schedule, skip (already completed or external)
            }
        }
        return totalViolation
    }
}

// MARK: - Atomic Group Constraint (Soft)

/// Events sharing a non-nil `groupId` should be included-or-dropped together.
/// Produced by `IntentCompiler.splitOversizedBacklogTasks` when a long backlog
/// task is chunked across days — without this, the GA could include chunks
/// 1 and 3 while dropping 2, leaving a half-scheduled task.
///
/// Soft so the GA can still settle on a partial plan when the full group
/// genuinely doesn't fit (rather than silently dropping everything and
/// hiding the task from the user). The penalty is small relative to the
/// value lost by dropping a chunk via `TaskInclusion`, so the preference
/// ordering is: `all-in > partial > all-out` only when `all-in` is
/// infeasible; otherwise `all-in > all-out > partial`.
struct AtomicGroupConstraint: ScheduleConstraint {
    let name = "AtomicGroup"
    let isHard = false

    func penalty(for chromosome: ScheduleChromosome, context: OptimizerContext) -> Double {
        // Build a (groupId → [eventId]) map once per evaluation. Events
        // without a `groupId` are ignored — this constraint only speaks to
        // explicitly-grouped splits.
        var groups: [String: [String]] = [:]
        for event in context.movableEvents {
            guard let gid = event.groupId else { continue }
            groups[gid, default: []].append(event.id)
        }
        guard !groups.isEmpty else { return 0 }

        let inclusion: [String: Bool] = Dictionary(
            chromosome.genes.map { ($0.eventId, $0.isIncluded) },
            uniquingKeysWith: { first, _ in first }
        )

        var totalViolation = 0.0
        for (_, memberIds) in groups {
            var included = 0
            var excluded = 0
            for id in memberIds {
                if inclusion[id] == true { included += 1 } else { excluded += 1 }
            }
            // Penalty scales with the minority count — number of flips
            // needed to make the group uniform. As a soft constraint this
            // enters `FitnessEvaluator.evaluate` as `softPenalty * 0.01`
            // in a multiplicative factor, so a 1-chunk mismatch trims
            // ~1% off the score — a real but survivable nudge.
            if included > 0 && excluded > 0 {
                totalViolation += Double(min(included, excluded))
            }
        }
        return totalViolation
    }
}
