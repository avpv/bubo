import Foundation

// MARK: - #27 Scenario Generator

/// Generates diverse schedule scenarios from GA results.
/// Returns top-K solutions that are meaningfully different from each other.
struct ScenarioGenerator {

    /// Maximum number of scenarios to return.
    var maxScenarios: Int = 3

    /// Minimum diversity threshold (0-1) between scenarios.
    var diversityThreshold: Double = 0.3

    // MARK: - Generate Scenarios

    /// Extract diverse scenarios from a sorted population.
    func generateScenarios(
        from population: [ScheduleChromosome],
        context: OptimizerContext,
        evaluator: FitnessEvaluator
    ) -> [ScheduleScenario] {
        guard !population.isEmpty else { return [] }

        var selected: [ScheduleChromosome] = []
        selected.append(population[0])  // Always include the best

        for candidate in population.dropFirst() {
            guard selected.count < maxScenarios else { break }

            // Check if candidate is diverse enough from all selected
            let isDiverse = selected.allSatisfy { existing in
                diversity(between: candidate, and: existing, context: context) >= diversityThreshold
            }

            if isDiverse {
                selected.append(candidate)
            }
        }

        return selected.map { chromosome in
            ScheduleScenario(
                genes: chromosome.genes,
                fitness: chromosome.fitness,
                objectiveBreakdown: evaluator.objectiveBreakdown(for: chromosome, context: context),
                constraintViolations: evaluator.constraintEngine.violations(for: chromosome, context: context)
            )
        }
    }

    // MARK: - Diversity Measurement

    /// Measure how different two chromosomes are (0 = identical, 1 = completely different).
    func diversity(
        between a: ScheduleChromosome,
        and b: ScheduleChromosome,
        context: OptimizerContext
    ) -> Double {
        guard !a.genes.isEmpty && !b.genes.isEmpty else { return 1.0 }

        var totalDifference = 0.0
        var comparedCount = 0

        for geneA in a.genes {
            guard let geneB = b.genes.first(where: { $0.eventId == geneA.eventId }) else {
                totalDifference += 1.0
                comparedCount += 1
                continue
            }

            // Time difference
            let timeDiff = abs(geneA.startTime.timeIntervalSince(geneB.startTime))
            let maxTimeDiff = context.planningHorizon.duration
            let normalizedTimeDiff = min(1.0, timeDiff / maxTimeDiff)

            // Day difference
            let cal = context.calendar
            let dayA = cal.startOfDay(for: geneA.startTime)
            let dayB = cal.startOfDay(for: geneB.startTime)
            let dayDiff: Double = dayA == dayB ? 0 : 0.5

            totalDifference += (normalizedTimeDiff * 0.6 + dayDiff * 0.4)
            comparedCount += 1
        }

        return comparedCount > 0 ? totalDifference / Double(comparedCount) : 0
    }

    // MARK: - Scenario Comparison

    /// Compare scenarios and highlight key differences for the user.
    func compareScenarios(_ scenarios: [ScheduleScenario]) -> [ScenarioComparison] {
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

            // Compare event placements
            for baseGene in base.genes {
                if let otherGene = other.genes.first(where: { $0.eventId == baseGene.eventId }) {
                    let timeDiff = otherGene.startTime.timeIntervalSince(baseGene.startTime)
                    if abs(timeDiff) > 30 * 60 {  // > 30 min difference
                        let direction = timeDiff > 0 ? "later" : "earlier"
                        let hours = abs(timeDiff) / 3600
                        differences.append("\(baseGene.eventId): \(String(format: "%.1f", hours))h \(direction)")
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

// MARK: - Scenario Comparison

struct ScenarioComparison {
    let scenarioIndex: Int
    let fitnessVsBest: Double
    let keyDifferences: [String]
}
