import Foundation

// MARK: - Backlog Task Cohesion

/// Similarity policy for grouping backlog tasks inside a single
/// `.focusBurst` session. Pure — drive it with fixtures in tests, reuse it
/// anywhere the optimizer needs a "these-belong-together" signal.
///
/// Birman: "одна точка правды, а не каша из if'ов" — every place that
/// wanted to stitch tasks together (focus burst, manual packing,
/// future suggestion engine) pipes through this one function.
enum BacklogTaskCohesion {

    // MARK: Score Weights

    /// How many points each aligned dimension contributes. Exposed so
    /// tests can pin expectations to the declared weights instead of
    /// hard-coded numbers scattered across call sites.
    struct Weights: Equatable, Sendable {
        var sameContext: Double       = 3.0
        /// Visual grouping the user already made — strong signal even
        /// when the project / context fields are empty.
        var sameColorTag: Double      = 2.0
        var samePeriod: Double        = 1.5
        var samePriority: Double      = 1.0
        var comparableDuration: Double = 0.5
        var nearbyDeadline: Double    = 0.5

        /// Inclusive ratio window for "durations are in the same league":
        /// a 25-min task and a 50-min task score; a 25-min task and a
        /// 2-hour task don't.
        var durationRatioBounds: ClosedRange<Double> = 0.5...2.0
        /// Deadlines this many days apart still count as "nearby".
        var deadlineProximityDays: Int = 3

        static let `default` = Weights()
    }

    // MARK: Score

    /// Higher score → more alike. Zero means "no dimension aligns", and
    /// those pairs never enter a cohort regardless of the cap.
    static func score(
        _ a: BacklogTask, _ b: BacklogTask,
        weights: Weights = .default
    ) -> Double {
        var s = 0.0

        if let ac = a.context, let bc = b.context,
           !ac.isEmpty, !bc.isEmpty, ac.caseInsensitiveCompare(bc) == .orderedSame {
            s += weights.sameContext
        }

        if let at = a.colorTag, let bt = b.colorTag, at == bt {
            s += weights.sameColorTag
        }

        if let ap = a.preferredPeriod, let bp = b.preferredPeriod, ap == bp {
            s += weights.samePeriod
        }

        if a.priority == b.priority {
            s += weights.samePriority
        }

        let ratio = Double(a.durationMinutes) / max(1.0, Double(b.durationMinutes))
        if weights.durationRatioBounds.contains(ratio) {
            s += weights.comparableDuration
        }

        switch (a.deadline, b.deadline) {
        case (nil, nil):
            s += weights.nearbyDeadline
        case let (da?, db?):
            let days = abs(da.timeIntervalSince(db) / 86_400)
            if days <= Double(weights.deadlineProximityDays) {
                s += weights.nearbyDeadline
            }
        default:
            break
        }

        return s
    }

    // MARK: Pick

    /// Build a cohort: `anchor` + up to `maxCohort - 1` tasks from
    /// `pool` sorted by descending cohesion score. Tasks scoring `0`
    /// against the anchor are dropped — the point of a focus burst is a
    /// coherent block, not "top-N from a sparse backlog".
    ///
    /// Ordering tiebreakers: when two tasks tie on score the one
    /// sitting earlier in `pool` wins (the user's drag-sorted order
    /// carries intent). A `maxCohort` ≤ 1 returns `[anchor]`.
    static func pick(
        from pool: [BacklogTask],
        anchor: BacklogTask,
        maxCohort: Int,
        weights: Weights = .default
    ) -> [BacklogTask] {
        let cap = max(1, maxCohort)
        guard cap > 1 else { return [anchor] }

        let scored: [(task: BacklogTask, score: Double, index: Int)] = pool
            .enumerated()
            .compactMap { idx, task in
                guard task.id != anchor.id else { return nil }
                let s = score(anchor, task, weights: weights)
                guard s > 0 else { return nil }
                return (task: task, score: s, index: idx)
            }
            .sorted { lhs, rhs in
                if lhs.score != rhs.score { return lhs.score > rhs.score }
                return lhs.index < rhs.index
            }

        let cohortTail = scored.prefix(cap - 1).map(\.task)
        return [anchor] + cohortTail
    }

    // MARK: Build Pack

    /// Full "focus burst" packing policy in one call: applies the user's
    /// optional context filter first, and falls through to cohesion
    /// picking when the filter is ambiguous or absent.
    ///
    /// Resolution:
    /// - Context matches ≥ 2 → honour the filter verbatim, capped at
    ///   `maxTasks`. Explicit user filter always wins.
    /// - Context matches exactly 1 → anchor cohesion on that single
    ///   task so a lone match still produces a coherent burst.
    /// - Context matches 0 / no filter → anchor on the top schedulable
    ///   task and run cohesion from there.
    /// - Empty pool → empty pack (the caller reverts to a generic
    ///   single-task pomodoro).
    static func buildPack(
        from pool: [BacklogTask],
        maxTasks: Int,
        contextFilter: String?,
        weights: Weights = .default
    ) -> [BacklogTask] {
        guard let defaultAnchor = pool.first else { return [] }
        let cap = max(1, maxTasks)

        if let raw = contextFilter?.trimmingCharacters(in: .whitespaces), !raw.isEmpty {
            let matched = pool.filter {
                $0.context?.caseInsensitiveCompare(raw) == .orderedSame
            }
            if matched.count >= 2 {
                return Array(matched.prefix(cap))
            }
            if let lone = matched.first {
                return pick(from: pool, anchor: lone, maxCohort: cap, weights: weights)
            }
        }
        return pick(from: pool, anchor: defaultAnchor, maxCohort: cap, weights: weights)
    }
}
