import Foundation

// MARK: - #15 Energy Curve Objective

/// Models user energy as a depletable resource throughout the day.
/// High-energy tasks should be placed at peak energy times.
/// Energy depletes with meetings and recovers during breaks.
struct EnergyCurveObjective: FitnessObjective {
    let name = "EnergyBalance"
    var weight: Double

    init(weight: Double = 0.9) {
        self.weight = weight
    }

    func evaluate(chromosome: ScheduleChromosome, context: OptimizerContext) -> Double {
        let cal = context.calendar

        // Group all events by day
        var eventsByDay: [Date: [(start: Date, end: Date, energyCost: Double)]] = [:]

        for event in context.fixedEvents {
            let day = cal.startOfDay(for: event.startDate)
            eventsByDay[day, default: []].append((event.startDate, event.endDate, 0.5)) // fixed = medium cost
        }
        for gene in chromosome.genes {
            let day = cal.startOfDay(for: gene.startTime)
            eventsByDay[day, default: []].append((gene.startTime, gene.endTime, gene.energyCost))
        }

        guard !eventsByDay.isEmpty else { return 1.0 }

        let peakHour = context.preferences.peakEnergyHour
        let decayRate = context.preferences.energyDecayRate
        var totalScore = 0.0
        var dayCount = 0

        for (_, events) in eventsByDay {
            let sorted = events.sorted { $0.start < $1.start }

            // Simulate energy throughout the day
            var energy = 1.0
            var minEnergy = 1.0
            var alignmentScore = 0.0

            for (idx, event) in sorted.enumerated() {
                // Recover energy during gap before this event
                if idx > 0 {
                    let gap = event.start.timeIntervalSince(sorted[idx - 1].end)
                    if gap > 0 {
                        let gapHours = gap / 3600
                        // Logarithmic recovery: longer breaks give diminishing returns.
                        // A 15-min break recovers ~0.05, a 1-hour break ~0.15.
                        let recovery = 0.15 * log2(1.0 + gapHours * 4.0)
                        energy = min(1.0, energy + recovery)
                    }
                }

                let hour = Double(cal.component(.hour, from: event.start))
                    + Double(cal.component(.minute, from: event.start)) / 60.0
                let durationHours = event.end.timeIntervalSince(event.start) / 3600

                // Energy at this time of day (smooth bell curve around peak)
                let hourDistance = abs(hour - Double(peakHour))
                let timeEnergy = exp(-hourDistance * hourDistance * 0.02)

                // High-cost tasks at high-energy times = good alignment
                let alignment = event.energyCost * timeEnergy
                alignmentScore += alignment

                // Deplete energy
                energy -= event.energyCost * durationHours * decayRate
                minEnergy = min(minEnergy, energy)
            }

            // Score components:
            // 1. Energy never drops below zero (0.4 weight)
            let burnoutScore = max(0, min(1.0, (minEnergy + 0.5) / 1.5))

            // 2. High-cost tasks aligned with high-energy times (0.4 weight)
            let maxPossibleAlignment = sorted.reduce(0.0) { $0 + $1.energyCost }
            let normalizedAlignment = maxPossibleAlignment > 0
                ? alignmentScore / maxPossibleAlignment
                : 1.0

            // 3. Smooth energy curve (not too many back-to-back heavy tasks) (0.2 weight)
            let heavyBackToBack = countConsecutiveHeavyTasks(sorted)
            let smoothnessScore = 1.0 / (1.0 + Double(heavyBackToBack) * 0.3)

            totalScore += burnoutScore * 0.4 + normalizedAlignment * 0.4 + smoothnessScore * 0.2
            dayCount += 1
        }

        return dayCount > 0 ? totalScore / Double(dayCount) : 0.5
    }

    private func countConsecutiveHeavyTasks(
        _ events: [(start: Date, end: Date, energyCost: Double)]
    ) -> Int {
        guard events.count > 1 else { return 0 }
        var count = 0
        for i in 0..<(events.count - 1) {
            // "Heavy" = energy cost > 0.6, and gap between events < 15 min
            if events[i].energyCost > 0.6 && events[i + 1].energyCost > 0.6 {
                let gap = events[i + 1].start.timeIntervalSince(events[i].end)
                if gap < 15 * 60 {
                    count += 1
                }
            }
        }
        return count
    }
}
