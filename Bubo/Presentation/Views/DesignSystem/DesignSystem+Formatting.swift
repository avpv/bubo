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

    /// HH:MM-only companion to `timeFormatter`, template-derived so
    /// 12/24-hour locales both render their native form. Cached: the
    /// old per-render `DateFormatter()` in the scheduled-when chip
    /// rebuilt two formatters on every redraw of every scheduled row.
    static let shortTimeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("Hmm")
        return f
    }()

    /// Abbreviated weekday («Tue») for compact day+time labels.
    static let weekdayShortFormatter: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("EEE")
        return f
    }()

    /// Compact «day + time» label shared by every surface that names a
    /// concrete calendar landing spot — «Today 15:14», «Tomorrow 9:30»,
    /// «Tue 14:00». Today and tomorrow get human names; everything else
    /// an abbreviated weekday so the label stays narrow.
    static func dayTimeLabel(_ date: Date) -> String {
        let time = shortTimeFormatter.string(from: date)
        let cal = Calendar.current
        if cal.isDateInToday(date) { return "Today\u{00A0}\(time)" }
        if cal.isDateInTomorrow(date) { return "Tomorrow\u{00A0}\(time)" }
        return "\(weekdayShortFormatter.string(from: date))\u{00A0}\(time)"
    }

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

    /// Eyebrow weekday label for further-out day sections —
    /// «Thursday», «Friday». Used as the eyebrow above the day-section
    /// title when the date isn't today/tomorrow. Full form: the
    /// eyebrow IS the weekday's one home (§3) — the title below
    /// carries only the calendar date, so nothing abbreviates.
    /// Locale-aware via the system formatter.
    static let dayOfWeekFormatter: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("EEEE")
        return f
    }()

    /// Date-only companion for further-out day-section titles —
    /// «17 Jul». No weekday: that fact lives in the eyebrow above
    /// (PRINCIPLES §3 — the old title «Thursday, 17 Jul» under a
    /// «THU» eyebrow said the weekday twice in one header).
    static let dayMonthFormatter: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("dMMM")
        return f
    }()
}
