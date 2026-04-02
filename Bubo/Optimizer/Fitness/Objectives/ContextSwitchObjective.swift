import Foundation

// MARK: - #22 Context Switch Objective

/// Penalizes frequent context switches between different projects/categories.
/// Rewards grouping events with the same context together.
struct ContextSwitchObjective: FitnessObjective {
    let name = "ContextSwitch"
    var weight: Double

    init(weight: Double = 0.7) {
        self.weight = weight
    }

    func evaluate(chromosome: ScheduleChromosome, context: OptimizerContext) -> Double {
        let cal = context.calendar

        // Group all events by day with their context
        var eventsByDay: [Date: [(start: Date, end: Date, context: String?)]] = [:]

        for event in context.fixedEvents {
            let day = cal.startOfDay(for: event.startDate)
            eventsByDay[day, default: []].append((event.startDate, event.endDate, event.resolvedContext()))
        }
        for gene in chromosome.genes {
            let day = cal.startOfDay(for: gene.startTime)
            eventsByDay[day, default: []].append((gene.startTime, gene.endTime, gene.context))
        }

        guard !eventsByDay.isEmpty else { return 1.0 }

        var totalScore = 0.0
        var dayCount = 0

        for (_, events) in eventsByDay {
            guard events.count > 1 else {
                totalScore += 1.0
                dayCount += 1
                continue
            }

            let sorted = events.sorted { $0.start < $1.start }

            // Measure context switch severity using composite key prefix overlap.
            // "Work/backend/API" → "Work/backend/DB" is a partial switch (0.33),
            // "Work/backend" → "Personal/sport" is a full switch (1.0),
            // "Work/backend" → "Work/backend" is no switch (0.0).
            var totalSwitchSeverity = 0.0
            for i in 0..<(sorted.count - 1) {
                let ctx1 = sorted[i].context ?? "__none__"
                let ctx2 = sorted[i + 1].context ?? "__none__"
                totalSwitchSeverity += Self.switchSeverity(from: ctx1, to: ctx2)
            }

            // Normalize: severity per transition, 0 = no switches, 1 = all full switches
            let maxSwitches = sorted.count - 1
            let switchRatio = maxSwitches > 0 ? totalSwitchSeverity / Double(maxSwitches) : 0

            // Score: fewer/lighter switches = better
            // switchRatio 0 = 1.0, switchRatio 1 = ~0.37
            let dayScore = exp(-switchRatio * 1.5)

            // Bonus: check for context clusters (3+ same-context events in a row)
            let clusterBonus = contextClusterBonus(sorted)

            totalScore += min(1.0, dayScore + clusterBonus)
            dayCount += 1
        }

        return dayCount > 0 ? totalScore / Double(dayCount) : 0.5
    }

    /// Bonus for having clusters of same-context events.
    /// Uses fuzzy matching: events sharing a common prefix (e.g. "Work/backend/API"
    /// and "Work/backend/DB") count as a cluster with partial credit.
    /// Scales with cluster size: 3 events → 0.05, 4 → 0.08, 5+ → 0.1.
    private func contextClusterBonus(
        _ events: [(start: Date, end: Date, context: String?)]
    ) -> Double {
        var maxRun = 1
        var currentRun = 1
        var clusterCount = 0

        for i in 1..<events.count {
            let prev = events[i - 1].context ?? "__none__"
            let curr = events[i].context ?? "__none__"
            // Near-match (severity < 0.5) counts as same cluster
            if Self.switchSeverity(from: prev, to: curr) < 0.5 {
                currentRun += 1
                maxRun = max(maxRun, currentRun)
            } else {
                if currentRun >= 3 { clusterCount += 1 }
                currentRun = 1
            }
        }
        if currentRun >= 3 { clusterCount += 1 }

        guard maxRun >= 3 else { return 0.0 }

        // Scaled bonus: larger clusters and more clusters = better
        let sizeBonus = min(0.1, Double(maxRun - 2) * 0.025)  // 3→0.025, 4→0.05, 6+→0.1
        let countBonus = min(0.05, Double(clusterCount - 1) * 0.025)  // extra clusters add up to 0.05
        return sizeBonus + countBonus
    }

    // MARK: - Fuzzy Context Comparison

    /// Measure how severe a context switch is based on shared prefix segments.
    ///   - Identical contexts → 0.0 (no switch)
    ///   - Partial overlap ("Work/backend/API" → "Work/backend/DB") → 0.33
    ///   - No overlap ("Work" → "Personal") → 1.0 (full switch)
    static func switchSeverity(from ctx1: String, to ctx2: String) -> Double {
        if ctx1 == ctx2 { return 0.0 }

        let parts1 = ctx1.split(separator: "/")
        let parts2 = ctx2.split(separator: "/")
        let maxParts = max(parts1.count, parts2.count)
        guard maxParts > 0 else { return 1.0 }

        var shared = 0
        for (a, b) in zip(parts1, parts2) {
            if a == b { shared += 1 } else { break }
        }

        // Fraction of segments that differ
        return 1.0 - Double(shared) / Double(maxParts)
    }
}
