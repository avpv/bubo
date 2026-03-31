import Foundation

// MARK: - Constraint Engine

/// Evaluates all constraints against a chromosome and computes total penalty.
struct ConstraintEngine {
    let constraints: [any ScheduleConstraint]

    /// Default constraints for schedule optimization.
    static var standard: ConstraintEngine {
        ConstraintEngine(constraints: [
            NoOverlapConstraint(),
            WorkingHoursConstraint(),
            PlanningHorizonConstraint(),
            DeadlineConstraint(),
            MaxMeetingsPerDayConstraint(),
            LunchWindowConstraint(),
        ])
    }

    // MARK: - Evaluation

    /// Evaluate all constraints and return the total penalty.
    /// Hard constraint violations are multiplied by a large factor.
    func totalPenalty(for chromosome: ScheduleChromosome, context: OptimizerContext) -> Double {
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
    func isValid(_ chromosome: ScheduleChromosome, context: OptimizerContext) -> Bool {
        for constraint in constraints where constraint.isHard {
            if constraint.penalty(for: chromosome, context: context) > 0 {
                return false
            }
        }
        return true
    }

    /// Return a list of violated constraint names.
    func violations(for chromosome: ScheduleChromosome, context: OptimizerContext) -> [String] {
        constraints.compactMap { constraint in
            let penalty = constraint.penalty(for: chromosome, context: context)
            return penalty > 0 ? "\(constraint.name): \(String(format: "%.1f", penalty))" : nil
        }
    }

    /// Detailed breakdown of all constraint penalties.
    func breakdown(for chromosome: ScheduleChromosome, context: OptimizerContext) -> [(name: String, isHard: Bool, penalty: Double)] {
        constraints.map { constraint in
            (
                name: constraint.name,
                isHard: constraint.isHard,
                penalty: constraint.penalty(for: chromosome, context: context)
            )
        }
    }
}
