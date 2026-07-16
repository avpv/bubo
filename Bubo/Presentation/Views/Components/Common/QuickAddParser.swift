import Foundation

// MARK: - Quick Add parser
//
// One line of free text in, one interpretation out: TASK or EVENT.
// This is the brain of the unified «+ Add» front door (UX_AUDIT.md F8)
// — instead of the user choosing between «Add event» and «Add task»
// vocabularies up front, they type the thought and the rule decides.
//
// The rule is deliberately narrow and learnable (PRINCIPLES §6 — the
// machine speaks in one voice, and the user must be able to predict it):
//
//   **an explicit clock time makes it an event; everything else is a task.**
//
//   "Write report 30m"           → task, 30 min
//   "Call mom"                   → task (duration guessed downstream)
//   "Lunch with Anna 13:00"      → event today 13:00 (tomorrow if past)
//   "Standup tomorrow 9:30 15m"  → event tomorrow 09:30, 15 min
//   "Gym at 7pm 1h"              → event today 19:00, 60 min
//
// Recognised time forms: `H:MM` / `HH:MM` (24-hour) and `Npm` / `N pm`
// (12-hour), optionally prefixed with «at». Day words: «today»,
// «tomorrow» / «tmr». Weekday names and dates are v1 non-goals — the
// interpretation is previewed live in `QuickAddView` before commit, so
// anything the rule misses lands as a task the user can see and correct,
// never as a silently misplaced event.
//
// The rule can also be overridden: `Mode.task` / `Mode.event` (the
// segmented control in `QuickAddView`) pin the interpretation so the
// user who finds auto-routing inconvenient gets a dedicated task or
// event composer in the same window. Forced event with no typed time
// defaults to the next quarter-hour (`nextQuarterHour`), previewed with
// the guess tilde before commit.
//
// Pure and clock-injectable so tests can pin «rolls to tomorrow when
// the time already passed» without waiting for an actual evening.
enum QuickAddParser {

    /// Explicit override for the routing rule, chosen by the segmented
    /// control in `QuickAddView`. `.auto` keeps the original rule (an
    /// explicit clock time makes an event); `.task` / `.event` pin the
    /// interpretation so the field behaves as a dedicated task or event
    /// composer — the user picks the vocabulary instead of having to
    /// learn (or fight) the rule. Raw string so the view can persist
    /// the last choice via `@AppStorage`.
    enum Mode: String, CaseIterable {
        case auto
        case task
        case event
    }

    enum Interpretation: Equatable {
        /// `durationMinutes` is only the *explicit* trailing duration
        /// («30m»); nil means the commit path may consult
        /// `BacklogTitleParser.guessDuration` exactly like the backlog
        /// composer does.
        case task(title: String, durationMinutes: Int?)
        case event(title: String, start: Date, durationMinutes: Int)
    }

    /// Fallback event length when the text carries no explicit duration
    /// and the verb table has no guess — matches the New Event form's
    /// default 30-minute window.
    static let defaultEventMinutes = 30

    // MARK: Regexes (compiled once — parse runs on every keystroke)

    /// `13:00`, `9:30`, optionally `9:30pm`, optionally prefixed «at ».
    private static let clockTimeRegex: NSRegularExpression? = try? NSRegularExpression(
        pattern: #"(?:\bat\s+)?\b(\d{1,2}):([0-5]\d)\s*(am|pm)?\b"#,
        options: .caseInsensitive
    )

    /// `7pm`, `11 am` — hour-only 12-hour form. The meridiem is required
    /// here: a bare number without `:` or am/pm is never a time (it is
    /// far more often a count — «buy 2 lamps»).
    private static let meridiemTimeRegex: NSRegularExpression? = try? NSRegularExpression(
        pattern: #"(?:\bat\s+)?\b(1[0-2]|[1-9])\s*(am|pm)\b"#,
        options: .caseInsensitive
    )

    private static let dayWordRegex: NSRegularExpression? = try? NSRegularExpression(
        pattern: #"\b(today|tomorrow|tmr)\b"#,
        options: .caseInsensitive
    )

    // MARK: Parse

    static func parse(
        _ text: String,
        mode: Mode = .auto,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> Interpretation {
        // 1. Trailing explicit duration first («… 30m» / «… 1h30m») —
        //    same parser the backlog composer trusts, so «30m» means
        //    the same thing on every input surface.
        let (afterDuration, explicitDuration) = BacklogTitleParser.parse(text)

        // Forced task mode: never an event, whatever the text says. Any
        // time words stay in the title — the user chose the task
        // vocabulary, the machine doesn't second-guess or drop input.
        if mode == .task {
            return .task(title: afterDuration, durationMinutes: explicitDuration)
        }

        // 2. Explicit clock time → event. Colon form wins over the
        //    hour-only form when both appear (it is the more specific
        //    statement of intent). In auto mode no time means task; in
        //    forced event mode the machine fills a default start below.
        let time = firstTime(in: afterDuration)
        if mode == .auto, time == nil {
            return .task(title: afterDuration, durationMinutes: explicitDuration)
        }

        // 3. Day word (checked on the pre-time string so «tomorrow» is
        //    found regardless of its position relative to the time).
        let dayWord = firstDayWord(in: afterDuration)

        // 4. Title = text minus the time token, the day word, and any
        //    orphaned «at». Falls back like the backlog parser: never
        //    lose what the user typed, never commit an empty title.
        //    Both ranges index the same original string, so cut the
        //    later one first — removing the earlier first would shift
        //    the second range onto the wrong characters.
        var title = afterDuration
        var cuts: [NSRange] = []
        if let time { cuts.append(time.range) }
        if let dayWord { cuts.append(dayWord.range) }
        for cut in cuts.sorted(by: { $0.location > $1.location }) {
            title = removing(range: cut, from: title)
        }
        title = title
            .replacingOccurrences(
                of: #"\s+at\s*$|^\s*at\s+"#,
                with: " ",
                options: [.regularExpression, .caseInsensitive]
            )
            .replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        if title.isEmpty { title = "Untitled" }

        // 5. Anchor day: explicit word wins; otherwise today, rolling to
        //    tomorrow when the moment has already passed («Lunch 13:00»
        //    typed at 15:00 means tomorrow's lunch, not a time machine).
        //    `date(bySettingHour:)` rather than seconds-from-midnight so
        //    DST-shift days keep the wall-clock time the user typed.
        var dayStart = calendar.startOfDay(for: now)
        if dayWord?.isTomorrow == true,
           let next = calendar.date(byAdding: .day, value: 1, to: dayStart) {
            dayStart = next
        }
        let start: Date
        if let time {
            var explicit = calendar.date(
                bySettingHour: time.hour, minute: time.minute, second: 0, of: dayStart
            ) ?? dayStart.addingTimeInterval(TimeInterval((time.hour * 60 + time.minute) * 60))
            if dayWord == nil, explicit <= now,
               let next = calendar.date(byAdding: .day, value: 1, to: explicit) {
                explicit = next
            }
            start = explicit
        } else {
            // Forced event mode with no explicit time: default to the
            // next quarter-hour so ↩ always creates something sensible.
            // The live preview wears the guess tilde (§6) — the fill-in
            // is visible before commit, never silent.
            let rounded = nextQuarterHour(after: now, calendar: calendar)
            if dayWord?.isTomorrow == true {
                let hour = calendar.component(.hour, from: rounded)
                let minute = calendar.component(.minute, from: rounded)
                start = calendar.date(
                    bySettingHour: hour, minute: minute, second: 0, of: dayStart
                ) ?? rounded
            } else {
                start = rounded
            }
        }

        // 6. Event length: explicit duration → verb guess («meeting» ≈
        //    60 min) → the form's default 30.
        let minutes = explicitDuration
            ?? BacklogTitleParser.guessDuration(for: title)
            ?? defaultEventMinutes

        return .event(title: title, start: start, durationMinutes: minutes)
    }

    /// True when the text carries an explicit clock time token — the
    /// signal `QuickAddView` uses to decide whether a forced-event
    /// start was typed by the user or guessed by the machine (and so
    /// must wear the §6 tilde in the preview).
    static func hasExplicitTime(_ text: String) -> Bool {
        let (afterDuration, _) = BacklogTitleParser.parse(text)
        return firstTime(in: afterDuration) != nil
    }

    /// Next quarter-hour boundary strictly after `now` — the default
    /// start for a forced-event commit that carries no explicit time.
    /// Strictly after, so an event created exactly on a boundary never
    /// starts in the past.
    static func nextQuarterHour(after now: Date, calendar: Calendar = .current) -> Date {
        let minute = calendar.component(.minute, from: now)
        let advance = 15 - (minute % 15)
        let bumped = calendar.date(byAdding: .minute, value: advance, to: now) ?? now
        let second = calendar.component(.second, from: bumped)
        return bumped.addingTimeInterval(TimeInterval(-second))
    }

    // MARK: Time extraction

    private struct TimeMatch {
        let range: NSRange
        let hour: Int
        let minute: Int
    }

    private struct DayWordMatch {
        let range: NSRange
        let isTomorrow: Bool
    }

    private static func firstTime(in text: String) -> TimeMatch? {
        let range = NSRange(text.startIndex..., in: text)

        if let regex = clockTimeRegex,
           let match = regex.firstMatch(in: text, range: range),
           let hourRange = Range(match.range(at: 1), in: text),
           let minuteRange = Range(match.range(at: 2), in: text),
           let hour = Int(text[hourRange]),
           let minute = Int(text[minuteRange]) {
            let meridiem = substring(match.range(at: 3), in: text)?.lowercased()
            if let normalized = normalizedHour(hour, meridiem: meridiem) {
                return TimeMatch(range: match.range, hour: normalized, minute: minute)
            }
        }

        if let regex = meridiemTimeRegex,
           let match = regex.firstMatch(in: text, range: range),
           let hourRange = Range(match.range(at: 1), in: text),
           let hour = Int(text[hourRange]),
           let meridiem = substring(match.range(at: 2), in: text)?.lowercased(),
           let normalized = normalizedHour(hour, meridiem: meridiem) {
            return TimeMatch(range: match.range, hour: normalized, minute: 0)
        }

        return nil
    }

    /// 12-hour → 24-hour, or validation for the 24-hour form.
    /// «12am» = 00, «12pm» = 12 — the two cases people reliably get
    /// wrong, pinned by tests.
    private static func normalizedHour(_ hour: Int, meridiem: String?) -> Int? {
        switch meridiem {
        case "am": return hour == 12 ? 0 : (1...11 ~= hour ? hour : nil)
        case "pm": return hour == 12 ? 12 : (1...11 ~= hour ? hour + 12 : nil)
        default:   return 0...23 ~= hour ? hour : nil
        }
    }

    private static func firstDayWord(in text: String) -> DayWordMatch? {
        guard let regex = dayWordRegex else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              let word = substring(match.range(at: 1), in: text)?.lowercased() else {
            return nil
        }
        return DayWordMatch(range: match.range, isTomorrow: word != "today")
    }

    // MARK: Small helpers

    private static func substring(_ nsRange: NSRange, in text: String) -> String? {
        guard nsRange.location != NSNotFound,
              let range = Range(nsRange, in: text) else { return nil }
        return String(text[range])
    }

    private static func removing(range nsRange: NSRange, from text: String) -> String {
        guard let range = Range(nsRange, in: text) else { return text }
        var copy = text
        copy.replaceSubrange(range, with: " ")
        return copy
    }
}
