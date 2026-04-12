import Foundation

// MARK: - Task Inclusion Objective

/// Rewards the GA for including droppable tasks rather than dropping them.
/// Score is the priority-weighted fraction of droppable tasks that are included,
/// so the GA prefers to schedule high-priority tasks first.
/// Returns 1.0 when no droppable tasks exist (nothing to optimize).
struct TaskInclusionObjective: FitnessObjective {
    let name = "TaskInclusion"
    var weight: Double

    init(weight: Double = 4.0) {
        self.weight = weight
    }

    func evaluate(chromosome: ScheduleChromosome, context: OptimizerContext) -> Double {
        let droppableGenes = chromosome.genes.filter { $0.isDroppable }
        guard !droppableGenes.isEmpty else { return 1.0 }

        var totalWeight = 0.0
        var includedWeight = 0.0
        for gene in droppableGenes {
            let w = gene.priority + 0.1   // +0.1 floor so even low-priority tasks have some pull
            totalWeight += w
            if gene.isIncluded {
                includedWeight += w
            }
        }

        guard totalWeight > 0 else { return 1.0 }
        return includedWeight / totalWeight
    }
}
