import Foundation

// MARK: - Pomodoro Defaults
//
// Smart defaults for a Pomodoro session derived from a target total
// duration. Used by "Convert to Pomodoro" so the user gets sensible
// work/break/rounds without opening a form — Birman: let the machine sweat,
// not the user.
//
// Algorithm: keep the canonical 25-min work / 5-min break ratio, fit as
// many complete rounds as possible inside `durationMinutes`. The last
// round has no trailing break, so:
//
//   total(rounds) = rounds * work + (rounds - 1) * break
//                 = rounds * (work + break) - break
//
// Solving `total ≤ D` for `rounds` gives `rounds ≤ (D + break) / (work + break)`.

public struct PomodoroDefaults: Equatable, Sendable {
    public let work: Int
    public let breakDur: Int
    public let rounds: Int
    /// Long-break minutes after all rounds. `0` = disabled.
    public let longBreak: Int

    /// Length of one work + break cycle in minutes.
    public var cycleMinutes: Int { work + breakDur }

    /// Total minutes occupied by all rounds (including breaks but not the
    /// trailing one). Lets callers verify the suggestion fits the source
    /// event's window before committing.
    public var totalMinutes: Int {
        work * rounds + breakDur * max(0, rounds - 1) + longBreak
    }

    /// Suggest defaults for an event of `durationMinutes`.
    ///
    /// Returns at least 1 round (so even short events convert cleanly when
    /// the caller has already confirmed they're long enough). Caps at 8
    /// rounds — beyond that the user's calling it a deep-work session, not
    /// a Pomodoro.
    public static func suggested(for durationMinutes: Int) -> PomodoroDefaults {
        let work = 25
        let breakDur = 5
        let cycle = work + breakDur
        // (D + break) / cycle — see file comment for derivation.
        let raw = (max(0, durationMinutes) + breakDur) / cycle
        let rounds = max(1, min(8, raw))
        return PomodoroDefaults(
            work: work,
            breakDur: breakDur,
            rounds: rounds,
            longBreak: 0
        )
    }

    /// Minimum source-event duration that yields at least one full work
    /// segment. Below this, "Convert to Pomodoro" is meaningless and is
    /// hidden from the UI.
    public static let minimumConvertibleMinutes: Int = 25
}
