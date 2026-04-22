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
/// The combining step reconstructs the pre-partitioning scalar so the
/// combined score still tracks `exp(-α·total_minutes)` semantics: we
/// take the geometric mean (weighted by the per-day event count)
/// rather than the arithmetic-mean default. Arithmetic mean would
/// reward many-clean-days even when a single day has heavy overlap;
/// geometric mean keeps a day with severe conflicts dominating the
/// combined score, matching the original un-partitioned objective.
struct ConflictObjective: DayPartitionedObjective {
    let name = "Conflict"
    var weight: Double

    init(weight: Double = 10.0) {
        self.weight = weight
    }

    func evaluate(chromosome: ScheduleChromosome, context: OptimizerContext) -> Double {
        let perDay = evaluatePerDay(chromosome: chromosome, context: context)
        return combinePerDay(perDay)
    }

    func evaluatePerDay(
        chromosome: ScheduleChromosome,
        context: OptimizerContext
    ) -> [Date: Double] {
        let cal = context.calendar
        var eventsByDay: [Date: [(start: Date, end: Date)]] = [:]

        for event in context.fixedEvents {
            let day = cal.startOfDay(for: event.startDate)
            eventsByDay[day, default: []].append((event.startDate, event.endDate))
        }
        for gene in chromosome.genes where gene.isIncluded {
            let day = cal.startOfDay(for: gene.startTime)
            eventsByDay[day, default: []].append((gene.startTime, gene.endTime))
        }

        var perDay: [Date: Double] = [:]
        perDay.reserveCapacity(eventsByDay.count)
        for (day, events) in eventsByDay {
            perDay[day] = scoreDay(events: events)
        }
        return perDay
    }

    func evaluateOneDay(
        day: Date,
        chromosome: ScheduleChromosome,
        context: OptimizerContext
    ) -> Double {
        let cal = context.calendar
        var events: [(start: Date, end: Date)] = []
        for event in context.fixedEvents where cal.startOfDay(for: event.startDate) == day {
            events.append((event.startDate, event.endDate))
        }
        for gene in chromosome.genes where gene.isIncluded && cal.startOfDay(for: gene.startTime) == day {
            events.append((gene.startTime, gene.endTime))
        }
        return scoreDay(events: events)
    }

    /// Geometric mean of per-day scores. Falls back to 1.0 when no day
    /// has events — matches `DayPartitionedObjective`'s empty-horizon
    /// default while keeping a single overloaded day from being
    /// diluted into invisibility by several clean ones.
    func combinePerDay(_ perDay: [Date: Double]) -> Double {
        guard !perDay.isEmpty else { return 1.0 }
        // Geometric mean via log-sum to avoid underflow when many days
        // have scores near 0.
        var logSum = 0.0
        var count = 0
        for score in perDay.values {
            // Clamp to a tiny floor so log(0) doesn't blow up; score=0
            // becomes log(1e-10) which already dominates the aggregate
            // the way we want.
            let clamped = max(1e-10, score)
            logSum += log(clamped)
            count += 1
        }
        return exp(logSum / Double(count))
    }

    /// Per-day scoring core — identical math to the pre-partitioning
    /// implementation but restricted to events on the same day.
    /// Same exponential-decay scales (0.05 per overlap minute, 0.02
    /// per near-miss minute) so the geometric combine above
    /// reconstructs the global scalar.
    private func scoreDay(events: [(start: Date, end: Date)]) -> Double {
        guard !events.isEmpty else { return 1.0 }
        let sorted = events.sorted { $0.start < $1.start }

        var totalOverlapMinutes = 0.0
        var nearMissMinutes = 0.0

        for i in 0..<sorted.count {
            for j in (i + 1)..<sorted.count {
                guard sorted[j].start < sorted[i].end else { break }
                let overlapStart = max(sorted[i].start, sorted[j].start)
                let overlapEnd = min(sorted[i].end, sorted[j].end)
                let overlapDuration = max(0, overlapEnd.timeIntervalSince(overlapStart)) / 60
                totalOverlapMinutes += overlapDuration
            }

            if i + 1 < sorted.count {
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
