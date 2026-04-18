import Foundation

// MARK: - Precedence Objective (Soft)
//
// The hard `TaskDependencyConstraint` only kicks in when a dependent
// starts *before* its prerequisite ends. This soft objective rewards
// keeping that gap *tight* — a dependent placed three days after its
// prerequisite is feasible but wasteful, and repair won't touch it
// because no hard constraint is violated.
//
// Score interpretation:
//   1.0 → every dependency pair scheduled back-to-back (gap ≤ target)
//   ~0.6 → average gap around 1 working day
//   0.0 → every pair spans the full horizon
//
// Paired with the new `TaskDependencyConstraint` repair logic, this
// gives the GA a continuous gradient toward tight chains without
// deleting the hard-violation floor that keeps truly infeasible
// solutions out of the population.

struct PrecedenceObjective: ComponentPartitionedObjective {
    let name = "Precedence"
    var weight: Double

    /// Ideal maximum gap between a prerequisite's end and a dependent's
    /// start — defaults to one working day (8 hours). Gaps below this
    /// score near 1.0; larger gaps decay smoothly.
    let targetGapSeconds: TimeInterval

    init(weight: Double = 0.5, targetGapSeconds: TimeInterval = 8 * 3600) {
        self.weight = weight
        self.targetGapSeconds = max(1, targetGapSeconds)
    }

    func evaluateComponent(
        members: [String],
        chromosome: ScheduleChromosome,
        context: OptimizerContext
    ) -> Double {
        // Convert member list to a lookup set once — membership tests
        // below are the inner loop. An empty component scores 1.0
        // (neutral) because it has no edges to violate.
        let memberSet = Set(members)
        guard !memberSet.isEmpty else { return 1.0 }

        var geneByEvent: [String: ScheduleGene] = [:]
        geneByEvent.reserveCapacity(memberSet.count)
        for gene in chromosome.genes where gene.isIncluded && memberSet.contains(gene.eventId) {
            geneByEvent[gene.eventId] = gene
        }
        var fixedEndByEvent: [String: Date] = [:]
        for event in context.fixedEvents { fixedEndByEvent[event.id] = event.endDate }

        var totalScore = 0.0
        var pairs = 0

        for event in context.movableEvents
        where memberSet.contains(event.id) && !event.dependsOn.isEmpty {
            guard let depGene = geneByEvent[event.id] else { continue }
            for prereqId in event.dependsOn {
                let prereqEnd: Date
                if let g = geneByEvent[prereqId] {
                    prereqEnd = g.endTime
                } else if !memberSet.contains(prereqId),
                          let externalGene = chromosome.genes.first(
                              where: { $0.eventId == prereqId && $0.isIncluded }) {
                    // Cross-component prereq: union-find should normally
                    // fold it into the same component, but defensive
                    // fallback for malformed graphs.
                    prereqEnd = externalGene.endTime
                } else if let fixedEnd = fixedEndByEvent[prereqId] {
                    prereqEnd = fixedEnd
                } else {
                    continue
                }

                pairs += 1
                let gap = depGene.startTime.timeIntervalSince(prereqEnd)

                if gap < 0 {
                    totalScore += 0
                    continue
                }

                let ratio = gap / targetGapSeconds
                totalScore += exp(-ratio)
            }
        }

        guard pairs > 0 else { return 1.0 }
        return totalScore / Double(pairs)
    }
}
