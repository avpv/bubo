import SwiftUI

extension DS {
    // MARK: Snooze Options

    struct SnoozeOption: Identifiable {
        let id: Int
        let minutes: Int
        let label: String

        init(_ minutes: Int) {
            self.id = minutes
            self.minutes = minutes
            self.label = DS.formatMinutes(minutes)
        }
    }

    static let snoozeOptions: [SnoozeOption] = [
        SnoozeOption(2),
        SnoozeOption(5),
        SnoozeOption(10),
        SnoozeOption(15),
        SnoozeOption(20),
    ]

    // MARK: Ordinal Formatting

    static func formatOrdinal(_ n: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .ordinal
        return formatter.string(from: NSNumber(value: n)) ?? "\(n)"
    }

    // MARK: Time Formatting

    static func formatMinutes(_ minutes: Int) -> String {
        if minutes >= 60 {
            let h = minutes / 60
            let m = minutes % 60
            return m == 0 ? "\(h)\u{00A0}h" : "\(h)\u{00A0}h\u{00A0}\(m)\u{00A0}min"
        }
        return "\(minutes)\u{00A0}min"
    }

    // MARK: Shared Formatters

    /// HIG: Respect user's locale time format (12h vs 24h).
    static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.timeStyle = .short
        return f
    }()

    /// HIG: Use locale-aware formatting for day section headers.
    static let daySectionFormatter: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("EEEEMMMd")
        return f
    }()

    /// Short companion to `daySectionFormatter` — abbreviated weekday
    /// + day + abbreviated month. Used to follow «Today» / «Tomorrow»
    /// in the day-section header so the actual date stays on screen
    /// (e.g. «Today \u{00B7} Tue, 6 May»). Locale-aware — order and
    /// punctuation come from the system formatter.
    static let daySectionShortFormatter: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("EEEdMMM")
        return f
    }()
}
