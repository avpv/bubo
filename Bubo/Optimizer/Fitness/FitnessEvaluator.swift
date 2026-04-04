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
/// Thread safety: a fresh evaluator is created per optimization run.
/// Weights are set before the GA starts and not mutated during evolution.
final class FitnessEvaluator: @unchecked Sendable {
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
                MeetingClusteringObjective(weight: preferences.meetingClusteringWeight),
            ],
            constraintEngine: .standard
        )
    }

    // MARK: - Evaluation

    /// Compute the total fitness for a chromosome.
    /// Returns a value in [0, 1] — 0 = completely infeasible, 1 = perfect.
    func evaluate(chromosome: ScheduleChromosome, context: OptimizerContext) -> Double {
        // Hard constraint check — infeasible solutions get near-zero fitness
        // but we still give a tiny gradient based on violation magnitude
        // so the GA can evolve toward feasibility.
        if !constraintEngine.isValid(chromosome, context: context) {
            // Only use hard constraint penalties for the gradient (not soft)
            let hardPenalty = constraintEngine.constraints
                .filter { $0.isHard }
                .reduce(0.0) { $0 + $1.penalty(for: chromosome, context: context) }
            // Map penalty to (0, 0.09] — lower penalty = closer to 0.09
            // Ceiling at 0.09 ensures infeasible < feasible (which starts at 0.1)
            return 0.09 / (1.0 + hardPenalty * 0.01)
        }

        // Soft constraint penalty (only from soft constraints, already validated hard ones)
        let softPenalty = constraintEngine.constraints
            .filter { !$0.isHard }
            .reduce(0.0) { $0 + $1.penalty(for: chromosome, context: context) }

        // Compute weighted objective sum
        let totalWeight = objectives.reduce(0.0) { $0 + $1.weight }
        guard totalWeight > 0 else { return 0.1 }

        var weightedSum = 0.0
        for objective in objectives {
            let score = max(0, min(1, objective.evaluate(chromosome: chromosome, context: context)))
            weightedSum += score * objective.weight
        }

        let normalizedScore = weightedSum / totalWeight  // [0, 1]

        // Soft penalty reduces score multiplicatively
        let penaltyFactor = 1.0 / (1.0 + softPenalty * 0.01)

        // Feasible solutions: [0.1, 1.0] — always above infeasible ceiling of 0.09
        return 0.1 + normalizedScore * penaltyFactor * 0.9
    }

    /// Evaluate and assign fitness to a chromosome (mutating).
    /// Skips evaluation if the chromosome hasn't changed since last evaluation.
    func evaluateAndAssign(_ chromosome: inout ScheduleChromosome, context: OptimizerContext) {
        guard chromosome.needsEvaluation else { return }
        chromosome.fitness = evaluate(chromosome: chromosome, context: context)
        chromosome.needsEvaluation = false
    }

    /// Detailed breakdown of all objective scores (clamped to [0, 1]).
    func objectiveBreakdown(
        for chromosome: ScheduleChromosome,
        context: OptimizerContext
    ) -> [String: Double] {
        var result: [String: Double] = [:]
        for objective in objectives {
            result[objective.name] = max(0, min(1, objective.evaluate(chromosome: chromosome, context: context)))
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
            case "Buffer":              objectives[i].weight = preferences.bufferWeight
            case "MeetingClustering":   objectives[i].weight = preferences.meetingClusteringWeight
            default: break
            }
        }
    }
}
