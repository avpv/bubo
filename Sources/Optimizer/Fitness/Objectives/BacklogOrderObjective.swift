import Foundation

// MARK: - #15 Backlog Order Objective

/// Rewards schedules that place backlog tasks in the user's preferred
/// order over time. Only tasks carrying a `backlogIndex` participate —
/// calendar-derived events and non-backlog optimisables are ignored.
///
/// Desired order is (priority DESC, backlogIndex ASC): HIGH-priority tasks
/// should be scheduled before lower-priority ones regardless of where they
/// sit in the drag list, and within a single priority tier the drag order
/// breaks ties. Without the priority component the GA would slavishly
/// follow drag order and schedule a HIGH task at position 4 after three
/// LOW tasks at positions 1–3.
///
/// Weight is intentionally small — strong preferences (deadlines, peak
/// energy) must still dominate the macro shape of the day.
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
public struct BacklogOrderObjective: FitnessObjective {
    public let name = "BacklogOrder"
    public var weight: Double

    public init(weight: Double = 1.5) {
        self.weight = weight
    }

    public func evaluate(chromosome: ScheduleChromosome, context: OptimizerContext) -> Double {
        let indexById = context.backlogIndexMap()
        guard !indexById.isEmpty else { return 1.0 }

        // Collect (priority, backlogIndex, startTime) for every included
        // gene that belongs to a backlog event. Dropped droppable genes
        // don't participate — a dropped task has no placement to order.
        var placements: [(priority: Double, backlogIndex: Int, start: Date)] = []
        placements.reserveCapacity(indexById.count)
        for gene in chromosome.genes where gene.isIncluded {
            if let idx = indexById[gene.eventId] {
                placements.append((gene.priority, idx, gene.startTime))
            }
        }
        // With fewer than two placements there is no pair to invert — any
        // arrangement trivially matches desired order.
        guard placements.count >= 2 else { return 1.0 }

        // Assign each placement a dense rank in (priority DESC, backlogIndex
        // ASC) order — rank 0 is the task that *should* start first.
        let n = placements.count
        let desiredOrder = placements.enumerated().sorted { lhs, rhs in
            if lhs.element.priority != rhs.element.priority {
                return lhs.element.priority > rhs.element.priority
            }
            return lhs.element.backlogIndex < rhs.element.backlogIndex
        }
        var desiredRank = [Int](repeating: 0, count: n)
        for (rank, entry) in desiredOrder.enumerated() {
            desiredRank[entry.offset] = rank
        }

        // Sort by actual start time and count inversions in the desired-
        // rank sequence. An inversion is a pair where the earlier-started
        // task has a higher desired rank (should have started later) than
        // the later-started one — i.e. the user's priority/drag order was
        // violated.
        let byStart = placements.enumerated()
            .sorted { $0.element.start < $1.element.start }
            .map { desiredRank[$0.offset] }

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
