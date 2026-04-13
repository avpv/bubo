import Foundation

// MARK: - #27 Scenario Generator

/// Generates diverse schedule scenarios from GA results.
/// Returns top-K solutions that are meaningfully different from each other.
struct ScenarioGenerator {

    /// Maximum number of scenarios to return.
    var maxScenarios: Int = 3

    /// Minimum diversity threshold (0-1) between scenarios.
    var diversityThreshold: Double = 0.15

    // MARK: - Generate Scenarios

    /// Extract diverse scenarios from a sorted population.
    /// Uses progressive diversity relaxation: first tries the full threshold,
    /// then halves it on each pass to fill remaining slots. This ensures
    /// users get multiple scenarios even when the population is fairly converged.
    func generateScenarios(
        from population: [ScheduleChromosome],
        context: OptimizerContext,
        evaluator: FitnessEvaluator
    ) -> [ScheduleScenario] {
        guard !population.isEmpty else { return [] }

        var selected: [ScheduleChromosome] = []
        selected.append(population[0])  // Always include the best

        // Progressive relaxation: try full threshold first, halve on each pass
        var threshold = diversityThreshold
        let minThreshold = diversityThreshold * 0.1

        while selected.count < maxScenarios && threshold >= minThreshold {
            for candidate in population.dropFirst() {
                guard selected.count < maxScenarios else { break }
                // Skip if already selected (by identity check on genes)
                if selected.contains(where: { $0.genes == candidate.genes }) { continue }

                let isDiverse = selected.allSatisfy { existing in
                    diversity(between: candidate, and: existing, context: context) >= threshold
                }

                if isDiverse {
                    selected.append(candidate)
                }
            }
            threshold *= 0.5
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
    /// Delegates to `ScheduleChromosome.distance(to:)` for a single source of truth on
    /// genotypic distance. The context-aware variant adds day-difference weighting on top.
    func diversity(
        between a: ScheduleChromosome,
        and b: ScheduleChromosome,
        context: OptimizerContext
    ) -> Double {
        guard !a.genes.isEmpty && !b.genes.isEmpty else { return 1.0 }

        // Base genotypic distance (time displacement + inclusion diffs)
        let baseDistance = a.distance(to: b)

        // Enrich with day-level difference for scenario variety
        var dayDiffTotal = 0.0
        var count = 0
        let cal = context.calendar

        for geneA in a.genes where geneA.isIncluded {
            guard let geneB = b.genes.first(where: { $0.eventId == geneA.eventId && $0.isIncluded }) else {
                continue
            }
            let dayA = cal.startOfDay(for: geneA.startTime)
            let dayB = cal.startOfDay(for: geneB.startTime)
            if dayA != dayB { dayDiffTotal += 0.5 }
            count += 1
        }

        let dayFactor = count > 0 ? dayDiffTotal / Double(count) : 0

        // Blend: 70% genotypic distance, 30% day-level difference, clamped to [0, 1]
        return min(1.0, baseDistance * 0.7 + dayFactor * 0.3)
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

// MARK: - Scenario Comparison

struct ScenarioComparison: Sendable {
    let scenarioIndex: Int
    let fitnessVsBest: Double
    let keyDifferences: [String]
}
