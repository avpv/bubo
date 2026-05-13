import Foundation

// MARK: - Schedule Constraint Protocol

/// A constraint that evaluates a schedule chromosome.
/// Hard constraints return 0 on violation (infeasible).
/// Soft constraints return a penalty score (0 = no penalty, higher = worse).
public protocol ScheduleConstraint {
    var name: String { get }
    var isHard: Bool { get }

    /// Evaluate the constraint. Returns 0.0 for no violation, positive for violations.
    func penalty(for chromosome: ScheduleChromosome, context: OptimizerContext) -> Double
}

// MARK: - No Overlap Constraint (Hard)

/// Events must not overlap with each other or with fixed events.
///
/// Implementation: merge movable and fixed intervals into a single
/// list, sort by start time, then run a single left-to-right sweep
/// maintaining the set of currently-active intervals (those that
/// haven't ended yet at the current sweep position).
///
/// Complexity:
///   • Sort:  O(N log N) where N = movable + fixed
///   • Sweep: O(N · k) where k is the maximum simultaneous overlap
///     depth — for a realistic schedule k ≤ 3, so the sweep is
///     effectively O(N). Pathological inputs where every interval
///     overlaps every other (early random GA generations) degrade
///     to O(N²), matching the legacy pair-scan behaviour.
///
/// Semantics: identical to the previous O(N² + M·F) pair-scanner.
/// Fixed-vs-fixed overlaps are skipped (they come from the user's
/// calendar and the GA can't change them); movable-vs-movable and
/// movable-vs-fixed overlaps are counted once each, and the total
/// overlap is returned in minutes.
public struct NoOverlapConstraint: ScheduleConstraint {
    public let name = "NoOverlap"
    public let isHard = true

    private struct TaggedInterval {
        let start: Date
        let end: Date
        let isMovable: Bool
    }

    public func penalty(for chromosome: ScheduleChromosome, context: OptimizerContext) -> Double {
        let movableCount = chromosome.genes.lazy.filter { $0.isIncluded }.count
        guard movableCount > 0 else { return 0 }

        var intervals: [TaggedInterval] = []
        intervals.reserveCapacity(movableCount + context.fixedEvents.count)
        for gene in chromosome.genes where gene.isIncluded {
            intervals.append(TaggedInterval(
                start: gene.startTime,
                end: gene.endTime,
                isMovable: true
            ))
        }
        for ev in context.fixedEvents {
            intervals.append(TaggedInterval(
                start: ev.startDate,
                end: ev.endDate,
                isMovable: false
            ))
        }
        intervals.sort { $0.start < $1.start }

        // Sweep. `active` holds intervals whose end > current sweep
        // position. A naïve scan-and-remove keeps `active` small for
        // realistic schedules (few concurrent events). We drop entries
        // by copying forward rather than `removeAll(where:)` so the
        // inner loop stays allocation-free on the hot path.
        var active: [TaggedInterval] = []
        active.reserveCapacity(8)
        var overlapMinutes = 0.0

        for interval in intervals {
            // Evict ended intervals. Equivalent to `active.removeAll
            // { $0.end <= interval.start }` but avoids the closure.
            if !active.isEmpty {
                var write = 0
                for read in 0..<active.count {
                    if active[read].end > interval.start {
                        if write != read { active[write] = active[read] }
                        write += 1
                    }
                }
                active.removeLast(active.count - write)
            }

            // Add overlap contribution against each still-active
            // interval. Fixed-vs-fixed is the only pair we skip.
            for other in active {
                if !interval.isMovable && !other.isMovable { continue }
                // `other.start <= interval.start` because intervals are
                // sorted by start, so the overlap start is always
                // `interval.start`. Overlap end is the earlier of the
                // two end times.
                let overlapEnd = min(interval.end, other.end)
                let seconds = overlapEnd.timeIntervalSince(interval.start)
                if seconds > 0 {
                    overlapMinutes += seconds / 60.0
                }
            }

            active.append(interval)
        }

        return overlapMinutes
    }
}

// MARK: - Working Hours Constraint (Hard)

/// Events must fall within working hours and on a weekday the user has
/// opted into (`preferences.workingDays`). Non-working days
/// (e.g. Sat, Sun, or any weekday the user unchecked in the picker)
/// charge the full event duration so the placement becomes infeasible
/// and the GA rehomes it onto a real working day. Without this, a day
/// with no fixed events looks like 10h of free working time and
/// WeekBalance happily sinks movable tasks onto it.
public struct WorkingHoursConstraint: ScheduleConstraint {
    public let name = "WorkingHours"
    public let isHard = true

    public func penalty(for chromosome: ScheduleChromosome, context: OptimizerContext) -> Double {
        let cal = context.calendar
        let prefs = context.preferences
        var totalViolation = 0.0

        for gene in chromosome.genes where gene.isIncluded {
            let day = cal.startOfDay(for: gene.startTime)

            // Non-working day: charge the full event duration. Skip the
            // in-/out-of-hours arithmetic — the non-working charge
            // already exceeds any hour-window slip the event could
            // accumulate within the same day, and mixing the two would
            // double-count without changing the relative ordering.
            if !prefs.isWorkingDay(day, calendar: cal) {
                totalViolation += gene.duration / 60
                continue
            }

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
public struct PlanningHorizonConstraint: ScheduleConstraint {
    public let name = "PlanningHorizon"
    public let isHard = true

    public func penalty(for chromosome: ScheduleChromosome, context: OptimizerContext) -> Double {
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
public struct DeadlineConstraint: ScheduleConstraint {
    public let name = "Deadline"
    public let isHard = true

    public func penalty(for chromosome: ScheduleChromosome, context: OptimizerContext) -> Double {
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
public struct EarliestStartConstraint: ScheduleConstraint {
    public let name = "EarliestStart"
    public let isHard = true

    public func penalty(for chromosome: ScheduleChromosome, context: OptimizerContext) -> Double {
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
///
/// Only penalises the *movable* portion of the overflow: fixed events
/// arrive from the user's calendar and the GA has no way to move them,
/// so charging against a day that's already at/over the limit from fixed
/// alone would be a flat tax on every candidate — same penalty regardless
/// of what the solver does. That taught the GA nothing and just added
/// constant noise to WeekBalance-style objectives that already read the
/// per-day load.
///
/// The rule is: only count movable events that push the day's meeting
/// count above the limit, but never attribute units of overflow that
/// existed before the GA ever touched the day.
public struct MaxMeetingsPerDayConstraint: ScheduleConstraint {
    public let name = "MaxMeetingsPerDay"
    public let isHard = false

    public func penalty(for chromosome: ScheduleChromosome, context: OptimizerContext) -> Double {
        let cal = context.calendar
        var fixedCountByDay: [Date: Int] = [:]
        var movableCountByDay: [Date: Int] = [:]

        for event in context.fixedEvents {
            let day = cal.startOfDay(for: event.startDate)
            fixedCountByDay[day, default: 0] += 1
        }
        for gene in chromosome.genes where gene.isIncluded {
            let day = cal.startOfDay(for: gene.startTime)
            movableCountByDay[day, default: 0] += 1
        }

        let maxPerDay = context.preferences.maxMeetingsPerDay
        var penalty = 0.0
        let allDays = Set(fixedCountByDay.keys).union(movableCountByDay.keys)
        for day in allDays {
            let fixed = fixedCountByDay[day] ?? 0
            let movable = movableCountByDay[day] ?? 0
            let total = fixed + movable
            guard total > maxPerDay else { continue }
            // Slack is the remaining room *after* fixed eats into the cap.
            // When fixed is already at/over the cap the slack is 0 and the
            // entire movable contribution on that day is the attributable
            // overflow. When fixed is under the cap we only blame the
            // movable events past the slack.
            let slack = max(0, maxPerDay - fixed)
            let overflowFromMovable = max(0, movable - slack)
            penalty += Double(overflowFromMovable) * 10
        }
        return penalty
    }
}

// MARK: - Lunch Window Constraint (Soft)

/// Prefer to keep the lunch window free.
public struct LunchWindowConstraint: ScheduleConstraint {
    public let name = "LunchWindow"
    public let isHard = false

    public func penalty(for chromosome: ScheduleChromosome, context: OptimizerContext) -> Double {
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
public struct TaskDependencyConstraint: ScheduleConstraint {
    public let name = "TaskDependency"
    public let isHard = true

    public func penalty(for chromosome: ScheduleChromosome, context: OptimizerContext) -> Double {
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
public struct AtomicGroupConstraint: ScheduleConstraint {
    public let name = "AtomicGroup"
    public let isHard = false

    public func penalty(for chromosome: ScheduleChromosome, context: OptimizerContext) -> Double {
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
