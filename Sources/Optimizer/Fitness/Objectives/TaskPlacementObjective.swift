import Foundation

// MARK: - #6 Task Placement Objective

/// Rewards placing tasks in their preferred time slots and grouping similar tasks.
/// Higher priority tasks should get better (preferred) slots.
public struct TaskPlacementObjective: FitnessObjective {
    public let name = "TaskPlacement"
    public var weight: Double

    public init(weight: Double = 1.0) {
        self.weight = weight
    }

    public func evaluate(chromosome: ScheduleChromosome, context: OptimizerContext) -> Double {
        guard !chromosome.genes.isEmpty else { return 1.0 }

        let cal = context.calendar
        // One-time lookups: avoid O(N·M) `first(where:)` scan over
        // `movableEvents` per gene and O(N·(F+M)) interrupted-check
        // over every fixed + gene per gene. Both collapse to
        // per-day/per-id dictionary reads below.
        let movableById = Dictionary(
            uniqueKeysWithValues: context.movableEvents.map { ($0.id, $0) }
        )
        var fixedStartsByDay: [Date: [Date]] = [:]
        for ev in context.fixedEvents {
            let day = cal.startOfDay(for: ev.startDate)
            fixedStartsByDay[day, default: []].append(ev.startDate)
        }
        var geneStartsByDay: [Date: [Date]] = [:]
        for g in chromosome.genes where g.isIncluded {
            let day = cal.startOfDay(for: g.startTime)
            geneStartsByDay[day, default: []].append(g.startTime)
        }

        var totalScore = 0.0
        var evaluatedCount = 0

        for gene in chromosome.genes {
            guard let event = movableById[gene.eventId] else { continue }
            evaluatedCount += 1

            // Dropped droppable genes stay in the denominator but contribute
            // 0 to `totalScore`. Without this, averaging only over included
            // genes meant excluding a poorly-placed task could mathematically
            // *raise* the objective — giving the GA a back-door incentive to
            // drop tasks whose placements pulled the per-task mean down,
            // even when `TaskInclusion` wanted to keep them.
            guard gene.isIncluded else { continue }

            var score = 0.0

            // 1. Preferred time range match (0.4 weight)
            let hour = cal.component(.hour, from: gene.startTime)
            if let preferredRange = event.preferredHourRange {
                if preferredRange.contains(hour) {
                    score += 0.4
                } else {
                    let distance = min(
                        abs(hour - preferredRange.lowerBound),
                        abs(hour - preferredRange.upperBound)
                    )
                    score += 0.4 * max(0, 1.0 - Double(distance) * 0.15)
                }
            } else {
                // No preference → reward "earlier in the day" instead
                // of a flat neutral 0.3. Before this, a task without
                // `preferredHourRange` scored identically at 09:00 and
                // 17:00, so the GA had no gradient pulling same-day
                // tasks toward the morning. Users consistently prefer
                // "do tasks first, leave gaps at the end of the day";
                // this term gives them that preference for free when
                // no stronger signal is set. Linear ramp from 0.4 (at
                // `workingHours.lowerBound`) to 0.2 (at
                // `workingHours.upperBound`) so a morning placement
                // still can't beat a matched `preferredHourRange`
                // placement on a task that has one.
                let lower = context.workingHours.lowerBound
                let upper = context.workingHours.upperBound
                let span = max(1, upper - lower)
                let offsetFromStart = max(0, min(span, hour - lower))
                let earliness = 1.0 - Double(offsetFromStart) / Double(span)
                score += 0.2 + 0.2 * earliness
            }

            // 2. Priority-weighted slot quality (0.3 weight)
            // Higher priority tasks should be at peak energy times.
            // Story points boost the effective priority for slot placement:
            // high-SP tasks are pushed harder toward peak energy hours.
            let peakDistance = context.preferences.peakEnergyDistance(from: hour)
            let slotQuality = 1.0 / (1.0 + Double(peakDistance) * 0.1)
            let spBoost: Double = {
                guard let sp = gene.storyPoints, sp > 0 else { return 0.0 }
                return min(0.3, log(Double(sp)) / log(13.0) * 0.3)
            }()
            let effectivePriority = min(1.0, event.priority + spBoost)
            score += 0.3 * (slotQuality * effectivePriority + (1 - effectivePriority) * 0.5)

            // 3. Not fragmented — task has enough continuous time (0.3 weight)
            let geneDay = cal.startOfDay(for: gene.startTime)
            let fixedStarts = fixedStartsByDay[geneDay] ?? []
            let geneStarts = geneStartsByDay[geneDay] ?? []
            let hasEnoughRoom = !isInterrupted(
                gene: gene,
                fixedStartsOnDay: fixedStarts,
                geneStartsOnDay: geneStarts
            )
            score += hasEnoughRoom ? 0.3 : 0.05

            totalScore += score
        }

        return evaluatedCount > 0 ? totalScore / Double(evaluatedCount) : 1.0
    }

    /// Returns true when any fixed event or other included gene starts
    /// strictly between `gene.startTime` and `gene.endTime`. Pre-
    /// filtered to the gene's own day by the caller — avoids a
    /// whole-horizon scan for a check that's only meaningful for
    /// same-day events. Self-exclusion falls out of the strict `>`
    /// comparison (a gene's own start is never strictly greater than
    /// itself), so no eventId filter is needed here.
    private func isInterrupted(
        gene: ScheduleGene,
        fixedStartsOnDay: [Date],
        geneStartsOnDay: [Date]
    ) -> Bool {
        let start = gene.startTime
        let end = gene.endTime
        for s in fixedStartsOnDay where s > start && s < end {
            return true
        }
        for s in geneStartsOnDay where s > start && s < end {
            return true
        }
        return false
    }
}
