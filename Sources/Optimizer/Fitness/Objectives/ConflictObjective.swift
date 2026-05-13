import Foundation

// MARK: - #5 Conflict Objective

/// Penalizes schedules where movable events overlap with fixed or other movable events.
/// This is a soft objective complement to the hard NoOverlapConstraint —
/// it provides gradient information even for near-conflicts.
///
/// Day-partitioned: two events on different days cannot overlap or be
/// within 5 minutes of each other, so the overlap/near-miss score
/// decomposes cleanly as a per-day calculation. Delta evaluation
/// shrinks from O(N²) pairwise across the whole horizon to
/// O(dirty_days) when a mutation touches only a few days — the
/// typical single-gene case on weekly plans.
///
/// The combining step averages per-day scores arithmetically,
/// weighted by event count so empty days don't dilute the signal
/// from a single busy-and-cluttered day. The previous geometric-mean
/// variant amplified small per-day penalties multiplicatively and
/// sent the combined Conflict score to ~0.6 even when
/// `conflict_edges=0` and the only trouble was a 5-minute gap
/// between two adjacent events — a penalty that blamed the GA for
/// user-driven fixed-event collisions it couldn't do anything about
/// and ate 70%+ of the fitness budget on trivial problems.
public struct ConflictObjective: DayPartitionedObjective {
    public let name = "Conflict"
    public var weight: Double

    public init(weight: Double = 10.0) {
        self.weight = weight
    }

    public func evaluate(chromosome: ScheduleChromosome, context: OptimizerContext) -> Double {
        let perDay = evaluatePerDay(chromosome: chromosome, context: context)
        return combinePerDay(perDay)
    }

    public func evaluatePerDay(
        chromosome: ScheduleChromosome,
        context: OptimizerContext
    ) -> [Date: Double] {
        let cal = context.calendar
        typealias DayEvent = (start: Date, end: Date, movable: Bool)
        var eventsByDay: [Date: [DayEvent]] = [:]

        for event in context.fixedEvents {
            let day = cal.startOfDay(for: event.startDate)
            eventsByDay[day, default: []].append((event.startDate, event.endDate, false))
        }
        for gene in chromosome.genes where gene.isIncluded {
            let day = cal.startOfDay(for: gene.startTime)
            eventsByDay[day, default: []].append((gene.startTime, gene.endTime, true))
        }

        var perDay: [Date: Double] = [:]
        perDay.reserveCapacity(eventsByDay.count)
        for (day, events) in eventsByDay {
            perDay[day] = scoreDay(events: events)
        }
        return perDay
    }

    public func evaluateOneDay(
        day: Date,
        chromosome: ScheduleChromosome,
        context: OptimizerContext
    ) -> Double {
        let cal = context.calendar
        var events: [(start: Date, end: Date, movable: Bool)] = []
        for event in context.fixedEvents where cal.startOfDay(for: event.startDate) == day {
            events.append((event.startDate, event.endDate, false))
        }
        for gene in chromosome.genes where gene.isIncluded && cal.startOfDay(for: gene.startTime) == day {
            events.append((gene.startTime, gene.endTime, true))
        }
        return scoreDay(events: events)
    }

    /// Arithmetic mean of per-day scores. Days with no events are
    /// skipped so the empty-horizon default (`1.0`) still applies.
    /// Unlike the previous geometric-mean combine, a single day
    /// scoring 0.9 no longer drags a week of perfect days down to
    /// ~0.95 — the combined score tracks the fraction of trouble
    /// linearly, which is what downstream fitness-loss breakdowns
    /// actually read for user-facing explanations.
    public func combinePerDay(_ perDay: [Date: Double]) -> Double {
        guard !perDay.isEmpty else { return 1.0 }
        var sum = 0.0
        var count = 0
        for score in perDay.values {
            sum += score
            count += 1
        }
        return sum / Double(count)
    }

    /// Per-day scoring core. Only counts overlaps and near-misses
    /// that involve at least one movable gene — fixed↔fixed
    /// collisions on the user's calendar are not the optimizer's
    /// problem to solve and should not be penalised.
    ///
    /// Same exponential-decay scales as before (0.05 per overlap
    /// minute, 0.02 per near-miss minute) so the scalar comparison
    /// with historical runs stays meaningful.
    private func scoreDay(events: [(start: Date, end: Date, movable: Bool)]) -> Double {
        guard !events.isEmpty else { return 1.0 }
        let sorted = events.sorted { $0.start < $1.start }

        var totalOverlapMinutes = 0.0
        var nearMissMinutes = 0.0

        for i in 0..<sorted.count {
            for j in (i + 1)..<sorted.count {
                guard sorted[j].start < sorted[i].end else { break }
                // Skip fixed↔fixed overlaps — the user owns those.
                if !sorted[i].movable && !sorted[j].movable { continue }
                let overlapStart = max(sorted[i].start, sorted[j].start)
                let overlapEnd = min(sorted[i].end, sorted[j].end)
                let overlapDuration = max(0, overlapEnd.timeIntervalSince(overlapStart)) / 60
                totalOverlapMinutes += overlapDuration
            }

            if i + 1 < sorted.count {
                // Near-miss also only when at least one side is
                // movable — two back-to-back fixed meetings are the
                // user's arrangement, not a scheduling defect.
                if !sorted[i].movable && !sorted[i + 1].movable { continue }
                let gap = sorted[i + 1].start.timeIntervalSince(sorted[i].end) / 60
                if gap > 0 && gap < 5 {
                    nearMissMinutes += (5 - gap)
                }
            }
        }

        let overlapScore = exp(-totalOverlapMinutes * 0.05)
        let nearMissScore = exp(-nearMissMinutes * 0.02)
        return overlapScore * 0.8 + nearMissScore * 0.2
    }
}
