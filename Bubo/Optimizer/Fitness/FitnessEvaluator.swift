import Foundation

// MARK: - Fitness Objective Protocol

/// A single objective function that scores a schedule chromosome.
/// Higher scores = better. All scores are normalized to [0, 1].
protocol FitnessObjective {
    var name: String { get }
    var weight: Double { get set }

    /// Evaluate the objective for a chromosome. Returns a score in [0, 1].
    func evaluate(chromosome: ScheduleChromosome, context: OptimizerContext) -> Double
}

// MARK: - Fitness Evaluator

/// Combines multiple objectives into a single weighted fitness score.
/// Also applies constraint penalties.
final class FitnessEvaluator {
    var objectives: [any FitnessObjective]
    let constraintEngine: ConstraintEngine

    init(
        objectives: [any FitnessObjective],
        constraintEngine: ConstraintEngine = .standard
    ) {
        self.objectives = objectives
        self.constraintEngine = constraintEngine
    }

    /// All default objectives with weights from preferences.
    static func standard(preferences: OptimizerPreferences) -> FitnessEvaluator {
        FitnessEvaluator(
            objectives: [
                FocusBlockObjective(weight: preferences.focusBlockWeight),
                PomodoroFitObjective(weight: preferences.pomodoroFitWeight),
                ConflictObjective(weight: preferences.conflictWeight),
                TaskPlacementObjective(weight: preferences.taskPlacementWeight),
                WeekBalanceObjective(weight: preferences.weekBalanceWeight),
                EnergyCurveObjective(weight: preferences.energyCurveWeight),
                MultiPersonObjective(weight: preferences.multiPersonWeight),
                BreakObjective(weight: preferences.breakWeight),
                DeadlineObjective(weight: preferences.deadlineWeight),
                ContextSwitchObjective(weight: preferences.contextSwitchWeight),
                BufferObjective(weight: preferences.bufferWeight),
            ],
            constraintEngine: .standard
        )
    }

    // MARK: - Evaluation

    /// Compute the total fitness for a chromosome.
    func evaluate(chromosome: ScheduleChromosome, context: OptimizerContext) -> Double {
        // Compute constraint penalty
        let penalty = constraintEngine.totalPenalty(for: chromosome, context: context)

        // Compute weighted objective sum
        let totalWeight = objectives.reduce(0.0) { $0 + $1.weight }
        guard totalWeight > 0 else { return -penalty }

        var weightedSum = 0.0
        for objective in objectives {
            let score = objective.evaluate(chromosome: chromosome, context: context)
            weightedSum += score * objective.weight
        }

        let normalizedScore = weightedSum / totalWeight

        // Fitness = objective score - constraint penalty
        return normalizedScore - penalty
    }

    /// Evaluate and assign fitness to a chromosome (mutating).
    func evaluateAndAssign(_ chromosome: inout ScheduleChromosome, context: OptimizerContext) {
        chromosome.fitness = evaluate(chromosome: chromosome, context: context)
    }

    /// Detailed breakdown of all objective scores.
    func objectiveBreakdown(
        for chromosome: ScheduleChromosome,
        context: OptimizerContext
    ) -> [String: Double] {
        var result: [String: Double] = [:]
        for objective in objectives {
            result[objective.name] = objective.evaluate(chromosome: chromosome, context: context)
        }
        return result
    }

    /// Update weights from preferences (e.g., after preference learning).
    func updateWeights(from preferences: OptimizerPreferences) {
        for i in objectives.indices {
            switch objectives[i].name {
            case "FocusBlock":      objectives[i].weight = preferences.focusBlockWeight
            case "PomodoroFit":     objectives[i].weight = preferences.pomodoroFitWeight
            case "Conflict":        objectives[i].weight = preferences.conflictWeight
            case "TaskPlacement":   objectives[i].weight = preferences.taskPlacementWeight
            case "WeekBalance":     objectives[i].weight = preferences.weekBalanceWeight
            case "EnergyBalance":   objectives[i].weight = preferences.energyCurveWeight
            case "MultiPerson":     objectives[i].weight = preferences.multiPersonWeight
            case "BreakPlacement":  objectives[i].weight = preferences.breakWeight
            case "Deadline":        objectives[i].weight = preferences.deadlineWeight
            case "ContextSwitch":   objectives[i].weight = preferences.contextSwitchWeight
            case "Buffer":          objectives[i].weight = preferences.bufferWeight
            default: break
            }
        }
    }
}
