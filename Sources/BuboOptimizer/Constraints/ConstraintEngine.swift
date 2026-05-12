import Foundation

// MARK: - Constraint Engine

/// Evaluates all constraints against a chromosome and computes total penalty.
public struct ConstraintEngine {
    public let constraints: [any ScheduleConstraint]

    /// Default constraints for schedule optimization.
    public static var standard: ConstraintEngine {
        ConstraintEngine(constraints: [
            NoOverlapConstraint(),
            WorkingHoursConstraint(),
            PlanningHorizonConstraint(),
            DeadlineConstraint(),
            EarliestStartConstraint(),
            TaskDependencyConstraint(),
            AtomicGroupConstraint(),
            MaxMeetingsPerDayConstraint(),
            LunchWindowConstraint(),
        ])
    }

    // MARK: - Evaluation

    /// Evaluate all constraints and return the total penalty.
    /// Hard constraint violations are multiplied by a large factor.
    public func totalPenalty(for chromosome: ScheduleChromosome, context: OptimizerContext) -> Double {
        var total = 0.0
        for constraint in constraints {
            let penalty = constraint.penalty(for: chromosome, context: context)
            if constraint.isHard {
                total += penalty * 100.0   // hard constraint multiplier
            } else {
                total += penalty
            }
        }
        return total
    }

    /// Check if a chromosome satisfies all hard constraints.
    public func isValid(_ chromosome: ScheduleChromosome, context: OptimizerContext) -> Bool {
        for constraint in constraints where constraint.isHard {
            if constraint.penalty(for: chromosome, context: context) > 0 {
                return false
            }
        }
        return true
    }

    /// Total penalty from every hard constraint. Returns `0` when the
    /// chromosome is feasible. Callers that need both "is it feasible"
    /// and "how badly does it violate" in one pass (the fitness
    /// evaluator) should use this instead of `isValid` + a separate
    /// penalty sum — otherwise every infeasible chromosome runs each
    /// hard constraint's `.penalty(...)` twice (first via `isValid`'s
    /// early-exit probe, then again in the sum), doubling the
    /// per-rejection cost on early generations where 30-50% of
    /// chromosomes are infeasible post-repair.
    public func hardPenaltySum(for chromosome: ScheduleChromosome, context: OptimizerContext) -> Double {
        var total = 0.0
        for constraint in constraints where constraint.isHard {
            total += constraint.penalty(for: chromosome, context: context)
        }
        return total
    }

    /// Return a list of violated constraint names.
    public func violations(for chromosome: ScheduleChromosome, context: OptimizerContext) -> [String] {
        constraints.compactMap { constraint in
            let penalty = constraint.penalty(for: chromosome, context: context)
            return penalty > 0 ? "\(constraint.name): \(String(format: "%.1f", penalty))" : nil
        }
    }

    /// Detailed breakdown of all constraint penalties.
    public func breakdown(for chromosome: ScheduleChromosome, context: OptimizerContext) -> [(name: String, isHard: Bool, penalty: Double)] {
        constraints.map { constraint in
            (
                name: constraint.name,
                isHard: constraint.isHard,
                penalty: constraint.penalty(for: chromosome, context: context)
            )
        }
    }
}
