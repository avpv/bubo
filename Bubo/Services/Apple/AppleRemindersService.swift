import EventKit
import Foundation
import os

private let logger = Logger(subsystem: "com.avpv.Bubo", category: "AppleReminders")

/// Provides read/write access to the user's Apple Reminders via EventKit.
///
/// Reuses AppleCalendarService's shared EKEventStore — Apple discourages
/// creating multiple instances ("creating multiple instances is expensive").
/// Manages its own authorization flow for the `.reminder` entity type.
@MainActor
@Observable
final class AppleRemindersService {

    static let shared = AppleRemindersService()

    /// Shared store owned by AppleCalendarService — single EKEventStore
    /// for the entire app, as Apple recommends.
    private var store: EKEventStore { AppleCalendarService.sharedStore }

    /// Posted when the EKEventStore detects external changes to reminders
    /// (e.g. user edits in Reminders.app or iCloud sync).
    nonisolated static let remindersDataChanged = Notification.Name("AppleRemindersDataChanged")

    /// Posted when the user resolves the Reminders permission prompt (grant
    /// or deny) via the in-app Connect button. Listeners — notably the menu
    /// bar's "Reminders access not granted" banner — refresh their cached
    /// `hasAccess` snapshot in response so the UI stops showing the banner
    /// the moment access is granted.
    nonisolated static let authorizationDidChange = Notification.Name("AppleRemindersAuthorizationDidChange")

    private var storeChangedObserver: Any?

    private init() {
        storeChangedObserver = NotificationCenter.default.addObserver(
            forName: .EKEventStoreChanged,
            object: nil,
            queue: .main
        ) { _ in
            NotificationCenter.default.post(name: Self.remindersDataChanged, object: nil)
        }
    }

    deinit {
        if let observer = MainActor.assumeIsolated({ storeChangedObserver }) {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    // MARK: - Authorization

    static var authorizationStatus: EKAuthorizationStatus {
        EKEventStore.authorizationStatus(for: .reminder)
    }

    static var hasAccess: Bool {
        authorizationStatus == .fullAccess
    }

    func requestAccess() async -> Bool {
        do {
            let granted = try await store.requestFullAccessToReminders()
            // Fire-and-forget signal so views that snapshot `hasAccess`
            // (e.g. the menu bar permission banner) can refresh without
            // having to poll a static EventKit property. Carry the
            // definitive `granted` result — `EKEventStore.authorizationStatus`
            // can still return `.notDetermined` for a beat after the
            // continuation resolves, and listeners that trust only the
            // static query end up stuck on the stale pre-grant state.
            NotificationCenter.default.post(
                name: Self.authorizationDidChange,
                object: nil,
                userInfo: ["granted": granted]
            )
            return granted
        } catch {
            logger.error("Failed to request full Reminders access: \(error)")
            NotificationCenter.default.post(name: Self.authorizationDidChange, object: nil)
            return false
        }
    }

    // MARK: - List Reminders Lists

    struct RemindersList: Identifiable {
        let id: String
        let title: String
        let accountName: String
        let color: CGColor?

        var displayName: String { title }
    }

    func listRemindersLists() -> [RemindersList] {
        store.calendars(for: .reminder).map { cal in
            RemindersList(
                id: cal.calendarIdentifier,
                title: cal.title,
                accountName: cal.source.title,
                color: cal.cgColor
            )
        }
        .sorted { a, b in
            if a.accountName != b.accountName { return a.accountName < b.accountName }
            return a.title < b.title
        }
    }

    func listsByAccount() -> [(account: String, lists: [RemindersList])] {
        let all = listRemindersLists()
        let grouped = Dictionary(grouping: all) { $0.accountName }
        return grouped
            .sorted { $0.key < $1.key }
            .map { (account: $0.key, lists: $0.value) }
    }

    // MARK: - Create List

    /// Creates a new Reminders list (EKCalendar with `.reminder` entityType)
    /// in the user's default Reminders source — usually iCloud, falling back
    /// to Local. Used by the backlog header's project picker «+ New
    /// Project…» to give Bubo a Reminders.app-style way to spin up an
    /// empty project without leaving the app. Returns the created list's
    /// `calendarIdentifier` so callers can immediately set it as the
    /// active project.
    ///
    /// Errors propagate: EventKit can refuse if the source is read-only
    /// (rare for the user's iCloud / Local sources but possible for
    /// shared accounts) or if the title collides on the same source.
    func createList(name: String) throws -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw NSError(
                domain: "AppleRemindersService",
                code: 400,
                userInfo: [NSLocalizedDescriptionKey: "List name can't be empty."]
            )
        }
        // Pick a writable source. `defaultCalendarForNewReminders` may be
        // nil if no list exists yet, so we fall back to the first source
        // that EventKit reports as a reminders host.
        let source: EKSource? = store.defaultCalendarForNewReminders()?.source
            ?? store.sources.first(where: { src in
                src.sourceType == .calDAV || src.sourceType == .local || src.sourceType == .exchange
            })
        guard let source else {
            throw NSError(
                domain: "AppleRemindersService",
                code: 500,
                userInfo: [NSLocalizedDescriptionKey: "No writable Reminders source available."]
            )
        }
        let calendar = EKCalendar(for: .reminder, eventStore: store)
        calendar.title = trimmed
        calendar.source = source
        try store.saveCalendar(calendar, commit: true)
        return calendar.calendarIdentifier
    }

    // MARK: - Fetch Incomplete Reminders

    /// Fetches all incomplete reminders from the specified lists (or all lists if empty).
    func fetchIncompleteReminders(fromListIds listIds: [String] = []) async -> [EKReminder] {
        let calendars: [EKCalendar]?
        if listIds.isEmpty {
            calendars = nil
        } else {
            calendars = store.calendars(for: .reminder).filter {
                listIds.contains($0.calendarIdentifier)
            }
            // If no matching calendars found, return empty
            if calendars?.isEmpty == true { return [] }
        }

        let predicate = store.predicateForIncompleteReminders(
            withDueDateStarting: nil,
            ending: nil,
            calendars: calendars
        )

        return await withCheckedContinuation { continuation in
            store.fetchReminders(matching: predicate) { reminders in
                continuation.resume(returning: reminders ?? [])
            }
        }
    }

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

    // MARK: - Complete Reminder

    /// Marks a reminder as completed in Apple Reminders.
    /// Call this when the user completes the corresponding BacklogTask in Bubo.
    func completeReminder(calendarItemId: String) throws {
        guard let reminder = store.calendarItem(withIdentifier: calendarItemId) as? EKReminder else {
            throw NSError(
                domain: "AppleRemindersService",
                code: 404,
                userInfo: [NSLocalizedDescriptionKey: "Reminder not found."]
            )
        }
        reminder.isCompleted = true
        reminder.completionDate = Date()
        try store.save(reminder, commit: true)
    }

    /// Extracts the Apple Reminders calendarItemIdentifier from a Bubo task ID.
    /// Returns nil if the task didn't originate from Reminders.
    static func remindersId(from backlogTaskId: String) -> String? {
        guard backlogTaskId.hasPrefix("reminder_") else { return nil }
        return String(backlogTaskId.dropFirst("reminder_".count))
    }

    // MARK: - Create Reminder (Export Bubo → Apple Reminders)

    /// Creates a new Apple Reminder from a BacklogTask.
    /// Returns the `calendarItemIdentifier` of the created reminder.
    func createReminder(from task: BacklogTask, inListId listId: String?) throws -> String {
        let reminder = EKReminder(eventStore: store)
        reminder.title = task.title
        reminder.priority = Self.appleRemindersPriority(from: task.priority)
        reminder.notes = Self.composeNotes(
            notes: task.notes,
            url: task.url,
            subtasks: task.subtasks,
            tags: task.tags
        )
        if let loc = task.location, !loc.isEmpty {
            reminder.location = loc
        }

        if let deadline = task.deadline {
            reminder.dueDateComponents = Self.dueDateComponents(from: deadline)
        }

        // Assign to the specified list, or default list
        if let listId,
           let calendar = store.calendars(for: .reminder).first(where: { $0.calendarIdentifier == listId }) {
            reminder.calendar = calendar
        } else {
            reminder.calendar = store.defaultCalendarForNewReminders()
        }

        if task.status == .done {
            reminder.isCompleted = true
            reminder.completionDate = task.completedAt ?? Date()
        }

        try store.save(reminder, commit: true)
        return reminder.calendarItemIdentifier
    }

    /// Updates an existing Apple Reminder with current BacklogTask values.
    /// Returns `true` if any fields were changed, `false` if the reminder
    /// already matched the task (no write was performed — saves an EventKit
    /// round-trip and avoids a superfluous store-changed notification).
    @discardableResult
    func updateReminder(calendarItemId: String, from task: BacklogTask) throws -> Bool {
        guard let reminder = store.calendarItem(withIdentifier: calendarItemId) as? EKReminder else {
            throw NSError(
                domain: "AppleRemindersService",
                code: 404,
                userInfo: [NSLocalizedDescriptionKey: "Reminder not found for update."]
            )
        }

        let newPriority = Self.appleRemindersPriority(from: task.priority)
        let newDueComponents: DateComponents? = task.deadline.map(Self.dueDateComponents(from:))
        let shouldBeDone = task.status == .done
        let newNotes = Self.composeNotes(
            notes: task.notes,
            url: task.url,
            subtasks: task.subtasks,
            tags: task.tags
        )
        let newLocation = task.location.flatMap { $0.isEmpty ? nil : $0 }

        // Field-by-field diff — skip the save if nothing actually changed.
        var didChange = false
        if reminder.title != task.title { reminder.title = task.title; didChange = true }
        if reminder.priority != newPriority { reminder.priority = newPriority; didChange = true }
        if reminder.dueDateComponents != newDueComponents {
            reminder.dueDateComponents = newDueComponents
            didChange = true
        }
        if reminder.notes != newNotes {
            reminder.notes = newNotes
            didChange = true
        }
        if reminder.location != newLocation {
            reminder.location = newLocation
            didChange = true
        }
        if reminder.isCompleted != shouldBeDone {
            reminder.isCompleted = shouldBeDone
            reminder.completionDate = shouldBeDone ? (task.completedAt ?? Date()) : nil
            didChange = true
        }

        guard didChange else { return false }
        try store.save(reminder, commit: true)
        return true
    }

    /// Deletes a reminder from Apple Reminders. Silently succeeds if the
    /// reminder no longer exists (e.g. already deleted on another device).
    func deleteReminder(calendarItemId: String) throws {
        guard let reminder = store.calendarItem(withIdentifier: calendarItemId) as? EKReminder else {
            return
        }
        try store.remove(reminder, commit: true)
    }

    /// Sets the reminder's due-date and alarms in a single write. Used by
    /// the Bubo scheduling writeback — `scheduledDate` replaces the
    /// reminder's due date so iPhone users see the time slot Bubo assigned
    /// the task, and `alarmDates` installs `EKAlarm`s so iPhone / iPad
    /// actually ring at the scheduled moment (and any user-configured
    /// lead times). Pass `nil` for `dueDate` to clear the due slot, and
    /// an empty `alarmDates` to clear all alarms. Returns `true` if
    /// anything actually changed; callers can skip logging when nothing
    /// needed writing.
    @discardableResult
    func updateReminderSchedule(
        calendarItemId: String,
        dueDate: Date?,
        alarmDates: [Date]
    ) throws -> Bool {
        guard let reminder = store.calendarItem(withIdentifier: calendarItemId) as? EKReminder else {
            throw NSError(
                domain: "AppleRemindersService",
                code: 404,
                userInfo: [NSLocalizedDescriptionKey: "Reminder not found for schedule update."]
            )
        }

        let newComponents: DateComponents? = dueDate.map(Self.dueDateComponents(from:))
        let dueChanged = reminder.dueDateComponents != newComponents

        // Compare alarms by their absolute fire-date set, ignoring order.
        // EKAlarm equality isn't suitable here — two alarms with identical
        // `absoluteDate` aren't `==` because the class doesn't override it.
        let existingDates = (reminder.alarms ?? [])
            .compactMap { $0.absoluteDate }
            .sorted()
        let desiredDates = alarmDates.sorted()
        let alarmsChanged = existingDates != desiredDates

        guard dueChanged || alarmsChanged else { return false }

        if dueChanged {
            reminder.dueDateComponents = newComponents
        }
        if alarmsChanged {
            // Drop every existing alarm and install fresh ones. Reminders
            // doesn't support partial alarm edits — wholesale replacement
            // is the supported pattern.
            for alarm in reminder.alarms ?? [] {
                reminder.removeAlarm(alarm)
            }
            for date in alarmDates {
                reminder.addAlarm(EKAlarm(absoluteDate: date))
            }
        }

        try store.save(reminder, commit: true)
        return true
    }

    /// Fetches a single reminder by its calendarItemIdentifier.
    func fetchReminder(calendarItemId: String) -> EKReminder? {
        store.calendarItem(withIdentifier: calendarItemId) as? EKReminder
    }

    /// Returns the `lastModifiedDate` of a reminder, for conflict resolution.
    func lastModified(calendarItemId: String) -> Date? {
        fetchReminder(calendarItemId: calendarItemId)?.lastModifiedDate
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
