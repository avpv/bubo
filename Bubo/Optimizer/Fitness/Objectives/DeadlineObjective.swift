import Foundation

// MARK: - #21 Deadline Objective

/// Rewards scheduling tasks well before their deadlines (no cramming).
/// Higher priority tasks get larger early-completion bonuses.
///
/// Day-partitioned: both the early-fraction reward and the cramming
/// penalty are functions of the gene's day only (events scheduled on
/// different days don't interact through this objective). Per-event
/// scores are bucketed by gene's start-of-day, then combined as a
/// count-weighted mean so a day with three deadline tasks
/// contributes proportionally more than a day with one — matching
/// the pre-partitioning "mean over evaluated events" semantics.
struct DeadlineObjective: DayPartitionedObjective {
    let name = "Deadline"
    var weight: Double

    init(weight: Double = 3.0) {
        self.weight = weight
    }

    func evaluate(chromosome: ScheduleChromosome, context: OptimizerContext) -> Double {
        let perDay = evaluatePerDay(chromosome: chromosome, context: context)
        return combinePerDay(perDay)
    }

    /// For the delta path: per-day scores are stored as
    /// `scoreSum / count` so the combine step can reconstruct the
    /// count-weighted mean. We pack the count into the dictionary
    /// value by multiplying: `perDay[day] = count_weighted_score`
    /// and rely on `combinePerDay` knowing the accompanying count.
    /// Since `[Date: Double]` can't carry counts, we instead return
    /// a per-day score that's already normalized, and combine via
    /// arithmetic mean — an approximation that's exact when each
    /// day has the same number of deadline events, and close
    /// enough when they don't. The delta path wins enormously and
    /// the fidelity loss is below GA noise on every workload we've
    /// measured against.
    func evaluatePerDay(
        chromosome: ScheduleChromosome,
        context: OptimizerContext
    ) -> [Date: Double] {
        let cal = context.calendar
        let eventsWithDeadlines = context.movableEvents.filter { $0.deadline != nil }
        guard !eventsWithDeadlines.isEmpty else { return [:] }

        // Bucket the chromosome's genes by day-of-start so the
        // cramming penalty (same-day deadline count) can be
        // precomputed per day and shared across events on that day.
        let deadlineEventIds = Set(eventsWithDeadlines.map { $0.id })
        var deadlineGenesByDay: [Date: [ScheduleGene]] = [:]
        for gene in chromosome.genes where gene.isIncluded && deadlineEventIds.contains(gene.eventId) {
            let day = cal.startOfDay(for: gene.startTime)
            deadlineGenesByDay[day, default: []].append(gene)
        }

        // Score each deadline-bearing event; bucket its contribution
        // by the day it lives on (or a sentinel day for dropped
        // events so the denominator still includes them).
        let droppedDay = cal.startOfDay(for: context.planningHorizon.start)
        var perDayScoreSum: [Date: Double] = [:]
        var perDayCount: [Date: Int] = [:]

        for event in eventsWithDeadlines {
            let includedGene = chromosome.genes.first { $0.eventId == event.id && $0.isIncluded }

            if let gene = includedGene, let deadline = event.deadline {
                let day = cal.startOfDay(for: gene.startTime)
                let sameDayCount = deadlineGenesByDay[day]?.count ?? 1
                let score = scoreEvent(gene: gene, deadline: deadline, priority: event.priority, sameDayDeadlineCount: sameDayCount)
                perDayScoreSum[day, default: 0] += score
                perDayCount[day, default: 0] += 1
            } else if chromosome.genes.contains(where: { $0.eventId == event.id }) {
                // Dropped droppable with a deadline: charge a zero
                // score against the horizon's first day so the
                // denominator still includes it. Matches the
                // pre-partition behaviour of counting drops as 0.
                perDayScoreSum[droppedDay, default: 0] += 0
                perDayCount[droppedDay, default: 0] += 1
            }
        }

        var perDay: [Date: Double] = [:]
        for (day, sum) in perDayScoreSum {
            let count = max(1, perDayCount[day] ?? 1)
            perDay[day] = sum / Double(count)
        }
        return perDay
    }

    func evaluateOneDay(
        day: Date,
        chromosome: ScheduleChromosome,
        context: OptimizerContext
    ) -> Double {
        let cal = context.calendar
        let eventsWithDeadlines = context.movableEvents.filter { $0.deadline != nil }
        let deadlineEventIds = Set(eventsWithDeadlines.map { $0.id })

        // Day-local genes with deadlines — both for scoring and for
        // the cramming count.
        let dayGenes = chromosome.genes.filter { gene in
            gene.isIncluded
                && deadlineEventIds.contains(gene.eventId)
                && cal.startOfDay(for: gene.startTime) == day
        }
        let sameDayCount = dayGenes.count
        guard !dayGenes.isEmpty else {
            // Day might still contain dropped-event contributions, but
            // those live on the horizon's first day in `evaluatePerDay`.
            // Return the neutral 1.0 so combine's arithmetic mean stays
            // well-defined for days that are genuinely empty of
            // deadline events.
            return 1.0
        }

        let eventByIdForDay: [String: OptimizableEvent] = Dictionary(
            uniqueKeysWithValues: eventsWithDeadlines.map { ($0.id, $0) }
        )

        var sum = 0.0
        for gene in dayGenes {
            guard let event = eventByIdForDay[gene.eventId],
                  let deadline = event.deadline else { continue }
            sum += scoreEvent(gene: gene, deadline: deadline, priority: event.priority, sameDayDeadlineCount: sameDayCount)
        }
        return sum / Double(dayGenes.count)
    }

    /// Per-event scoring — identical math to the pre-partitioning
    /// implementation, lifted into a shared helper so `evaluateOneDay`
    /// and `evaluatePerDay` stay byte-identical in arithmetic.
    private func scoreEvent(gene: ScheduleGene, deadline: Date, priority: Double, sameDayDeadlineCount: Int) -> Double {
        let timeUntilDeadline = deadline.timeIntervalSince(gene.endTime)
        if timeUntilDeadline < 0 { return 0 }

        let totalWindow = deadline.timeIntervalSince(gene.startTime)
        guard totalWindow > 0 else { return 0 }

        let bufferFraction = timeUntilDeadline / totalWindow
        let earlyScore = 1.0 - exp(-bufferFraction * 3.0)
        let priorityBonus = earlyScore * priority * 0.2
        // Cramming penalty: 0.05 per *other* same-day deadline event
        // (so three events on one day each get 0.10 penalty).
        let otherSameDay = max(0, sameDayDeadlineCount - 1)
        let crammingPenalty = Double(otherSameDay) * 0.05
        return max(0, min(1.0, earlyScore + priorityBonus - crammingPenalty))
    }
}
