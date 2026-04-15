import Foundation

// MARK: - #23 Buffer Objective

/// Rewards adequate buffer time between events.
/// Heavy meetings need more buffer than light ones.
///
/// Day-partitioned: the score is the ratio of "well-buffered pairs" to
/// "all consecutive pairs" across every day. Each day contributes an
/// independent pair-count and sum of pair-scores, so delta evaluation
/// only needs to rescore days whose gene placements changed.
struct BufferObjective: DayPartitionedObjective {
    let name = "Buffer"
    var weight: Double

    init(weight: Double = 0.6) {
        self.weight = weight
    }

    func evaluate(chromosome: ScheduleChromosome, context: OptimizerContext) -> Double {
        combinePerDay(evaluatePerDay(chromosome: chromosome, context: context))
    }

    func evaluatePerDay(
        chromosome: ScheduleChromosome,
        context: OptimizerContext
    ) -> [Date: Double] {
        let cal = context.calendar

        var eventsByDay: [Date: [(start: Date, end: Date, energyCost: Double)]] = [:]
        for event in context.fixedEvents {
            let day = cal.startOfDay(for: event.startDate)
            eventsByDay[day, default: []].append((event.startDate, event.endDate, 0.5))
        }
        for gene in chromosome.genes where gene.isIncluded {
            let day = cal.startOfDay(for: gene.startTime)
            eventsByDay[day, default: []].append((gene.startTime, gene.endTime, gene.energyCost))
        }

        var perDay: [Date: Double] = [:]
        perDay.reserveCapacity(eventsByDay.count)
        for (day, events) in eventsByDay {
            perDay[day] = scoreDay(events: events, preferences: context.preferences)
        }
        return perDay
    }

    func evaluateOneDay(
        day: Date,
        chromosome: ScheduleChromosome,
        context: OptimizerContext
    ) -> Double {
        let cal = context.calendar
        var events: [(start: Date, end: Date, energyCost: Double)] = []
        for event in context.fixedEvents where cal.startOfDay(for: event.startDate) == day {
            events.append((event.startDate, event.endDate, 0.5))
        }
        for gene in chromosome.genes where gene.isIncluded && cal.startOfDay(for: gene.startTime) == day {
            events.append((gene.startTime, gene.endTime, gene.energyCost))
        }
        return scoreDay(events: events, preferences: context.preferences)
    }

    /// Shared scoring core. Returns 1.0 for days with fewer than two events
    /// (no pair to score) so single-event days don't depress the daily mean —
    /// matches the pair-denominator behaviour of the pre-partitioned version.
    private func scoreDay(
        events: [(start: Date, end: Date, energyCost: Double)],
        preferences: OptimizerPreferences
    ) -> Double {
        guard events.count >= 2 else { return 1.0 }
        let sorted = events.sorted { $0.start < $1.start }

        var totalScore = 0.0
        var pairCount = 0

        for i in 0..<(sorted.count - 1) {
            let current = sorted[i]
            let next = sorted[i + 1]

            let gapMinutes = next.start.timeIntervalSince(current.end) / 60
            let requiredBuffer: Double = current.energyCost > 0.7
                ? Double(preferences.heavyMeetingBufferMinutes)
                : Double(preferences.defaultBufferMinutes)

            let pairScore: Double
            if gapMinutes < 0 {
                pairScore = 0.0
            } else if gapMinutes >= requiredBuffer {
                pairScore = 1.0
            } else {
                pairScore = requiredBuffer > 0 ? gapMinutes / requiredBuffer : 1.0
            }

            totalScore += pairScore
            pairCount += 1
        }

        return pairCount > 0 ? totalScore / Double(pairCount) : 1.0
    }
}
