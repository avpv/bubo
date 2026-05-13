import EventKit
import Foundation
import BuboDomain

// MARK: - AppleRemindersService — Convert (EKReminder ↔ BacklogTask)
//
// Pure conversion helpers extracted from `AppleRemindersService.swift` on
// 2026-05-13 so the service file stays under ~500 lines. Contains the
// EKReminder → BacklogTask mapper plus three groups of static helpers:
//   • Priority mapping (Bubo `TaskPriority` ↔ Apple integer priority)
//   • Due-date components (preserving date-only vs datetime granularity)
//   • Notes / URL / Subtasks / Tags codec inside `EKReminder.notes`
//
// None of these methods reach for instance state on the service (`store`,
// observers); they are pure conversions safe to call from any actor.

@MainActor
extension AppleRemindersService {

    // MARK: - Convert to BacklogTask

    /// Converts an EKReminder into a BacklogTask suitable for the Bubo backlog.
    func toBacklogTask(_ reminder: EKReminder, defaultDuration: Int = 60) -> BacklogTask {
        let priority = Self.buboPriority(fromAppleReminders: reminder.priority)

        let deadline: Date?
        if let dueDateComponents = reminder.dueDateComponents {
            deadline = Calendar.current.date(from: dueDateComponents)
        } else {
            deadline = nil
        }

        // EKReminder doesn't expose a dedicated URL slot, so we carry the
        // link in `notes` using a leading `URL:` sentinel line. Round-trips
        // cleanly with Reminders.app: the sentinel text is visible there and
        // stays intact when users edit the notes body below it. Subtasks
        // ride alongside as a `Subtasks:` markdown checklist block; tags as
        // a single `Tags: #foo #bar` line.
        let parsed = Self.extractAttachments(fromNotes: reminder.notes)

        return BacklogTask(
            id: "reminder_\(reminder.calendarItemIdentifier)",
            title: reminder.title ?? "Untitled",
            durationMinutes: defaultDuration,
            priority: priority,
            deadline: deadline,
            context: reminder.calendar.title,
            notes: parsed.notes,
            url: parsed.url,
            location: reminder.location,
            subtasks: parsed.subtasks,
            tags: parsed.tags,
            createdAt: reminder.creationDate ?? Date()
        )
    }

    // MARK: - Priority Mapping (static — pure functions, testable)

    /// Maps Bubo TaskPriority to Apple Reminders integer priority.
    ///   high → 1 (!!!)   medium → 5 (!!)   low → 9 (!)
    static func appleRemindersPriority(from priority: TaskPriority) -> Int {
        switch priority {
        case .high: return 1
        case .medium: return 5
        case .low: return 9
        }
    }

    /// Inverse mapping: Apple Reminders integer priority → Bubo TaskPriority.
    ///   0 (none) → medium (neutral default)
    ///   1...4    → high (UI shows !!!)
    ///   5        → medium (UI shows !!)
    ///   6...9    → low (UI shows !)
    static func buboPriority(fromAppleReminders raw: Int) -> TaskPriority {
        switch raw {
        case 1...4: return .high
        case 5: return .medium
        case 6...9: return .low
        default: return .medium // 0 = none
        }
    }

    // MARK: - Due Date Components (preserve date-only vs datetime granularity)

    /// Returns DateComponents suitable for `EKReminder.dueDateComponents`.
    /// If the deadline is exactly midnight local time, returns date-only
    /// components (year/month/day). This preserves the distinction Apple
    /// Reminders makes between "due today" vs "due today at 3:00 PM".
    static func dueDateComponents(from date: Date) -> DateComponents {
        let cal = Calendar.current
        let comps = cal.dateComponents([.hour, .minute, .second], from: date)
        let hasMeaningfulTime = (comps.hour ?? 0) != 0
            || (comps.minute ?? 0) != 0
            || (comps.second ?? 0) != 0

        if hasMeaningfulTime {
            return cal.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        }
        return cal.dateComponents([.year, .month, .day], from: date)
    }

    // MARK: - Notes / URL Codec

    /// Sentinel line prefix used to serialize `BacklogTask.url` inside
    /// `EKReminder.notes`. Placed on the first line so Reminders.app still
    /// renders the link as a tappable URL and users can edit the notes body
    /// below without disturbing it.
    private static let urlNotesPrefix = "URL: "

    /// Sentinel header that opens a markdown checklist block carrying
    /// `BacklogTask.subtasks`. Placed after the optional `URL:` line; each
    /// subsequent `- [ ]` / `- [x]` line is one subtask. The block ends at
    /// the first non-checkbox line so the user-authored body underneath
    /// stays free-form.
    private static let subtasksHeader = "Subtasks:"

    /// Sentinel prefix for the single-line tag sentinel
    /// (`Tags: #foo #bar`). Same shape as `URL:` — one line, parseable
    /// as a unit, easy for users to read in Reminders.app.
    private static let tagsNotesPrefix = "Tags: "

    /// Combine notes + url + subtasks + tags into a single `EKReminder.notes`
    /// string. `nil` when nothing is populated so reminders without rich
    /// data keep an empty notes slot instead of a stray blank line.
    static func composeNotes(
        notes: String?,
        url: URL?,
        subtasks: [Subtask] = [],
        tags: [String] = []
    ) -> String? {
        let body = notes?.trimmingCharacters(in: .whitespacesAndNewlines)

        var sections: [String] = []
        if let url {
            sections.append("\(urlNotesPrefix)\(url.absoluteString)")
        }
        if !subtasks.isEmpty {
            var lines: [String] = [subtasksHeader]
            for sub in subtasks {
                let mark = sub.isDone ? "x" : " "
                lines.append("- [\(mark)] \(sub.title)")
            }
            sections.append(lines.joined(separator: "\n"))
        }
        if !tags.isEmpty {
            let formatted = tags.map { "#\($0)" }.joined(separator: " ")
            sections.append("\(tagsNotesPrefix)\(formatted)")
        }
        if let body, !body.isEmpty {
            sections.append(body)
        }
        guard !sections.isEmpty else { return nil }
        return sections.joined(separator: "\n\n")
    }

    /// Backward-compatible shim that drops parsed subtasks and tags. New
    /// callers should use `extractAttachments` to receive the full set.
    static func extractURL(fromNotes raw: String?) -> (url: URL?, notes: String?) {
        let parsed = extractAttachments(fromNotes: raw)
        return (parsed.url, parsed.notes)
    }

    /// Inverse of `composeNotes`. Splits the `URL:` sentinel, the
    /// `Subtasks:` checklist block, and the `Tags:` line (each optional)
    /// from the user body. Returns `(nil, original, [], [])` when the
    /// notes don't carry any recognised sentinel so user-authored text
    /// never gets misclassified.
    static func extractAttachments(
        fromNotes raw: String?
    ) -> (url: URL?, notes: String?, subtasks: [Subtask], tags: [String]) {
        guard let raw, !raw.isEmpty else { return (nil, nil, [], []) }

        var lines = raw.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)

        // Track whether we consumed any sentinel; if we didn't, return the
        // full raw text as notes so a malformed leading line stays readable.
        var consumedAny = false

        // 1. Optional `URL:` line.
        var url: URL? = nil
        if let first = lines.first, first.hasPrefix(urlNotesPrefix) {
            let urlString = String(first.dropFirst(urlNotesPrefix.count))
                .trimmingCharacters(in: .whitespaces)
            if let parsed = URL(string: urlString) {
                url = parsed
                lines.removeFirst()
                consumedAny = true
            }
        }

        // 2. Skip blank separator lines after the URL header.
        while let first = lines.first,
              first.trimmingCharacters(in: .whitespaces).isEmpty {
            lines.removeFirst()
        }

        // 3. Optional `Subtasks:` checklist block.
        var subtasks: [Subtask] = []
        if let first = lines.first,
           first.trimmingCharacters(in: .whitespaces) == subtasksHeader {
            lines.removeFirst()
            consumedAny = true
            while let next = lines.first,
                  let parsed = parseChecklistLine(next) {
                subtasks.append(parsed)
                lines.removeFirst()
            }
        }

        // 4. Skip blank lines before the next sentinel.
        while let first = lines.first,
              first.trimmingCharacters(in: .whitespaces).isEmpty {
            lines.removeFirst()
        }

        // 5. Optional `Tags:` single line.
        var tags: [String] = []
        if let first = lines.first, first.hasPrefix(tagsNotesPrefix) {
            let payload = String(first.dropFirst(tagsNotesPrefix.count))
            tags = parseTagsLine(payload)
            lines.removeFirst()
            consumedAny = true
        }

        // 6. Skip a single blank separator before the body.
        while let first = lines.first,
              first.trimmingCharacters(in: .whitespaces).isEmpty {
            lines.removeFirst()
        }

        let bodyText = lines.joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if !consumedAny {
            // Nothing recognised — keep the original text intact in notes.
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            return (nil, trimmed.isEmpty ? nil : trimmed, [], [])
        }

        return (url, bodyText.isEmpty ? nil : bodyText, subtasks, tags)
    }

    /// Parse the payload of a `Tags:` line — a whitespace-separated list
    /// of `#tag` tokens. Tokens lacking the `#` prefix or normalising to
    /// empty strings are dropped silently.
    private static func parseTagsLine(_ payload: String) -> [String] {
        payload
            .split(whereSeparator: { $0.isWhitespace })
            .compactMap { token -> String? in
                let s = String(token)
                guard s.hasPrefix("#") else { return nil }
                return BacklogTask.normalizeTag(s)
            }
    }

    /// Parse a single `- [ ] foo` / `- [x] foo` line into a `Subtask`.
    /// Returns nil for any other shape so the parser stops cleanly at the
    /// first body line.
    private static func parseChecklistLine(_ raw: String) -> Subtask? {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        // Accept "- [ ] x", "- [x] x", "* [ ] x" — match Markdown variants.
        let prefixes = ["- [ ] ", "- [x] ", "- [X] ", "* [ ] ", "* [x] ", "* [X] "]
        for p in prefixes {
            if trimmed.hasPrefix(p) {
                let title = String(trimmed.dropFirst(p.count))
                    .trimmingCharacters(in: .whitespaces)
                guard !title.isEmpty else { return nil }
                let isDone = p.contains("x") || p.contains("X")
                return Subtask(title: title, isDone: isDone)
            }
        }
        return nil
    }
}
