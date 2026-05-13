import Foundation
import SwiftData
import os
import BuboDomain

private let reminderServiceLogger = Logger(subsystem: "com.avpv.Bubo", category: "ReminderService")

// MARK: - Reminder Service (Orchestrator)
//
// This was a 700-line god-object that owned EventKit sync timers, the
// notification firing pipeline, three persistence stores, and the
// in-memory event source of truth. The mechanical pieces have been
// extracted into:
//
//   - `EventKitSyncCoordinator` — periodic sync, post-sync follow-ups,
//     calendar-data observer, on-disk cache.
//   - `NotificationScheduler` — per-event timers, fired-key dedup,
//     UNNotificationCenter delivery.
//   - `LocalEventStore` / `ExcludedOccurrenceStore` /
//     `ReminderOverrideStore` — CloudKit-safe persistence.
//
// What's left here is the orchestration that was load-bearing and
// can't move without breaking the public API: in-memory `upcomingEvents`
// and `localEvents`, computed view properties (`allEvents`,
// `eventsByDay`, `badgeCount`), and the wiring that ties the four
// services together. Everything else is delegation.
@MainActor
@Observable
class ReminderService {
    /// How many days ahead to fetch events. Used as the ceiling for the
    /// badge time window. Kept here for source-compat with views.
    static let fetchWindowDays = 7

    var upcomingEvents: [CalendarEvent] = []
    var localEvents: [CalendarEvent] = []

    /// Computed proxies into `EventKitSyncCoordinator` so views keep
    /// reading these off `ReminderService`. The Observation framework
    /// tracks the underlying property accesses transparently.
    var lastSyncDate: Date? { syncCoordinator.lastSyncDate }
    var syncError: String? { syncCoordinator.syncError }
    var isSyncing: Bool { syncCoordinator.isSyncing }
    var isUsingCache: Bool { syncCoordinator.isUsingCache }

    /// Aggregated persistence error surfaced to the UI. Picks the first
    /// non-nil error across the three stores so Settings shows one
    /// warning instead of three.
    var lastPersistenceError: String? {
        localEventStore.lastError
            ?? excludedOccurrenceStore.lastError
            ?? reminderOverrideStore.lastError
            ?? eventAttributeOverrideStore.lastError
    }

    private var settings: ReminderSettings

    // Sub-services. All four are owned by this orchestrator and live
    // for the lifetime of the app.
    private let scheduler: NotificationScheduler
    private let syncCoordinator: EventKitSyncCoordinator
    /// Typed by protocol so tests can swap in `InMemoryLocalEventStore`
    /// (etc.) without spinning up SwiftData. The concrete implementation
    /// in production is the CloudKit-backed `LocalEventStore`.
    private let localEventStore: any LocalEventStoring
    private let excludedOccurrenceStore: any ExcludedOccurrenceStoring
    private let reminderOverrideStore: any ReminderOverrideStoring
    private let eventAttributeOverrideStore: any EventAttributeOverrideStoring

    /// Calendar access abstracted for the same reason the stores are —
    /// tests need to drive create/shift calls without a real EKEventStore.
    /// Production receives `AppleCalendarService.shared`.
    private let calendarSource: any CalendarEventSource

    private var excludedOccurrences: Set<String> = []
    private var localRemindersOverrides: [String: [Int]] = [:]
    private var eventAttributeOverrides: [String: EventAttributeOverride] = [:]

    private nonisolated(unsafe) var settingsObserver: Any?
    private nonisolated(unsafe) var snoozeObserver: Any?
    private nonisolated(unsafe) var cloudImportObserver: Any?

    /// IDs of events currently playing their disintegration animation.
    /// These events are kept in the list briefly after ending so the
    /// dust effect can finish.
    private(set) var disintegratingEventIDs: Set<String> = []

    var allEvents: [CalendarEvent] {
        let expandedLocal = localEvents.flatMap {
            RecurrenceExpander.expand($0, excludedIds: excludedOccurrences)
        }
        return (upcomingEvents + expandedLocal)
            .filter { $0.isUpcoming || disintegratingEventIDs.contains($0.id) }
            .sorted { $0.startDate < $1.startDate }
    }

    func beginDisintegration(for eventID: String) {
        disintegratingEventIDs.insert(eventID)
    }

    func completeDisintegration(for eventID: String) {
        disintegratingEventIDs.remove(eventID)
    }

    /// Count of real (non-disintegrating) upcoming events — used to
    /// decide when to show the empty state so it appears before the
    /// dust settles.
    var nonDisintegratingEventCount: Int {
        allEvents.filter { !disintegratingEventIDs.contains($0.id) }.count
    }

    /// Number of remaining events to show as a badge on the menu bar
    /// icon.
    var badgeCount: Int {
        guard settings.showBadgeCount else { return 0 }
        let calendar = Calendar.current
        let now = Date()

        let cutoff: Date
        switch settings.badgeCountMode {
        case .wholeDay:
            cutoff = calendar.startOfDay(for: now).addingTimeInterval(24 * 60 * 60)
        case .timeWindow:
            cutoff = now.addingTimeInterval(TimeInterval(settings.badgeTimeWindowHours) * 60 * 60)
        }

        return allEvents.filter { $0.endDate > now && $0.startDate < cutoff }.count
    }

    /// Events grouped by day for display, including days with no events.
    var eventsByDay: [(date: Date, events: [CalendarEvent])] {
        let calendar = Calendar.current
        let grouped = Dictionary(grouping: allEvents) { event in
            calendar.startOfDay(for: event.startDate)
        }
        let today = calendar.startOfDay(for: Date())
        var results: [(date: Date, events: [CalendarEvent])] = []
        for offset in 0..<Self.fetchWindowDays {
            guard let day = calendar.date(byAdding: .day, value: offset, to: today) else { continue }
            results.append((date: day, events: grouped[day] ?? []))
        }
        return results
    }

    /// Production initializer. Builds the SwiftData-backed stores from
    /// the two containers. Tests should use the designated initializer
    /// below and inject in-memory or fake stores instead.
    convenience init(
        settings: ReminderSettings,
        eventCacheContainer: ModelContainer,
        userEventsContainer: ModelContainer
    ) {
        self.init(
            settings: settings,
            eventCacheContainer: eventCacheContainer,
            localEventStore: LocalEventStore(container: userEventsContainer),
            excludedOccurrenceStore: ExcludedOccurrenceStore(container: userEventsContainer),
            reminderOverrideStore: ReminderOverrideStore(container: userEventsContainer),
            eventAttributeOverrideStore: EventAttributeOverrideStore(container: userEventsContainer)
        )
    }

    /// Designated initializer. Takes stores and the calendar source by
    /// protocol so tests can drive the orchestrator with `InMemory*`
    /// doubles + `FakeCalendarEventSource` instead of SwiftData and
    /// EventKit.
    init(
        settings: ReminderSettings,
        eventCacheContainer: ModelContainer,
        localEventStore: any LocalEventStoring,
        excludedOccurrenceStore: any ExcludedOccurrenceStoring,
        reminderOverrideStore: any ReminderOverrideStoring,
        eventAttributeOverrideStore: any EventAttributeOverrideStoring,
        calendarSource: any CalendarEventSource = AppleCalendarService.shared
    ) {
        self.settings = settings
        self.localEventStore = localEventStore
        self.excludedOccurrenceStore = excludedOccurrenceStore
        self.reminderOverrideStore = reminderOverrideStore
        self.eventAttributeOverrideStore = eventAttributeOverrideStore
        self.calendarSource = calendarSource
        self.scheduler = NotificationScheduler(settings: settings)
        self.syncCoordinator = EventKitSyncCoordinator(
            eventCacheContainer: eventCacheContainer,
            settings: settings,
            calendarSource: calendarSource
        )

        // All stored properties exist — safe to wire up the closures
        // that capture `self`.
        self.syncCoordinator.overridesProvider = { [weak self] in
            self?.localRemindersOverrides ?? [:]
        }
        self.syncCoordinator.attributeOverridesProvider = { [weak self] in
            self?.eventAttributeOverrides ?? [:]
        }
        self.syncCoordinator.onEventsUpdated = { [weak self] events, _ in
            guard let self = self else { return }
            self.upcomingEvents = events
            self.scheduler.pruneFiredReminders(keepingEventIds: Set(events.map { $0.id }))
            self.scheduler.schedule(events)
        }

        loadLocalEvents()
        loadLocalRemindersOverrides()
        loadEventAttributeOverrides()
        wireObservers()
    }

    private func wireObservers() {
        // Reconcile after CloudKit lands a remote batch — collapses
        // duplicates and picks up edits from other devices.
        cloudImportObserver = NotificationCenter.default.addObserver(
            forName: CloudKitSyncMonitor.didFinishImport,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.reconcileAfterCloudImport()
            }
        }

        snoozeObserver = NotificationCenter.default.addObserver(
            forName: .snoozeReminder,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self,
                  let event = notification.userInfo?["event"] as? CalendarEvent,
                  let minutes = notification.userInfo?["minutes"] as? Int else { return }
            Task { @MainActor in
                self.snoozeReminder(for: event, minutes: minutes)
            }
        }

        settingsObserver = NotificationCenter.default.addObserver(
            forName: ReminderSettings.settingsDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.onSettingsChanged()
            }
        }
    }

    deinit {
        if let observer = snoozeObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let observer = settingsObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let observer = cloudImportObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    private func onSettingsChanged() {
        // Re-sync immediately (drops external events if disabled) and
        // restart the timer with the new interval.
        syncCoordinator.syncNow()
        syncCoordinator.startSyncTimer()
    }

    func updateSettings(_ settings: ReminderSettings) {
        self.settings = settings
        scheduler.updateSettings(settings)
        syncCoordinator.updateSettings(settings)
        scheduler.rescheduleAll(allEvents)
    }

    // MARK: - Sync (delegated)

    func startSync() { syncCoordinator.start() }
    func stopSync() {
        syncCoordinator.stop()
        scheduler.cancelAll()
    }

    func syncNow() { syncCoordinator.syncNow() }

    // MARK: - Local Events

    func addCalendarEvent(_ event: CalendarEvent, calendarId: String? = nil) {
        do {
            // Pomodoro events expand into work + break + long break events.
            if event.eventType == .pomodoro, event.recurrenceRule?.isPomodoro == true {
                let expanded = RecurrenceExpander.expand(event)
                for occurrence in expanded {
                    // Each expanded event is individual (no recurrence rule).
                    let calEvent = CalendarEvent(
                        id: occurrence.id,
                        title: occurrence.title,
                        startDate: occurrence.startDate,
                        endDate: occurrence.endDate,
                        location: occurrence.location,
                        description: occurrence.description,
                        calendarName: occurrence.calendarName,
                        eventType: occurrence.eventType
                    )
                    try calendarSource.createEvent(calEvent, calendarId: calendarId)
                }
            } else {
                try calendarSource.createEvent(event, calendarId: calendarId)
            }
            syncCoordinator.syncNow()
        } catch {
            reminderServiceLogger.error("Failed to create Apple Calendar event: \(error)")
        }
    }

    func addLocalEvent(_ event: CalendarEvent) {
        localEvents.append(event)
        localEventStore.save(localEvents)
        scheduler.schedule(RecurrenceExpander.expand(event, excludedIds: excludedOccurrences))
    }

    func removeLocalEvent(id: String) {
        if let event = localEvents.first(where: { $0.id == id }) {
            let expanded = RecurrenceExpander.expand(event, excludedIds: excludedOccurrences)
            for occurrence in expanded { scheduler.cancel(eventId: occurrence.id) }
        }
        excludedOccurrences = excludedOccurrences.filter { !$0.hasPrefix(id) }
        excludedOccurrenceStore.save(excludedOccurrences)
        localEvents.removeAll { $0.id == id }
        localEventStore.save(localEvents)
    }

    func excludeOccurrence(occurrenceId: String) {
        excludedOccurrences.insert(occurrenceId)
        excludedOccurrenceStore.save(excludedOccurrences)
        scheduler.cancel(eventId: occurrenceId)
    }

    func seriesEvent(for event: CalendarEvent) -> CalendarEvent? {
        guard let sid = event.seriesId else { return nil }
        return localEvents.first { $0.id == sid }
    }

    func updateLocalEvent(_ event: CalendarEvent) {
        guard let index = localEvents.firstIndex(where: { $0.id == event.id }) else { return }
        let oldExpanded = RecurrenceExpander.expand(localEvents[index], excludedIds: excludedOccurrences)
        for occurrence in oldExpanded { scheduler.cancel(eventId: occurrence.id) }
        localEvents[index] = event
        localEventStore.save(localEvents)
        scheduler.schedule(RecurrenceExpander.expand(event, excludedIds: excludedOccurrences))
    }

    private func loadLocalEvents() {
        localEvents = localEventStore.loadAll()
            .filter { $0.isUpcoming || $0.recurrenceRule != nil }
        excludedOccurrences = excludedOccurrenceStore.loadAll()
    }

    // MARK: - Local Reminder Overrides

    func updateLocalReminder(for eventId: String, minutes: [Int]?) {
        localRemindersOverrides[eventId] = minutes ?? []
        reminderOverrideStore.save(localRemindersOverrides)

        // Apply immediately so the user sees the change without waiting
        // for the next sync.
        if let idx = upcomingEvents.firstIndex(where: { $0.id == eventId }) {
            upcomingEvents[idx].customReminderMinutes = minutes
            scheduler.schedule([upcomingEvents[idx]])
            syncCoordinator.cacheEvents(upcomingEvents)
        } else if let idx = localEvents.firstIndex(where: { $0.id == eventId }) {
            localEvents[idx].customReminderMinutes = minutes
            scheduler.schedule(
                RecurrenceExpander.expand(localEvents[idx], excludedIds: excludedOccurrences)
            )
        }
    }

    private func loadLocalRemindersOverrides() {
        localRemindersOverrides = reminderOverrideStore.loadAll()
    }

    // MARK: - External Event Attribute Overrides

    /// Persist user-set color/context for an event Bubo doesn't own
    /// (Apple Calendar). External events live in EventKit, so we keep a
    /// side table keyed by `seriesId ?? event.id` — one write reaches
    /// every occurrence of a recurring series. An override with both
    /// fields nil/empty is removed.
    func updateEventAttributes(
        for event: CalendarEvent,
        colorTag: EventColorTag?,
        context: String?
    ) {
        let trimmed = context?.trimmingCharacters(in: .whitespaces)
        let normalized = (trimmed?.isEmpty ?? true) ? nil : trimmed
        let override = EventAttributeOverride(colorTag: colorTag, context: normalized)
        let key = EventKitSyncCoordinator.attributeKey(for: event)
        if override.isEmpty {
            eventAttributeOverrides.removeValue(forKey: key)
        } else {
            eventAttributeOverrides[key] = override
        }
        eventAttributeOverrideStore.save(eventAttributeOverrides)

        // Apply immediately to every visible occurrence that resolves
        // to the same key — the editor user expects every Tuesday-1:1
        // to repaint, not just the one they opened. Then push the
        // updated snapshot so a cold start before the next live sync
        // still shows the choice.
        var changed = false
        for i in upcomingEvents.indices
        where EventKitSyncCoordinator.attributeKey(for: upcomingEvents[i]) == key {
            upcomingEvents[i].colorTag = colorTag
            upcomingEvents[i].context = normalized
            changed = true
        }
        if changed {
            syncCoordinator.cacheEvents(upcomingEvents)
        }
    }

    private func loadEventAttributeOverrides() {
        eventAttributeOverrides = eventAttributeOverrideStore.loadAll()
    }

    /// Re-overlay the current override dictionaries onto the in-memory
    /// upcoming-events snapshot. Used when the dictionaries change for
    /// a reason other than a direct user edit (e.g. a CloudKit batch
    /// landing edits made on another device) so the UI catches up
    /// without waiting for the next live sync.
    private func reapplyOverridesToUpcoming() {
        guard !upcomingEvents.isEmpty else { return }
        let overlaid = syncCoordinator.applyAllOverrides(to: upcomingEvents)
        if overlaid != upcomingEvents {
            upcomingEvents = overlaid
            syncCoordinator.cacheEvents(upcomingEvents)
        }
    }

    // MARK: - Reminder Intervals (delegated)

    var defaultReminderMinutesList: [Int] { scheduler.defaultReminderMinutesList }
    func activeReminderMinutes(for event: CalendarEvent) -> [Int] {
        scheduler.activeReminderMinutes(for: event)
    }

    // MARK: - CloudKit Reconcile

    /// Called after `NSPersistentCloudKitContainer` finishes an import.
    /// Reloads the three user-event collections so edits from other
    /// devices become visible without a restart, and re-saves to
    /// collapse any duplicates CloudKit's merge introduced.
    private func reconcileAfterCloudImport() {
        loadLocalEvents()
        loadLocalRemindersOverrides()
        loadEventAttributeOverrides()
        // Writing back flushes duplicate-collapse to disk so we don't
        // keep re-deduplicating on every read.
        localEventStore.save(localEvents)
        excludedOccurrenceStore.save(excludedOccurrences)
        reminderOverrideStore.save(localRemindersOverrides)
        eventAttributeOverrideStore.save(eventAttributeOverrides)
        // Re-overlay the freshly-imported overrides onto the upcoming
        // events already on screen — otherwise an edit from another
        // device wouldn't be visible until the next live sync.
        reapplyOverridesToUpcoming()
    }

    // MARK: - Snooze

    func snoozeReminder(for event: CalendarEvent, minutes: Int) {
        if event.isLocalEvent {
            let interval = TimeInterval(minutes * 60)
            let updated = CalendarEvent(
                id: event.id,
                title: event.title,
                startDate: event.startDate.addingTimeInterval(interval),
                endDate: event.endDate.addingTimeInterval(interval),
                location: event.location,
                description: event.description,
                calendarName: event.calendarName,
                customReminderMinutes: event.customReminderMinutes,
                recurrenceRule: event.recurrenceRule,
                seriesId: event.seriesId,
                eventType: event.eventType
            )
            updateLocalEvent(updated)
        } else {
            do {
                try calendarSource.shiftEventTime(id: event.id, byMinutes: minutes)
            } catch {
                reminderServiceLogger.error("Failed to shift Apple Calendar event time: \(error)")
            }
        }
    }
}
