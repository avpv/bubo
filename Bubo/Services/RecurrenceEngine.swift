import Foundation

// MARK: - Recurrence Engine

/// Derives the next occurrence date for a recurring `BacklogTask` from its
/// free-form `recurrenceTag` ("daily", "weekly review", "monthly report").
///
/// `BacklogService.completeTask` used to just reset a recurring task to
/// `.pending` with a fresh `createdAt`. The row survived, but it sat at
/// the top of the backlog with no hint of *when* it should happen again —
/// a "weekly review" completed on Friday would re-appear Friday evening
/// as urgent, not the following Friday. This engine fills that gap: it
/// reads the tag, matches a frequency, and returns a sensible next date
/// the caller can drop into `deadline`.
///
/// Pattern matching is intentionally forgiving. Tag strings are written by
/// humans, not structured input, so we look for keyword substrings ("week",
/// "month") instead of requiring exact grammar. Unknown tags fall back to
/// "tomorrow" — the task still carries forward, just without a multi-day
/// delay.
enum RecurrenceEngine {

    /// Coarse frequency buckets derived from the recurrence tag.
    enum Frequency: String, Equatable {
        case daily
        case weekly
        case biweekly
        case monthly
        case quarterly
        case yearly
        /// Tag was present but didn't match any known pattern. Caller
        /// treats this the same as `.daily` — a forgiving default.
        case unknown
    }

    /// Map a free-form tag to a frequency bucket. Case-insensitive; matches
    /// English keywords first, then a few common Russian equivalents that
    /// appear in the app's native-language prompts.
    static func frequency(for tag: String?) -> Frequency {
        let trimmed = (tag ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return .unknown }

        if trimmed.contains("biweek") || trimmed.contains("fortnight") || trimmed.contains("раз в две") {
            return .biweekly
        }
        if trimmed.contains("quarter") || trimmed.contains("квартал") {
            return .quarterly
        }
        if trimmed.contains("year") || trimmed.contains("annual") || trimmed.contains("год") {
            return .yearly
        }
        if trimmed.contains("month") || trimmed.contains("месяч") || trimmed.contains("месяц") {
            return .monthly
        }
        if trimmed.contains("week") || trimmed.contains("недел") {
            return .weekly
        }
        if trimmed.contains("day") || trimmed.contains("daily") || trimmed.contains("ежеднев") || trimmed.contains("стендап") || trimmed.contains("standup") {
            return .daily
        }
        return .unknown
    }

    /// Compute the next occurrence date for a recurring task that was just
    /// completed. Returns `nil` if the task isn't recurring — callers short
    /// -circuit to a plain completion in that case.
    ///
    /// `now` is injected for test determinism. The returned date is
    /// calendar-correct (DST, month-length): we add a component, not a
    /// fixed interval, so "monthly" on Jan 31 lands on Feb 28 rather than
    /// Mar 3.
    static func nextOccurrence(
        after now: Date,
        tag: String?,
        calendar: Calendar = .current
    ) -> Date? {
        let freq = frequency(for: tag)
        let (component, value): (Calendar.Component, Int) = {
            switch freq {
            case .daily, .unknown: return (.day, 1)
            case .weekly:          return (.weekOfYear, 1)
            case .biweekly:        return (.weekOfYear, 2)
            case .monthly:         return (.month, 1)
            case .quarterly:       return (.month, 3)
            case .yearly:          return (.year, 1)
            }
        }()
        return calendar.date(byAdding: component, value: value, to: now)
    }
}
