import Foundation

/// Defines how a local event repeats over time.
struct RecurrenceRule: Codable, Hashable {
    let type: RecurrenceType
    let intervalMinutes: Int
    let repeatCount: Int

    /// Human-readable summary, e.g. "4x every 25 min"
    var displayText: String {
        let interval = DS.formatMinutes(intervalMinutes)
        return "\(repeatCount)x every \(interval)"
    }

    /// Total span in minutes (from first event start to last event start).
    var totalSpanMinutes: Int {
        intervalMinutes * (repeatCount - 1)
    }
}

enum RecurrenceType: String, Codable, Hashable, CaseIterable {
    case pomodoro
    case custom

    var label: String {
        switch self {
        case .pomodoro: return "Pomodoro"
        case .custom: return "Custom"
        }
    }
}

// MARK: - Presets

extension RecurrenceRule {
    /// Classic Pomodoro: 25 min work, 5 min break = 30 min cycle, 4 rounds
    static let pomodoro = RecurrenceRule(type: .pomodoro, intervalMinutes: 30, repeatCount: 4)

    /// Short Pomodoro: 15 min work, 5 min break = 20 min cycle, 4 rounds
    static let pomodoroShort = RecurrenceRule(type: .pomodoro, intervalMinutes: 20, repeatCount: 4)

    /// Long Pomodoro: 50 min work, 10 min break = 60 min cycle, 3 rounds
    static let pomodoroLong = RecurrenceRule(type: .pomodoro, intervalMinutes: 60, repeatCount: 3)
}
