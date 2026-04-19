import Foundation

// MARK: - Task Inclusion Objective

/// Rewards the GA for including droppable tasks rather than dropping them.
/// Score is the priority-weighted fraction of droppable tasks that are
/// included, so the GA prefers to schedule high-priority tasks first.
/// Returns 1.0 when no droppable tasks exist (nothing to optimize).
///
/// Weighting also folds in the user's backlog drag order via a small boost:
/// dropping a task that sits high in the backlog (low `backlogIndex`) costs
/// more than dropping one near the bottom. The differential is small enough
/// that real priority differences still dominate, but for identical-priority
/// backlog tasks that don't all fit it forces the GA to drop the *last* one
/// instead of an arbitrary middle one — matching what the user expects when
/// they ranked tasks by dragging.
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
            let base = gene.priority + 0.1   // +0.1 floor so even low-priority tasks have some pull
            let backlogBoost: Double
            if let idx = backlogIdx[gene.eventId] {
                // earliness in [0, 1]: 1 for the very first backlog task,
                // 0 for the last. 0.5x scale keeps the boost a tiebreaker
                // — for identical priorities the early task's weight is at
                // most 1.5× the late one's, which beats arbitrary-choice
                // ties without overriding meaningful priority gaps.
                let earliness = 1.0 - Double(min(idx, spread)) / Double(spread)
                backlogBoost = 1.0 + 0.5 * earliness
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
