import Foundation

// MARK: - Scenario Comparison
//
// Diverse-scenario generation has moved to `MAPElitesArchive`. This file
// now hosts scenario comparison helpers: once the archive produces K
// schedules, `ScenarioComparison` summarizes how each alternative differs
// from the primary pick (objective scores, event placements).

public struct ScenarioComparison: Sendable {
    public let scenarioIndex: Int
    public let fitnessVsBest: Double
    public let keyDifferences: [String]
}

public enum ScenarioComparer {

    /// Compare scenarios against the first (primary) scenario and return
    /// human-readable differences. Used by the UI "compare scenarios"
    /// view to highlight trade-offs between Pareto-frontier alternatives.
    public static func compare(_ scenarios: [ScheduleScenario]) -> [ScenarioComparison] {
        guard scenarios.count >= 2 else { return [] }

        var comparisons: [ScenarioComparison] = []

        for i in 1..<scenarios.count {
            let base = scenarios[0]
            let other = scenarios[i]

            var differences: [String] = []

            // Compare objective scores
            for (key, baseScore) in base.objectiveBreakdown {
                if let otherScore = other.objectiveBreakdown[key] {
                    let diff = otherScore - baseScore
                    if abs(diff) > 0.1 {
                        let direction = diff > 0 ? "better" : "worse"
                        differences.append("\(key): \(direction) by \(String(format: "%.0f%%", abs(diff) * 100))")
                    }
                }
            }

            // Compare event placements (> 30 min shift is notable)
            for baseGene in base.genes {
                if let otherGene = other.genes.first(where: { $0.eventId == baseGene.eventId }) {
                    let timeDiff = otherGene.startTime.timeIntervalSince(baseGene.startTime)
                    if abs(timeDiff) > 30 * 60 {
                        let direction = timeDiff > 0 ? "later" : "earlier"
                        let hours = abs(timeDiff) / 3600
                        differences.append("\(baseGene.title): \(String(format: "%.1f", hours))h \(direction)")
                    }
                }
            }

            comparisons.append(ScenarioComparison(
                scenarioIndex: i,
                fitnessVsBest: other.fitness - base.fitness,
                keyDifferences: differences
            ))
        }

        return comparisons
    }
}
