import Foundation
import BuboDomain

// MARK: - #21 Deadline Objective

/// Rewards scheduling tasks well before their deadlines (no cramming).
/// Higher priority tasks get larger early-completion bonuses.
///
/// Deliberately NOT day-partitioned. A per-day formulation combined
/// day scores with an arithmetic mean over days, which is not
/// drop-safe: a dropped event's zero folded into an existing day's
/// bucket while a kept-but-crammed placement added a whole
/// low-scoring day to the denominator, so excluding a task could
/// SCORE HIGHER than keeping it. It also made fitness depend on
/// which evaluation path (full vs delta) ran. The flat per-event
/// mean below is exact, cheap (O(N) per evaluation), and identical
/// on every path.
public struct DeadlineObjective: FitnessObjective {
    public let name = "Deadline"
    public var weight: Double

    public init(weight: Double = 3.0) {
        self.weight = weight
    }

    public func evaluate(chromosome: ScheduleChromosome, context: OptimizerContext) -> Double {
        // Exact count-weighted mean over every deadline-bearing
        // event, with drops charged as 0: dropping event X only
        // changes X's own contribution from `score ≥ 0` to 0, so a
        // drop can never raise the objective.
        let cal = context.calendar
        let eventsWithDeadlines = context.movableEvents.filter { $0.deadline != nil }
        guard !eventsWithDeadlines.isEmpty else { return 1.0 }

        let deadlineEventIds = Set(eventsWithDeadlines.map { $0.id })
        var deadlineCountByDay: [Date: Int] = [:]
        for gene in chromosome.genes where gene.isIncluded && deadlineEventIds.contains(gene.eventId) {
            deadlineCountByDay[cal.startOfDay(for: gene.startTime), default: 0] += 1
        }

        var sum = 0.0
        var count = 0
        for event in eventsWithDeadlines {
            guard chromosome.genes.contains(where: { $0.eventId == event.id }) else { continue }
            count += 1
            guard let gene = chromosome.genes.first(where: { $0.eventId == event.id && $0.isIncluded }),
                  let deadline = event.deadline else {
                continue   // dropped → contributes 0
            }
            let day = cal.startOfDay(for: gene.startTime)
            sum += scoreEvent(
                gene: gene,
                deadline: deadline,
                priority: event.priority,
                sameDayDeadlineCount: deadlineCountByDay[day] ?? 1
            )
        }
        guard count > 0 else { return 1.0 }
        return sum / Double(count)
    }

    /// Per-event scoring — identical math to the original
    /// implementation, kept as a helper for readability.
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
