import Foundation

// MARK: - Task Inclusion Objective

/// Rewards the GA for including droppable tasks rather than dropping them.
/// Score is the priority-weighted fraction of droppable tasks that are
/// included, so the GA prefers to schedule high-priority tasks first.
/// Returns 1.0 when no droppable tasks exist (nothing to optimize).
///
/// Weighting folds in the user's backlog drag order as a pure tiebreaker:
/// among tasks with identical priority, dropping one that sits higher in
/// the backlog (low `backlogIndex`) costs slightly more than dropping one
/// near the bottom. The position boost is capped well below a single
/// priority tier, so a HIGH-priority task at the bottom of the backlog is
/// never dropped in favor of a MEDIUM/LOW task at the top.
struct TaskInclusionObjective: FitnessObjective {
    let name = "TaskInclusion"
    var weight: Double

    init(weight: Double = 4.0) {
        self.weight = weight
    }

    func evaluate(chromosome: ScheduleChromosome, context: OptimizerContext) -> Double {
        let droppableGenes = chromosome.genes.filter { $0.isDroppable }
        guard !droppableGenes.isEmpty else { return 1.0 }

        let backlogIdx = context.backlogIndexMap()
        // Compute the maximum index actually present so the boost is dense
        // over what the GA is currently considering — sparse `backlogIndex`
        // values (e.g. after some tasks were filtered out earlier) still map
        // to a clean [0, 1] earliness ratio.
        let maxIdx = backlogIdx.values.max() ?? 0
        let spread = max(1, maxIdx)

        var totalWeight = 0.0
        var includedWeight = 0.0
        for gene in droppableGenes {
            // Squaring the priority sharpens the gap between tiers so
            // HIGH (1.00) clearly dominates MEDIUM (0.36) and LOW (0.16).
            // Without this amplification a MEDIUM task at the top of the
            // backlog could out-weigh a HIGH task at the bottom once the
            // position boost is applied — dropping the user's most
            // important task in favor of a lower-priority one.
            let base = pow(gene.priority + 0.1, 2)
            let backlogBoost: Double
            if let idx = backlogIdx[gene.eventId] {
                // earliness in [0, 1]: 1 for the very first backlog task,
                // 0 for the last. Boost is capped at 1.1× so it only
                // breaks ties *within* a priority tier — a top-of-backlog
                // MEDIUM (0.36 × 1.1 = 0.396) still scores far below a
                // bottom-of-backlog HIGH (1.00 × 1.0 = 1.00).
                let earliness = 1.0 - Double(min(idx, spread)) / Double(spread)
                backlogBoost = 1.0 + 0.1 * earliness
            } else {
                // Non-backlog droppable (e.g. focus-block fillers) — no
                // user-stated order, so leave the weight unchanged.
                backlogBoost = 1.0
            }
            let w = base * backlogBoost
            totalWeight += w
            if gene.isIncluded {
                includedWeight += w
            }
        }

        guard totalWeight > 0 else { return 1.0 }
        return includedWeight / totalWeight
    }
}
