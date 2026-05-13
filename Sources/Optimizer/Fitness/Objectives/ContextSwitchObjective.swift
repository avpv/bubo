import Foundation

// MARK: - #22 Context Switch Objective

/// Penalizes frequent context switches between different projects/categories.
/// Rewards grouping events with the same context together.
public struct ContextSwitchObjective: DayPartitionedObjective {
    public let name = "ContextSwitch"
    public var weight: Double

    public init(weight: Double = 0.7) {
        self.weight = weight
    }

    public func evaluate(chromosome: ScheduleChromosome, context: OptimizerContext) -> Double {
        combinePerDay(evaluatePerDay(chromosome: chromosome, context: context))
    }

    public func evaluatePerDay(
        chromosome: ScheduleChromosome,
        context: OptimizerContext
    ) -> [Date: Double] {
        let cal = context.calendar
        var eventsByDay: [Date: [(start: Date, end: Date, context: String?)]] = [:]

        for event in context.fixedEvents {
            let day = cal.startOfDay(for: event.startDate)
            eventsByDay[day, default: []].append((event.startDate, event.endDate, event.resolvedContext()))
        }
        for gene in chromosome.genes where gene.isIncluded {
            let day = cal.startOfDay(for: gene.startTime)
            eventsByDay[day, default: []].append((gene.startTime, gene.endTime, gene.context))
        }

        var scores: [Date: Double] = [:]
        for (day, events) in eventsByDay {
            scores[day] = scoreDay(events: events)
        }
        return scores
    }

    public func evaluateOneDay(
        day: Date,
        chromosome: ScheduleChromosome,
        context: OptimizerContext
    ) -> Double {
        let cal = context.calendar
        var events: [(start: Date, end: Date, context: String?)] = []
        for event in context.fixedEvents where cal.startOfDay(for: event.startDate) == day {
            events.append((event.startDate, event.endDate, event.resolvedContext()))
        }
        for gene in chromosome.genes where gene.isIncluded && cal.startOfDay(for: gene.startTime) == day {
            events.append((gene.startTime, gene.endTime, gene.context))
        }
        return scoreDay(events: events)
    }

    /// Score a single day's context-switch severity. Called by both the
    /// bulk and single-day paths so scoring logic lives in one place.
    private func scoreDay(
        events: [(start: Date, end: Date, context: String?)]
    ) -> Double {
        guard events.count > 1 else { return 1.0 }
        let sorted = events.sorted { $0.start < $1.start }

        var totalSwitchSeverity = 0.0
        for i in 0..<(sorted.count - 1) {
            let ctx1 = sorted[i].context ?? "__none__"
            let ctx2 = sorted[i + 1].context ?? "__none__"
            totalSwitchSeverity += Self.switchSeverity(from: ctx1, to: ctx2)
        }

        let maxSwitches = sorted.count - 1
        let switchRatio = maxSwitches > 0 ? totalSwitchSeverity / Double(maxSwitches) : 0
        let dayScore = exp(-switchRatio * 1.5)
        let clusterBonus = contextClusterBonus(sorted)
        return min(1.0, dayScore + clusterBonus)
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
    public static func switchSeverity(from ctx1: String, to ctx2: String) -> Double {
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
