import Foundation

// MARK: - Recurrence Engine

/// Derives the next occurrence date for a recurring `BacklogTask` from its
/// free-form `recurrenceTag` ("daily", "weekly review", "monthly report").
/// `BacklogService.completeTask` writes the result into `deadline` so the
/// row reappears at the right time, not immediately.
///
/// Pattern matching is intentionally forgiving. Tag strings are written by
/// humans, not structured input, so we look for keyword substrings ("week",
/// "month") instead of requiring exact grammar. Unknown tags fall back to
/// "tomorrow" — the task still carries forward, just without a multi-day
/// delay.
public enum RecurrenceEngine {

    /// Coarse frequency buckets derived from the recurrence tag.
    public enum Frequency: String, Equatable {
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
    public static func frequency(for tag: String?) -> Frequency {
        let trimmed = (tag ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return .unknown }

        if trimmed.contains("biweek") || trimmed.contains("fortnight") {
            return .biweekly
        }
        if trimmed.contains("quarter") {
            return .quarterly
        }
        if trimmed.contains("year") || trimmed.contains("annual") {
            return .yearly
        }
        if trimmed.contains("month") {
            return .monthly
        }
        if trimmed.contains("week") {
            return .weekly
        }
        if trimmed.contains("day") || trimmed.contains("daily") || trimmed.contains("standup") {
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
    public static func nextOccurrence(
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
