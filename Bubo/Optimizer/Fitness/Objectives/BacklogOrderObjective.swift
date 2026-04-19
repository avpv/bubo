import Foundation

// MARK: - #15 Backlog Order Objective

/// Rewards schedules that place backlog tasks in the same order the user has
/// them in the backlog list. Only tasks carrying a `backlogIndex` participate
/// — calendar-derived events and non-backlog optimisables are ignored.
///
/// The existing priority/deadline/energy objectives already decide the macro
/// shape of the day; this one is the tiebreaker that stops the GA from
/// shuffling identical tasks into arbitrary time slots just because every
/// permutation scores the same on every other axis. Weight is intentionally
/// small — strong preferences (deadlines, peak energy) must still dominate.
///
/// Scoring: Kendall-style inversion count over included backlog genes. For
/// every ordered pair `(a, b)` where `a.backlogIndex < b.backlogIndex` but
/// `a.startTime > b.startTime`, we count one inversion. The score is
/// `1 - inversions / maxPairs`, so a schedule matching backlog order exactly
/// gets 1.0 and a fully reversed schedule gets 0.0.
struct BacklogOrderObjective: FitnessObjective {
    let name = "BacklogOrder"
    var weight: Double

    init(weight: Double = 0.5) {
        self.weight = weight
    }

    func evaluate(chromosome: ScheduleChromosome, context: OptimizerContext) -> Double {
        // Build a map of eventId → backlogIndex once per evaluation. The
        // objective only cares about events the user authored through the
        // backlog, so we filter non-tagged events out up front.
        var indexById: [String: Int] = [:]
        indexById.reserveCapacity(context.movableEvents.count)
        for event in context.movableEvents {
            if let idx = event.backlogIndex {
                indexById[event.id] = idx
            }
        }
        guard !indexById.isEmpty else { return 1.0 }

        // Collect (backlogIndex, startTime) for every included gene that
        // belongs to a backlog event. Dropped droppable genes don't
        // participate — a dropped task has no placement to order.
        var placements: [(backlogIndex: Int, start: Date)] = []
        placements.reserveCapacity(indexById.count)
        for gene in chromosome.genes where gene.isIncluded {
            if let idx = indexById[gene.eventId] {
                placements.append((idx, gene.startTime))
            }
        }
        // With fewer than two placements there is no pair to invert — any
        // arrangement trivially matches backlog order.
        guard placements.count >= 2 else { return 1.0 }

        let n = placements.count
        let maxPairs = n * (n - 1) / 2
        var inversions = 0
        for i in 0..<n {
            for j in (i + 1)..<n {
                let a = placements[i]
                let b = placements[j]
                // Canonicalise on backlog index so we only count one direction
                // per pair: the pair is inverted iff the earlier-indexed task
                // is placed strictly later in time than the later-indexed one.
                let (earlier, later) = a.backlogIndex < b.backlogIndex ? (a, b) : (b, a)
                if earlier.start > later.start {
                    inversions += 1
                }
            }
        }

        return 1.0 - Double(inversions) / Double(maxPairs)
    }
}
