import Foundation

/// Defines how a local event repeats over time.
struct RecurrenceRule: Codable, Hashable {
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
