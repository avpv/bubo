import AppKit
import EventKit
import Foundation
import os
import BuboDomain

private let appleCalendarLogger = Logger(subsystem: "com.avpv.Bubo", category: "AppleCalendar")

/// Provides access to calendars configured in the native macOS Calendar.app
/// via EventKit. This includes iCloud, Exchange, Google, CalDAV, and any other
/// accounts the user has set up in System Settings → Internet Accounts.
///
/// Uses a shared EKEventStore instance and listens for external changes
/// (e.g. user edits in Calendar.app).
class AppleCalendarService {
    /// Shared event store — creating multiple instances is expensive and discouraged by Apple.
    static let shared = AppleCalendarService()

    /// Exposed for AppleRemindersService — single store for the entire app.
    static var sharedStore: EKEventStore { shared.store }

    private var store = EKEventStore()

    /// Posted when the underlying EKEventStore detects changes (events added/modified/deleted
    /// in Calendar.app or via iCloud sync). Observers should re-fetch events.
    static let calendarDataChanged = Notification.Name("AppleCalendarDataChanged")

    /// Posted when the user resolves the Calendar permission prompt (grant
    /// or deny) via the in-app Connect button. Mirrors
    /// `AppleRemindersService.authorizationDidChange` so the menu bar
    /// permission banner can drop the moment access is granted.
    static let authorizationDidChange = Notification.Name("AppleCalendarAuthorizationDidChange")

    private var storeChangedObserver: Any?
    private var wakeObserver: Any?

    /// Freshness of the change-push channel: the later of «store
    /// (re)created» and «last `EKEventStoreChanged` received». Read by
    /// `EventKitSyncCoordinator`'s self-heal to detect a dead
    /// `calendard` connection (see `CalendarEventSource`).
    private(set) var lastPushActivityAt: Date = Date()

    private init() {
        subscribeToStoreChanges()

        // The main killer of the store's XPC connection to `calendard`
        // is system sleep. Rebuild proactively on wake — invisible to
        // the user, cheap (once per wake), and it closes the window in
        // which pushes would be silently dead. The delay lets the
        // daemon and network come back before we reconnect; the posted
        // notification makes the coordinator re-sync through its usual
        // debounced path.
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                self?.handleWake()
            }
        }
    }

    deinit {
        if let observer = storeChangedObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let observer = wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
    }

    /// Forward EKEventStoreChanged to our own notification on the main
    /// queue, and record the push activity for the dead-connection
    /// detector. Re-run against the new store on every rebuild.
    private func subscribeToStoreChanges() {
        if let observer = storeChangedObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        storeChangedObserver = NotificationCenter.default.addObserver(
            forName: .EKEventStoreChanged,
            object: store,
            queue: .main
        ) { [weak self] _ in
            self?.lastPushActivityAt = Date()
            NotificationCenter.default.post(name: Self.calendarDataChanged, object: nil)
        }
    }

    private func handleWake() {
        appleCalendarLogger.info("store_rebuilt reason=wake_from_sleep")
        rebuildStore()
        NotificationCenter.default.post(name: Self.calendarDataChanged, object: nil)
    }

    /// Current authorization status for calendar access.
    static var authorizationStatus: EKAuthorizationStatus {
        EKEventStore.authorizationStatus(for: .event)
    }

    static var hasAccess: Bool {
        authorizationStatus == .fullAccess
    }

    /// Request access to the user's calendars. Returns true if access was granted.
    func requestAccess() async -> Bool {
        do {
            let granted = try await store.requestFullAccessToEvents()
            // Carry the grant result — the static authorizationStatus
            // can lag the continuation, so listeners that only consult
            // it get a stale `.notDetermined` right after a successful
            // grant. See AppleRemindersService.requestAccess for the
            // same pattern.
            NotificationCenter.default.post(
                name: Self.authorizationDidChange,
                object: nil,
                userInfo: ["granted": granted]
            )
            return granted
        } catch {
            appleCalendarLogger.error("Failed to request full access: \(error)")
            NotificationCenter.default.post(name: Self.authorizationDidChange, object: nil)
            return false
        }
    }

    /// A throwaway store for reads. The long-lived `store` exists for
    /// `EKEventStoreChanged` delivery and for writes, but READING through
    /// it has a universal failure mode: when its XPC connection to
    /// `calendard` silently dies (sleep/wake, daemon restart), the store
    /// keeps serving the snapshot it froze on — deleted events stay,
    /// new ones never appear — and `ek.refresh()` answers from the same
    /// frozen snapshot, so the per-event liveness check cannot catch it.
    /// A freshly created store connects anew and always reads the
    /// daemon's current database, whatever the account type (iCloud,
    /// Google, Exchange, CalDAV), so every read path builds one and
    /// discards it. Creation costs one XPC handshake — acceptable at
    /// sync cadence, and the pattern widgets use for every timeline
    /// refresh. The shared `store` stays untouched, so change
    /// notifications, in-flight remote refreshes, and
    /// `AppleRemindersService` are unaffected (the PR #588 failure was
    /// rebuilding the SHARED store on every sync, which killed exactly
    /// those).
    private func freshReadStore() -> EKEventStore {
        EKEventStore()
    }

    /// List all calendars available in the system Calendar.app, grouped by source/account.
    func listCalendars() -> [CalendarInfo] {
        freshReadStore().calendars(for: .event).map { cal in
            CalendarInfo(
                id: cal.calendarIdentifier,
                title: cal.title,
                accountName: cal.source.title,
                sourceId: cal.source.sourceIdentifier,
                color: cal.cgColor
            )
        }
        .sorted { a, b in
            if a.accountName != b.accountName { return a.accountName < b.accountName }
            return a.title < b.title
        }
    }

    /// List calendars grouped by account name.
    func listCalendarsByAccount() -> [(account: String, calendars: [CalendarInfo])] {
        let all = listCalendars()
        let grouped = Dictionary(grouping: all) { $0.accountName }
        return grouped
            .sorted { $0.key < $1.key }
            .map { (account: $0.key, calendars: $0.value) }
    }

    /// Ask EventKit to pull the latest data from remote calendar sources
    /// (iCloud, Google, Exchange, CalDAV). This is asynchronous — the actual
    /// data arrives later via an `EKEventStoreChanged` notification.
    ///
    /// Deliberately does NOT call `store.reset()`: `reset()` rolls back
    /// unsaved changes and invalidates every `EKEvent` / `EKReminder`
    /// the store has ever handed out (including the ones
    /// `AppleRemindersService` is holding — it shares this store), and
    /// it can abort an in-flight sync request to `calendard`. It is not
    /// a cache flush; `events(matching:)` already reads the daemon's
    /// current database state.
    func triggerRemoteRefresh() {
        store.refreshSourcesIfNecessary()
    }

    /// Rebuild the shared EventKit store. Three sanctioned, rare
    /// triggers: a TCC state change (a store created before the grant
    /// caches the pre-grant authorization and keeps returning empty
    /// results — the Settings connect flows call this once after a
    /// grant), wake from sleep (`handleWake` — proactive, because sleep
    /// is the main killer of the `calendard` connection), and the
    /// coordinator's dead-push self-heal (`rebuildForSelfHeal`).
    ///
    /// Must NOT be called on the periodic sync path: replacing the store
    /// tears down the IPC connection to `calendard` that delivers
    /// `EKEventStoreChanged` pushes, aborts any remote refresh that is
    /// still in flight, and swaps the shared store out from under
    /// `AppleRemindersService`. Rebuilding on every sync is precisely
    /// what made external edits (new / deleted events) stop reaching
    /// the app.
    func rebuildStore() {
        store = EKEventStore()
        lastPushActivityAt = Date()
        subscribeToStoreChanges()
    }

    /// Self-heal entry point for `EventKitSyncCoordinator`: rebuild the
    /// shared store because the push channel is provably dead (data
    /// changed while `EKEventStoreChanged` stayed silent). Kept as its
    /// own method so the intent is auditable at the call site — the
    /// periodic sync path must never call `rebuildStore` directly.
    func rebuildForSelfHeal() {
        appleCalendarLogger.warning("store_rebuilt reason=push_connection_dead")
        rebuildStore()
    }

    /// Fetch events from selected Apple calendars within a date range.
    /// Reads through a fresh store (see `freshReadStore`) so a stale
    /// long-lived snapshot can never serve ghost events — the universal
    /// fix for «deleted weeks ago, still shown», independent of which
    /// account the calendar belongs to.
    func fetchEvents(from: Date, to: Date, onlyCalendarIds: [String] = []) -> [CalendarEvent] {
        let readStore = freshReadStore()
        let calendars: [EKCalendar]?
        if onlyCalendarIds.isEmpty {
            calendars = nil
        } else {
            calendars = readStore.calendars(for: .event).filter {
                onlyCalendarIds.contains($0.calendarIdentifier)
            }
        }

        let predicate = readStore.predicateForEvents(withStart: from, end: to, calendars: calendars)
        let ekEvents = readStore.events(matching: predicate)

        return ekEvents.compactMap { ek in
            guard !ek.isAllDay else { return nil }
            // Skip cancelled/deleted events — remote calendars (Google,
            // Exchange, iCloud) may keep them around with a .canceled status
            // for a while before fully removing them from the database.
            guard ek.status != .canceled else { return nil }

            // Explicitly force EventKit to confirm the event still exists in the
            // local database. This catches "ghost" deleted events that EventKit's
            // index still returns when Apple Calendar is closed, even after a sync.
            guard ek.refresh() else { return nil }

            let baseId = "apple_\(ek.eventIdentifier ?? UUID().uuidString)"
            let uniqueId = "\(baseId)_\(ek.startDate.timeIntervalSince1970)"

            return CalendarEvent(
                id: uniqueId,
                title: ek.title ?? "Untitled",
                startDate: ek.startDate,
                endDate: ek.endDate,
                location: ek.location,
                description: ek.notes,
                calendarName: ek.calendar.title,
                seriesId: ek.hasRecurrenceRules ? baseId : nil,
                eventType: .standard,
                colorTag: nil
            )
        }
    }

    /// The facts `CalDAVVerificationService` needs to check each external
    /// occurrence against a CalDAV server: Bubo's occurrence/series ids
    /// (identical scheme to `fetchEvents` above so verifier output can be
    /// used as tombstone keys), the calendar + account titles for
    /// matching, and the iCalendar UID EventKit keeps in
    /// `calendarItemExternalIdentifier`. Applies the same all-day /
    /// canceled / refresh filters as `fetchEvents` — the verifier should
    /// only reason about events Bubo can actually display.
    func externalEventSyncKeys(from: Date, to: Date) -> [ExternalEventSyncKey] {
        let readStore = freshReadStore()
        let predicate = readStore.predicateForEvents(withStart: from, end: to, calendars: nil)
        return readStore.events(matching: predicate).compactMap { ek in
            guard !ek.isAllDay, ek.status != .canceled, ek.refresh() else { return nil }
            let baseId = "apple_\(ek.eventIdentifier ?? UUID().uuidString)"
            return ExternalEventSyncKey(
                occurrenceId: "\(baseId)_\(ek.startDate.timeIntervalSince1970)",
                seriesKey: ek.hasRecurrenceRules ? baseId : nil,
                calendarTitle: ek.calendar.title,
                accountName: ek.calendar.source.title,
                uid: ek.calendarItemExternalIdentifier
            )
        }
    }

    /// Create a new event in Apple Calendar.
    /// - Parameters:
    ///   - event: The event data to create.
    ///   - calendarId: The calendar identifier to add the event to. Uses the default calendar if nil.
    func createEvent(_ event: CalendarEvent, calendarId: String? = nil) throws {
        let ekEvent = EKEvent(eventStore: store)
        ekEvent.title = event.title
        ekEvent.startDate = event.startDate
        ekEvent.endDate = event.endDate
        ekEvent.location = event.location
        ekEvent.notes = event.description
        if let calendarId,
           let calendar = store.calendars(for: .event).first(where: { $0.calendarIdentifier == calendarId }) {
            ekEvent.calendar = calendar
        } else {
            ekEvent.calendar = store.defaultCalendarForNewEvents
        }
        try store.save(ekEvent, span: .thisEvent)
    }

    /// The identifier of the default calendar for new events, if available.
    var defaultCalendarId: String? {
        store.defaultCalendarForNewEvents?.calendarIdentifier
    }

    /// Shift the start and end times of an Apple Calendar event by a given number of minutes.
    func shiftEventTime(id: String, byMinutes minutes: Int) throws {
        var actualId = id.replacingOccurrences(of: "apple_", with: "")
        if let lastUnderscore = actualId.lastIndex(of: "_") {
            // Strip the timestamp we added to make it unique per occurrence
            actualId = String(actualId[..<lastUnderscore])
        }
        
        guard let ekEvent = store.event(withIdentifier: actualId) else {
            throw NSError(domain: "AppleCalendarService", code: 404, userInfo: [NSLocalizedDescriptionKey: "Event not found."])
        }
        let interval = TimeInterval(minutes * 60)
        ekEvent.startDate = ekEvent.startDate.addingTimeInterval(interval)
        ekEvent.endDate = ekEvent.endDate.addingTimeInterval(interval)
        try store.save(ekEvent, span: .thisEvent)
    }

    // MARK: - Types

    struct CalendarInfo: Identifiable {
        let id: String
        let title: String
        let accountName: String
        let sourceId: String
        let color: CGColor?

        var displayName: String {
            title
        }
    }
}
