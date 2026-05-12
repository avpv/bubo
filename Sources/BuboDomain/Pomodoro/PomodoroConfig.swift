import Foundation

// MARK: - Pomodoro Config

/// Concrete shape of one pomodoro session — work / break / rounds.
///
/// Lives in `Domain/` rather than `Optimizer/` because it is a stored
/// property on `CalendarEvent`, JSON-persisted by `PersistedEvent`,
/// and consumed by `PomodoroHistoryService`. Moving it here breaks the
/// Domain ↔ Optimizer dependency cycle.
public struct PomodoroConfig: Codable, Hashable, Sendable {
    public let workMinutes: Int
    public let breakMinutes: Int
    public let rounds: Int
    public let longBreakMinutes: Int

    public init(workMinutes: Int, breakMinutes: Int, rounds: Int, longBreakMinutes: Int) {
        self.workMinutes = workMinutes
        self.breakMinutes = breakMinutes
        self.rounds = rounds
        self.longBreakMinutes = longBreakMinutes
    }

    /// Wall-clock minutes from first round start to end of long break.
    /// The last round has no trailing short break, so we have
    /// `rounds` works + `rounds - 1` short breaks + optional long break.
    public var totalMinutes: Int {
        workMinutes * rounds
            + breakMinutes * max(0, rounds - 1)
            + longBreakMinutes
    }
}
