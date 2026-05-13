import Foundation
import os

// MARK: - Fitness Objective Protocol

/// A single objective function that scores a schedule chromosome.
/// Higher scores = better. All scores are normalized to [0, 1].
public protocol FitnessObjective {
    var name: String { get }
    var weight: Double { get set }

    /// Evaluate the objective for a chromosome. Returns a score in [0, 1].
    func evaluate(chromosome: ScheduleChromosome, context: OptimizerContext) -> Double
}

// MARK: - Day-Partitioned Objective

/// An objective that naturally decomposes into independent per-day scores.
///
/// `BreakObjective`, `BufferObjective`, and similar aggregate-per-day
/// objectives conform so the evaluator can rescore only the days touched by a
/// mutation instead of the whole horizon. Huge savings on weekly planning
/// runs where a single mutation typically disturbs one day out of seven.
///
/// Non-conforming objectives (global structure, event-level) fall back to the
/// full-evaluation path — no correctness difference, just a missed speedup.
public protocol DayPartitionedObjective: FitnessObjective {
    /// Evaluate every populated day. Keys are `calendar.startOfDay(for:)` dates.
    func evaluatePerDay(
        chromosome: ScheduleChromosome,
        context: OptimizerContext
    ) -> [Date: Double]

    /// Evaluate a single day — the fast path for delta evaluation. The
    /// default just re-runs `evaluatePerDay` and picks the requested entry;
    /// conformers are expected to override with a scoped implementation
    /// that only visits that day's genes. Without the override, no speedup
    /// is realized over full evaluation.
    func evaluateOneDay(
        day: Date,
        chromosome: ScheduleChromosome,
        context: OptimizerContext
    ) -> Double

    /// Reduce the per-day scores to a scalar fitness in [0, 1]. Default:
    /// arithmetic mean, with an empty-day fallback of 1.0 to match the
    /// existing objectives' behaviour.
    func combinePerDay(_ perDay: [Date: Double]) -> Double
}

public extension DayPartitionedObjective {
    func evaluateOneDay(
        day: Date,
        chromosome: ScheduleChromosome,
        context: OptimizerContext
    ) -> Double {
        evaluatePerDay(chromosome: chromosome, context: context)[day] ?? 1.0
    }

    func combinePerDay(_ perDay: [Date: Double]) -> Double {
        guard !perDay.isEmpty else { return 1.0 }
        return perDay.values.reduce(0, +) / Double(perDay.count)
    }
}

// MARK: - Component-Partitioned Objective

/// An objective whose score decomposes into independent per-component
/// scores, where "component" is a weakly-connected component of the
/// `ScheduleConflictGraph`. Two genes in different components can
/// never structurally affect each other's contribution — so a
/// mutation that only touches component A doesn't require rescoring
/// component B.
///
/// Unlike `DayPartitionedObjective`, partitioning here is driven by
/// graph structure rather than the calendar. The two axes compose
/// orthogonally: an objective can conform to both and the evaluator
/// will pick whichever decomposition is cheaper for the current
/// mutation (component-level when the hit set is small; day-level
/// when a day-wide recompute is anyway needed).
public protocol ComponentPartitionedObjective: FitnessObjective {
    /// Score a single component (identified by an array of event IDs).
    /// Implementations must read *only* genes whose `eventId` is in
    /// `componentMembers`; touching other genes silently defeats the
    /// cache.
    func evaluateComponent(
        members: [String],
        chromosome: ScheduleChromosome,
        context: OptimizerContext
    ) -> Double

    /// Reduce per-component scores into a scalar fitness in [0, 1].
    /// Default: arithmetic mean, with an empty-component fallback of
    /// 1.0 so workloads without any structural coupling score
    /// neutrally.
    func combineComponents(_ perComponent: [Int: Double]) -> Double
}

public extension ComponentPartitionedObjective {
    func combineComponents(_ perComponent: [Int: Double]) -> Double {
        guard !perComponent.isEmpty else { return 1.0 }
        return perComponent.values.reduce(0, +) / Double(perComponent.count)
    }

    /// Default global evaluation: walk every component and combine.
    /// Objectives that only conform to the component protocol get a
    /// working `evaluate(chromosome:context:)` for free via this.
    func evaluate(chromosome: ScheduleChromosome, context: OptimizerContext) -> Double {
        let graph = context.ensureConflictGraph()
        let components = graph.allComponents()
        guard !components.isEmpty else { return 1.0 }
        var perComponent: [Int: Double] = [:]
        for (idx, members) in components.enumerated() {
            perComponent[idx] = evaluateComponent(
                members: members, chromosome: chromosome, context: context
            )
        }
        return combineComponents(perComponent)
    }
}
