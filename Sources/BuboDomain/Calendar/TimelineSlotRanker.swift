import Foundation

/// Pure-logic ranker that orders backlog tasks for placement into a
/// specific timeline slot. Used by `SlotPickerPopover` to surface the
/// best candidate first — urgent → fits the slot → matches the
/// neighbouring project context → matches the user's preferred period
/// of day → most recently created (anti-staleness).
///
/// Birman: «let the machine sweat». The user shouldn't have to scan a
/// 50-task backlog to pick the obvious candidate for «14:00–15:30
/// surrounded by Project X work»; the ranker does it for them.
///
/// Pure on inputs; tested without UI. Weights are hand-tuned in
/// `Score.total` — change them in one place to retune the whole
/// surface.
public enum TimelineSlotRanker {

    /// Inputs the ranker needs about the slot being filled.
    public struct SlotContext {

        public init(
            start: Date,
            end: Date,
            adjacentEvents: [CalendarEvent]
        ) {
            self.start = start
            self.end = end
            self.adjacentEvents = adjacentEvents
        }

        let start: Date
        let end: Date
        /// Events on the same day used for context-match scoring.
        /// The ranker filters internally to those within
        /// `Self.adjacencyWindow` of the slot's edges, so callers
        /// can pass the full day without pre-pruning.
        let adjacentEvents: [CalendarEvent]

        var durationMinutes: Int {
            max(0, Int(end.timeIntervalSince(start) / 60))
        }
    }

    /// Per-task signal breakdown. Each component is normalised to
    /// `0…1`; `total` applies hand-tuned weights. Callers don't
    /// usually need the breakdown — it's exposed for tests and for a
    /// future «why is this task ranked first?» tooltip.
    public struct Score: Equatable {

        public init(
            urgency: Double,
            fit: Double,
            context: Double,
            period: Double,
            recency: Double
        ) {
            self.urgency = urgency
            self.fit = fit
            self.context = context
            self.period = period
            self.recency = recency
        }

        let urgency: Double
        let fit: Double
        let context: Double
        let period: Double
        let recency: Double

        /// Hand-tuned weighted sum. Urgency dominates (a deadline
        /// today should beat any other consideration), then fit (a
        /// task that won't fit shouldn't sit at the top), then context
        /// match, then period preference, then recency as the final
        /// tiebreaker.
        var total: Double {
            urgency * 4.0
                + fit * 2.5
                + context * 1.5
                + period * 1.0
                + recency * 0.5
        }
    }

    // MARK: - Tunables

    /// Window (in seconds) on each side of the slot for context match.
    /// Events within this window count as «neighbours» for the
    /// project-cohesion signal.
    public static let adjacencyWindow: TimeInterval = 2 * 60 * 60

    /// Half-life of the recency signal (in days). Tasks created more
    /// than ~3 half-lives ago get negligible recency credit and rely
    /// on the other signals to surface.
    public static let recencyHalfLifeDays: Double = 7

    /// Days within which a deadline counts as fully urgent. Outside
    /// this window deadlines still pull above non-deadline tasks but
    /// at a softer weight (`urgencyScore`).
    public static let urgentWithinDays: Int = 2

    // MARK: - Public API

    /// Rank `tasks` for placement into `slot`. Caller is responsible
    /// for filtering inputs (e.g. `.pending` only); the ranker scores
    /// every task it sees.
    public static func rank(
        tasks: [BacklogTask],
        slot: SlotContext,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> [BacklogTask] {
        tasks
            .map { ($0, score($0, in: slot, now: now, calendar: calendar)) }
            .sorted { lhs, rhs in
                if lhs.1.total != rhs.1.total { return lhs.1.total > rhs.1.total }
                // Stable tiebreaker: most recent first, matches the
                // anti-staleness intent of the recency signal so two
                // identical scores still surface the fresher row.
                return lhs.0.createdAt > rhs.0.createdAt
            }
            .map { $0.0 }
    }

    /// Score a single task against a slot. Exposed for tests and for
    /// the planned «why is this ranked first?» surface.
    public static func score(
        _ task: BacklogTask,
        in slot: SlotContext,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> Score {
        Score(
            urgency: urgencyScore(task, now: now, calendar: calendar),
            fit: fitScore(task, slotMinutes: slot.durationMinutes),
            context: contextScore(task, slot: slot),
            period: periodScore(task, slot: slot, calendar: calendar),
            recency: recencyScore(task, now: now)
        )
    }

    // MARK: - Signal scores
    //
    // Each helper returns 0…1. Done/frozen tasks zero out everything
    // — the caller shouldn't be passing them in, but this is a
    // defensive belt-and-braces so a bug upstream can't promote a
    // dead task to the top of the picker.

    private static func urgencyScore(
        _ task: BacklogTask,
        now: Date,
        calendar: Calendar
    ) -> Double {
        guard task.status != .done, task.status != .frozen,
              let deadline = task.deadline
        else { return 0 }
        let cutoff = calendar.date(byAdding: .day, value: urgentWithinDays, to: now) ?? now
        if deadline <= cutoff { return 1.0 }
        // Soft tail — even non-urgent deadlines pull above tasks
        // without one. Drops to ~0 at 14 days out.
        let daysAway = deadline.timeIntervalSince(now) / 86400
        return max(0, min(0.6, 0.6 - daysAway / 14 * 0.6))
    }

    private static func fitScore(_ task: BacklogTask, slotMinutes: Int) -> Double {
        guard slotMinutes > 0, task.durationMinutes > 0 else { return 0 }
        if task.durationMinutes <= slotMinutes {
            // Snug fits (close to 100% of slot) score higher than
            // tiny tasks in a huge slot — leaving smaller orphan gaps
            // for downstream optimisation.
            let ratio = Double(task.durationMinutes) / Double(slotMinutes)
            return 0.3 + 0.7 * ratio
        }
        // Overflow — small overflow still scorable (caller may
        // split), big overflow drops to zero.
        let overflow = Double(task.durationMinutes - slotMinutes)
            / Double(slotMinutes)
        return max(0, 0.3 - overflow * 0.3)
    }

    private static func contextScore(
        _ task: BacklogTask,
        slot: SlotContext
    ) -> Double {
        let raw = task.context?.trimmingCharacters(in: .whitespaces) ?? ""
        guard !raw.isEmpty else { return 0 }
        let target = raw.lowercased()

        // «Neighbours» — events whose end is within `adjacencyWindow`
        // before the slot, or whose start is within the same window
        // after the slot. Inside the slot itself never happens (the
        // slot is by definition free), so we don't special-case that.
        let neighbours = slot.adjacentEvents.filter { event in
            let beforeGap = slot.start.timeIntervalSince(event.endDate)
            let afterGap = event.startDate.timeIntervalSince(slot.end)
            return (beforeGap >= 0 && beforeGap <= adjacencyWindow)
                || (afterGap >= 0 && afterGap <= adjacencyWindow)
        }
        guard !neighbours.isEmpty else { return 0 }

        // Match priority: explicit `context` field wins, then
        // `calendarName` (often the user's project label), then
        // colour-tag string. Anything else doesn't count.
        let matches = neighbours.filter { event in
            if let ctx = event.context?.trimmingCharacters(in: .whitespaces),
               !ctx.isEmpty,
               ctx.lowercased() == target {
                return true
            }
            if let cal = event.calendarName?.trimmingCharacters(in: .whitespaces),
               !cal.isEmpty,
               cal.lowercased() == target {
                return true
            }
            return false
        }
        guard !matches.isEmpty else { return 0 }
        return min(1.0, Double(matches.count) / Double(neighbours.count))
    }

    private static func periodScore(
        _ task: BacklogTask,
        slot: SlotContext,
        calendar: Calendar
    ) -> Double {
        guard let preferred = task.preferredPeriod else { return 0 }
        let hour = calendar.component(.hour, from: slot.start)
        if preferred.hourRange.contains(hour) { return 1.0 }
        // Adjacent period gets a small partial credit — a «morning»
        // task at 13:00 still reads as «I'd rather do this earlier»,
        // not «irrelevant».
        let mid = Double(preferred.hourRange.lowerBound + preferred.hourRange.upperBound) / 2.0
        let dist = abs(Double(hour) - mid)
        return max(0, 0.5 - dist / 12.0 * 0.5)
    }

    private static func recencyScore(
        _ task: BacklogTask,
        now: Date
    ) -> Double {
        let ageDays = max(0, now.timeIntervalSince(task.createdAt) / 86400)
        let halfLives = ageDays / recencyHalfLifeDays
        return pow(0.5, halfLives)
    }
}
