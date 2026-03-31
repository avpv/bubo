import Foundation

// MARK: - #23 Buffer Objective

/// Rewards adequate buffer time between events.
/// Heavy meetings need more buffer than light ones.
struct BufferObjective: FitnessObjective {
    let name = "Buffer"
    var weight: Double

    init(weight: Double = 0.6) {
        self.weight = weight
    }

    func evaluate(chromosome: ScheduleChromosome, context: OptimizerContext) -> Double {
        let cal = context.calendar

        // Collect all events sorted by day, then by start time
        var eventsByDay: [Date: [(start: Date, end: Date, energyCost: Double)]] = [:]

        for event in context.fixedEvents {
            let day = cal.startOfDay(for: event.startDate)
            eventsByDay[day, default: []].append((event.startDate, event.endDate, 0.5))
        }
        for gene in chromosome.genes {
            let day = cal.startOfDay(for: gene.startTime)
            eventsByDay[day, default: []].append((gene.startTime, gene.endTime, gene.energyCost))
        }

        guard !eventsByDay.isEmpty else { return 1.0 }

        var totalScore = 0.0
        var pairCount = 0

        for (_, events) in eventsByDay {
            let sorted = events.sorted { $0.start < $1.start }

            for i in 0..<(sorted.count - 1) {
                let current = sorted[i]
                let next = sorted[i + 1]

                let gapMinutes = next.start.timeIntervalSince(current.end) / 60

                // Required buffer depends on the heaviness of the outgoing event
                let requiredBuffer: Double
                if current.energyCost > 0.7 {
                    requiredBuffer = Double(context.preferences.heavyMeetingBufferMinutes)
                } else {
                    requiredBuffer = Double(context.preferences.defaultBufferMinutes)
                }

                // Score for this pair
                let pairScore: Double
                if gapMinutes < 0 {
                    // Overlap — bad
                    pairScore = 0.0
                } else if gapMinutes >= requiredBuffer {
                    // Adequate buffer
                    pairScore = 1.0
                } else {
                    // Partial buffer
                    pairScore = gapMinutes / requiredBuffer
                }

                totalScore += pairScore
                pairCount += 1
            }
        }

        return pairCount > 0 ? totalScore / Double(pairCount) : 1.0
    }
}
