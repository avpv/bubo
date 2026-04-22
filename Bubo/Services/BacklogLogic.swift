import Foundation

// MARK: - Backlog Logic

/// Pure functions that derive presentation state from a `BacklogTask` array.
///
/// Extracted out of `BacklogView` so smart-sort, urgent-filter, sprint-cap
/// and capacity math can be tested without standing up a SwiftUI host. The
/// view keeps its computed properties but delegates to these helpers.
///
/// All functions are deterministic and depend only on their inputs — no
/// `Date()` calls outside an injected `now` parameter, no environment reads.
enum BacklogLogic {

    // MARK: Filters

    /// Returns the subset of `tasks` that should appear in the active list:
    /// everything that is neither done nor frozen. The storage order is
    /// preserved so user drag order survives the filter.
    static func activeTasks(_ tasks: [BacklogTask]) -> [BacklogTask] {
        tasks.filter { $0.status != .done && $0.status != .frozen }
    }

    /// Returns the urgent subset — tasks whose deadline is within `days`
    /// from `now`. Used both by the "N urgent" counter and the urgent-only
    /// UI filter. Excludes done/frozen and tasks without a deadline.
    static func urgentTasks(
        _ tasks: [BacklogTask],
        withinDays days: Int = 2,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> [BacklogTask] {
        let cutoff = calendar.date(byAdding: .day, value: days, to: now) ?? now
        return tasks.filter { task in
            task.status != .done
                && task.status != .frozen
                && task.deadline != nil
                && task.deadline! <= cutoff
        }
    }

    /// True iff `task` qualifies as urgent under the same rule used by
    /// `urgentTasks` — extracted so row-level rendering can answer the
    /// question without materialising the whole subset.
    static func isUrgent(
        _ task: BacklogTask,
        withinDays days: Int = 2,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> Bool {
        guard task.status != .done, task.status != .frozen,
              let deadline = task.deadline else { return false }
        let cutoff = calendar.date(byAdding: .day, value: days, to: now) ?? now
        return deadline <= cutoff
    }

    // MARK: Smart sort

    /// Deadline-urgency + priority score. Higher = more urgent.
    /// Today / overdue dominates, tomorrow is a strong second, week-out is
    /// a nudge. Without a deadline, only priority contributes.
    static func smartScore(
        for task: BacklogTask,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> Double {
        var score = task.priority.numericValue * 100
        if let deadline = task.deadline {
            if deadline < now || calendar.isDate(deadline, inSameDayAs: now) {
                score += 1000
            } else if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now),
                      calendar.isDate(deadline, inSameDayAs: tomorrow) {
                score += 500
            } else {
                let days = max(1, calendar.dateComponents([.day], from: now, to: deadline).day ?? 7)
                score += max(0, 300 - Double(days) * 20)
            }
        }
        return score
    }

    /// Sort a task list by `smartScore`, with a stable fallback to the
    /// original (storage) order so ties don't shuffle.
    static func smartSorted(
        _ tasks: [BacklogTask],
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> [BacklogTask] {
        let indexed = tasks.enumerated().map { ($0.offset, $0.element) }
        return indexed.sorted { lhs, rhs in
            let lScore = smartScore(for: lhs.1, now: now, calendar: calendar)
            let rScore = smartScore(for: rhs.1, now: now, calendar: calendar)
            if lScore == rScore { return lhs.0 < rhs.0 }
            return lScore > rScore
        }.map(\.1)
    }

    // MARK: Sprint cap

    /// Cap a task list at `max` items — the pattern used by sprint mode,
    /// which shows "what's next" in a bigger type size without scrolling.
    static func sprintCapped(_ tasks: [BacklogTask], max: Int) -> [BacklogTask] {
        guard max > 0 else { return [] }
        return Array(tasks.prefix(max))
    }

    // MARK: Tombstone sets

    /// Tasks completed since local midnight. Drives the "N completed today"
    /// tombstone. Ordered most-recent-first so the freshest completion sits
    /// at the top of the section.
    static func completedToday(
        _ tasks: [BacklogTask],
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> [BacklogTask] {
        let startOfDay = calendar.startOfDay(for: now)
        return tasks
            .filter { $0.status == .done }
            .filter { ($0.completedAt ?? .distantPast) >= startOfDay }
            .sorted { ($0.completedAt ?? .distantPast) > ($1.completedAt ?? .distantPast) }
    }

    // MARK: Capacity

    /// Ratio of backlog workload to remaining minutes in the workday.
    /// Empty backlog = 0; workday over with any workload = 1.5 overflow
    /// sentinel (matches the colour table in `BacklogCapacityRing`).
    static func capacityFraction(
        pendingMinutes: Int,
        remainingWorkdayMinutes: Int
    ) -> Double {
        guard pendingMinutes > 0 else { return 0 }
        guard remainingWorkdayMinutes > 0 else { return 1.5 }
        return Double(pendingMinutes) / Double(remainingWorkdayMinutes)
    }

    /// Minutes left between `now` and the end of the working day, clamped
    /// to zero once the window has closed. Shares its `workingHours`
    /// definition with `OptimizerService` so the ring and the free-slot
    /// finder never disagree. When `workingDays` is non-empty and `now`
    /// lands on a day not in the set, returns zero — matches the
    /// hard-constraint view the GA uses, so the capacity ring stops
    /// claiming "6h remaining" on a day the user has already opted out
    /// of scheduling. The set uses Foundation's 1-indexed weekday
    /// convention (1 = Sunday, 7 = Saturday).
    static func remainingWorkdayMinutes(
        workingHours: ClosedRange<Int>,
        now: Date = Date(),
        calendar: Calendar = .current,
        workingDays: Set<Int> = []
    ) -> Int {
        if !workingDays.isEmpty {
            let weekday = calendar.component(.weekday, from: now)
            if !workingDays.contains(weekday) { return 0 }
        }
        guard let endOfWorkday = calendar.date(
            bySettingHour: workingHours.upperBound,
            minute: 0,
            second: 0,
            of: now
        ) else { return 0 }
        let seconds = max(0, endOfWorkday.timeIntervalSince(now))
        return Int(seconds / 60)
    }
}
