import Foundation

// MARK: - #15 Backlog Order Objective

/// Rewards schedules that place backlog tasks in the same time-order the user
/// has them in the backlog list. Only tasks carrying a `backlogIndex`
/// participate — calendar-derived events and non-backlog optimisables are
/// ignored.
///
/// The other objectives (priority, deadline, energy, …) decide the macro
/// shape of the day; this one is the tiebreaker that stops the GA from
/// shuffling identical tasks into arbitrary time slots just because every
/// permutation scores the same on every other axis. Weight is intentionally
/// small — strong preferences (deadlines, peak energy) must still dominate.
///
/// Scoring: Kendall-style inversion count **across every included backlog
/// gene**, globally — not scoped per day. An earlier attempt was day-
/// partitioned for delta-evaluation speedups, but that made the signal
/// vanish whenever the GA spread identical tasks across multiple days: each
/// day had one or two tasks, so every day scored 1.0 trivially and the
/// objective couldn't differentiate any permutation. The global version
/// correctly penalises a Monday-Wednesday-Tuesday layout of tasks 0, 1, 2
/// (one inversion) the same way it would penalise a within-day shuffle.
///
/// Inversion counting runs in O(N log N) via merge sort, so even very wide
/// backlogs stay cheap enough to score on every population evaluation.
struct BacklogOrderObjective: FitnessObjective {
    let name = "BacklogOrder"
    var weight: Double

    init(weight: Double = 0.5) {
        self.weight = weight
    }

    func evaluate(chromosome: ScheduleChromosome, context: OptimizerContext) -> Double {
        let indexById = context.backlogIndexMap()
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

        // Sort by time, then count inversions against the backlog-index
        // sequence. An inversion is a pair where the earlier-started task
        // has a higher backlog index than the later-started one, i.e. the
        // user's drag order was violated.
        let byStart = placements
            .sorted { $0.start < $1.start }
            .map { $0.backlogIndex }

        let n = byStart.count
        let maxPairs = n * (n - 1) / 2
        guard maxPairs > 0 else { return 1.0 }

        var buffer = Array(repeating: 0, count: n)
        var work = byStart
        let inversions = mergeSortCountInversions(&work, buffer: &buffer, lo: 0, hi: n)
        return 1.0 - Double(inversions) / Double(maxPairs)
    }

    /// Classic inversion count via merge sort. `buffer` is a scratch array
    /// sized to `arr.count` supplied by the caller so the recursive calls
    /// don't keep allocating. Runs in O(n log n) time and O(n) scratch
    /// space independent of recursion depth.
    private func mergeSortCountInversions(
        _ arr: inout [Int],
        buffer: inout [Int],
        lo: Int,
        hi: Int
    ) -> Int {
        guard hi - lo > 1 else { return 0 }
        let mid = (lo + hi) / 2
        var count = mergeSortCountInversions(&arr, buffer: &buffer, lo: lo, hi: mid)
        count += mergeSortCountInversions(&arr, buffer: &buffer, lo: mid, hi: hi)
        count += mergeCountInversions(&arr, buffer: &buffer, lo: lo, mid: mid, hi: hi)
        return count
    }

    private func mergeCountInversions(
        _ arr: inout [Int],
        buffer: inout [Int],
        lo: Int,
        mid: Int,
        hi: Int
    ) -> Int {
        for i in lo..<hi { buffer[i] = arr[i] }

        var i = lo
        var j = mid
        var k = lo
        var inversions = 0
        while i < mid && j < hi {
            if buffer[i] <= buffer[j] {
                arr[k] = buffer[i]
                i += 1
            } else {
                // Every remaining element in the left half is > buffer[j],
                // so each contributes one inversion against j.
                arr[k] = buffer[j]
                inversions += mid - i
                j += 1
            }
            k += 1
        }
        while i < mid {
            arr[k] = buffer[i]
            i += 1
            k += 1
        }
        while j < hi {
            arr[k] = buffer[j]
            j += 1
            k += 1
        }
        return inversions
    }
}
