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
/// Scoring: Kendall-style inversion count per day. For every ordered pair
/// `(a, b)` on the same day where `a.backlogIndex < b.backlogIndex` but
/// `a.startTime > b.startTime`, we count one inversion. Each day yields
/// `1 - inversions / maxPairs`; the per-day scores are averaged into the
/// final fitness. Scoping inversions per day lets this objective conform to
/// `DayPartitionedObjective` so delta evaluation only rescores days touched
/// by a mutation — cross-day ordering is already driven by deadline/priority
/// objectives, so losing the global Kendall-tau semantics is a deliberate
/// trade for the GA's much faster inner loop.
///
/// Inversion counting itself runs in O(N log N) via merge sort, so even very
/// wide backlogs (hundreds of tasks on one day) stay cheap enough to score
/// on every population evaluation.
struct BacklogOrderObjective: DayPartitionedObjective {
    let name = "BacklogOrder"
    var weight: Double

    init(weight: Double = 0.5) {
        self.weight = weight
    }

    func evaluate(chromosome: ScheduleChromosome, context: OptimizerContext) -> Double {
        combinePerDay(evaluatePerDay(chromosome: chromosome, context: context))
    }

    func evaluatePerDay(
        chromosome: ScheduleChromosome,
        context: OptimizerContext
    ) -> [Date: Double] {
        let indexById = buildIndexMap(context)
        guard !indexById.isEmpty else { return [:] }

        let cal = context.calendar
        var byDay: [Date: [(backlogIndex: Int, start: Date)]] = [:]
        for gene in chromosome.genes where gene.isIncluded {
            guard let idx = indexById[gene.eventId] else { continue }
            let day = cal.startOfDay(for: gene.startTime)
            byDay[day, default: []].append((idx, gene.startTime))
        }

        var perDay: [Date: Double] = [:]
        perDay.reserveCapacity(byDay.count)
        for (day, placements) in byDay {
            perDay[day] = scoreDay(placements)
        }
        return perDay
    }

    func evaluateOneDay(
        day: Date,
        chromosome: ScheduleChromosome,
        context: OptimizerContext
    ) -> Double {
        let indexById = buildIndexMap(context)
        guard !indexById.isEmpty else { return 1.0 }

        let cal = context.calendar
        var placements: [(backlogIndex: Int, start: Date)] = []
        for gene in chromosome.genes where gene.isIncluded {
            guard cal.startOfDay(for: gene.startTime) == day else { continue }
            guard let idx = indexById[gene.eventId] else { continue }
            placements.append((idx, gene.startTime))
        }
        return scoreDay(placements)
    }

    // MARK: - Scoring Core

    /// Map of `eventId → backlogIndex` built lazily per evaluation call.
    /// Only events the user authored through the backlog carry an index, so
    /// calendar-derived movables drop out up front and never pay the pairwise
    /// cost.
    private func buildIndexMap(_ context: OptimizerContext) -> [String: Int] {
        var out: [String: Int] = [:]
        out.reserveCapacity(context.movableEvents.count)
        for event in context.movableEvents {
            if let idx = event.backlogIndex {
                out[event.id] = idx
            }
        }
        return out
    }

    /// Score a single day's placements. Sorts by start time, then counts
    /// inversions against the `backlogIndex` sequence via merge sort — an
    /// inversion is a pair where the earlier-started task has a higher
    /// backlog index than the later-started one, i.e. the user's drag order
    /// was violated.
    private func scoreDay(_ placements: [(backlogIndex: Int, start: Date)]) -> Double {
        // With fewer than two placements there is no pair to invert — any
        // arrangement trivially matches backlog order.
        guard placements.count >= 2 else { return 1.0 }

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
