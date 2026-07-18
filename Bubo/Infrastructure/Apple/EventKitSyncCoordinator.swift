import Foundation
import SwiftData
import os
import BuboDomain

private let eventKitSyncLogger = Logger(subsystem: "com.avpv.Bubo", category: "EventKitSyncCoordinator")

// MARK: - EventKit Sync Coordinator

/// Owns the EventKit-side of `ReminderService`: the periodic sync timer,
/// the post-sync follow-up cascade that exists to work around
/// `calendard` daemon throttling, the in-flight refresh task, and the
/// disk cache write-back. Pulled out of `ReminderService` so that class
/// stops carrying ~200 lines of plumbing for a single concern.
///
/// Boundary: the coordinator does not own `upcomingEvents`. It calls the
/// `onEventsUpdated` closure with the freshly-fetched and override-applied
/// list, and the orchestrator decides what to do with them (publish to
/// the UI, hand them to the notification scheduler, etc.). That keeps
/// the coordinator stateless w.r.t. UI presentation and trivially
/// testable — drive it with a mock `EventFetching` and assert what it
/// emits.
@MainActor
@Observable
final class EventKitSyncCoordinator {
    /// How many days ahead to fetch events. Mirrored from the legacy
    /// constant on `ReminderService` so existing call sites keep working.
    static let fetchWindowDays = ReminderService.fetchWindowDays

    private(set) var lastSyncDate: Date?
    private(set) var syncError: String?
    private(set) var isSyncing: Bool = false
    private(set) var isUsingCache: Bool = false

    /// True when the last successful sync is older than `staleThreshold`
    /// AND the watchdog's self-heal attempt could not refresh it. The
    /// popover status row and the menu-bar icon read this to surface
    /// «sync silently died» — Apple Calendar's per-account ⚠️ has no
    /// EventKit equivalent, so pipeline freshness is the honest signal
    /// Bubo can actually stand behind.
    private(set) var isStale: Bool = false

    /// Emitted whenever a fresh `[CalendarEvent]` slice is available
    /// (live sync, follow-up fetch, or cached load). The orchestrator
    /// reads this slice into its in-memory state and calls into the
    /// scheduler. Optional so this class can be unit-tested without
    /// wiring the closure.
    var onEventsUpdated: (([CalendarEvent], Source) -> Void)?

    /// Distinguishes a live sync from a cached load so the orchestrator
    /// can flip its `isUsingCache` flag accordingly. Live sync clears it.
    enum Source { case live, cache }

    private var settings: ReminderSettings
    private let eventCache: EventCache
    /// Calendar access abstracted behind a protocol so tests can drive
    /// the coordinator with `FakeCalendarEventSource` — EventKit requires
    /// entitlements and user consent, neither of which XCTest can
    /// provide. Production wires in `AppleCalendarService.shared`.
    private let calendarSource: any CalendarEventSource
    /// Closure handing the coordinator the latest reminder overrides
    /// without forcing it to import or reference the override store
    /// directly. Decouples the two services. Mutable so the orchestrator
    /// can swap it in after `init` (avoids a chicken-and-egg with `self`
    /// in the parent's init list).
    var overridesProvider: () -> [String: [Int]] = { [:] }
    /// Closure handing the coordinator the latest per-event color/context
    /// overrides for external events. Same decoupling motivation as
    /// `overridesProvider`: the coordinator doesn't import the store type.
    var attributeOverridesProvider: () -> [String: EventAttributeOverride] = { [:] }

    private nonisolated(unsafe) var syncTimer: Timer?
    private nonisolated(unsafe) var watchdogTimer: Timer?
    private nonisolated(unsafe) var pendingPostSyncTask: Task<Void, Never>?
    private nonisolated(unsafe) var pendingAppleRefreshTask: Task<Void, Never>?
    private nonisolated(unsafe) var calendarObserver: Any?

    /// Set on first successful live sync. Guards against the cached
    /// load overwriting fresh data when both happen in a tight window.
    private var hasCompletedLiveSync: Bool = false

    /// Last event slice emitted through `onEventsUpdated` from a live
    /// fetch. The post-sync cascade compares against this so it only
    /// emits when something actually changed — otherwise the UI and the
    /// notification scheduler would churn at every 4/12/30/60 s step
    /// after every sync.
    private var lastEmittedEvents: [CalendarEvent]?

    init(
        eventCacheContainer: ModelContainer,
        settings: ReminderSettings,
        calendarSource: any CalendarEventSource = AppleCalendarService.shared
    ) {
        self.eventCache = EventCache(modelContainer: eventCacheContainer)
        self.settings = settings
        self.calendarSource = calendarSource

        // Auto-sync when Calendar.app data changes (edits, iCloud sync).
        // Debounced via `scheduleAppleCalendarRefresh` because
        // `EKEventStoreChanged` can fire in bursts.
        calendarObserver = NotificationCenter.default.addObserver(
            forName: AppleCalendarService.calendarDataChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.scheduleAppleCalendarRefresh()
            }
        }
    }

    deinit {
        if let observer = calendarObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        pendingAppleRefreshTask?.cancel()
        pendingPostSyncTask?.cancel()
        syncTimer?.invalidate()
        watchdogTimer?.invalidate()
    }

    func updateSettings(_ settings: ReminderSettings) {
        self.settings = settings
    }

    // MARK: - Lifecycle

    func start() {
        loadCachedEvents()
        syncNow()
        startSyncTimer()
        startWatchdog()
    }

    func stop() {
        syncTimer?.invalidate()
        syncTimer = nil
        watchdogTimer?.invalidate()
        watchdogTimer = nil
        pendingPostSyncTask?.cancel()
        pendingPostSyncTask = nil
    }

    func startSyncTimer() {
        syncTimer?.invalidate()
        let interval = TimeInterval(settings.syncIntervalMinutes * 60)
        syncTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.syncNow()
            }
        }
    }

    // MARK: - Staleness Watchdog

    /// A sync is «stale» when the last successful refresh is older than
    /// three sync intervals, floored at 15 minutes. Three intervals — a
    /// single missed timer tick (Timer coalescing around app nap /
    /// sleep-wake is routine) must not alarm; two consecutive misses
    /// plus slack means the loop is actually dead. Pure and static so
    /// tests can drive it with a simulated clock.
    static func isStale(lastSync: Date?, now: Date, intervalMinutes: Int) -> Bool {
        // Never-synced is not «stale» — that state is already reported
        // through `syncError` / the permission banners; staleness is
        // specifically «it worked, then silently stopped».
        guard let lastSync else { return false }
        let threshold = max(TimeInterval(intervalMinutes) * 60 * 3, 15 * 60)
        return now.timeIntervalSince(lastSync) > threshold
    }

    /// Once a minute, check the age of `lastSyncDate` independently of
    /// the sync timer itself — the whole point is to catch the sync
    /// timer dying (invalidated without restart, lost across
    /// sleep/wake). Generous tolerance keeps it cheap.
    private func startWatchdog() {
        watchdogTimer?.invalidate()
        let timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.watchdogTick()
            }
        }
        timer.tolerance = 10
        watchdogTimer = timer
    }

    /// Heal first, alarm second: a stale pipeline gets its timer re-armed
    /// and an immediate `syncNow()` — a successful sync clears `isStale`
    /// on the spot, so the user only ever sees the warning when the
    /// retry could not refresh (access revoked mid-flight, EventKit
    /// wedged). `now` is injectable so tests can simulate elapsed time.
    func watchdogTick(now: Date = Date()) {
        guard settings.isCalendarSyncEnabled else {
            isStale = false
            return
        }
        guard Self.isStale(lastSync: lastSyncDate, now: now, intervalMinutes: settings.syncIntervalMinutes) else {
            isStale = false
            return
        }
        eventKitSyncLogger.warning("sync_stale last_sync_age_s=\(Int(now.timeIntervalSince(self.lastSyncDate ?? now)))")
        isStale = true
        startSyncTimer()
        syncNow()
    }

    private func scheduleAppleCalendarRefresh() {
        pendingAppleRefreshTask?.cancel()
        pendingAppleRefreshTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            self?.syncNow()
        }
    }

    // MARK: - Sync

    func syncNow() {
        guard settings.isCalendarSyncEnabled else {
            eventKitSyncLogger.info("sync_skipped reason=disabled")
            syncError = "Calendar sync disabled"
            isUsingCache = false
            isStale = false
            lastEmittedEvents = []
            onEventsUpdated?([], .live)
            return
        }

        guard calendarSource.hasAccess else {
            eventKitSyncLogger.warning("sync_skipped reason=no_access")
            syncError = "Calendar access not granted"
            return
        }

        let startedAt = Date()
        eventKitSyncLogger.info("sync_started")

        isSyncing = true
        syncError = nil

        // Ask EventKit to pull fresh data from remote calendar servers
        // (iCloud, Google, Exchange, CalDAV). The pull is async — when it
        // lands, `EKEventStoreChanged` fires and the observer in `init`
        // schedules another sync, so late-arriving remote changes reach
        // us without polling. The store itself is long-lived on purpose:
        // an earlier revision rebuilt it here on every sync, which tore
        // down the `calendard` IPC connection that delivers those change
        // pushes — external edits (new / deleted events) then simply
        // never arrived until the next timer tick, and often not even
        // then, because the rebuild also aborted the in-flight refresh.
        calendarSource.triggerRemoteRefresh()

        let events = fetchAndApplyOverrides()

        lastSyncDate = Date()
        isSyncing = false
        isUsingCache = false
        isStale = false
        hasCompletedLiveSync = true

        lastEmittedEvents = events
        onEventsUpdated?(events, .live)

        Task {
            await eventCache.save(events: events)
        }

        schedulePostSyncRefresh()

        let durationMs = Int(Date().timeIntervalSince(startedAt) * 1000)
        eventKitSyncLogger.info("sync_completed events=\(events.count) duration_ms=\(durationMs)")
    }

    /// Re-fetches events on a cascading delay schedule. The remote
    /// refresh requested by `syncNow` is asynchronous, and while its
    /// completion normally lands as `EKEventStoreChanged` (which
    /// re-enters `syncNow` via the observer), Calendar.app being closed
    /// makes `calendard` slow and occasionally silent about remote
    /// pulls — so we re-read at 4 / 12 / 30 / 60 second intervals as a
    /// safety net for late deletes and updates. The interleaved
    /// `triggerRemoteRefresh` prods are cheap: `refreshSourcesIfNecessary`
    /// throttles itself and no longer resets the store.
    private func schedulePostSyncRefresh() {
        pendingPostSyncTask?.cancel()
        pendingPostSyncTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            self?.fetchAndUpdate()

            self?.calendarSource.triggerRemoteRefresh()

            try? await Task.sleep(for: .seconds(12))
            guard !Task.isCancelled else { return }
            self?.fetchAndUpdate()

            self?.calendarSource.triggerRemoteRefresh()

            try? await Task.sleep(for: .seconds(30))
            guard !Task.isCancelled else { return }
            self?.fetchAndUpdate()

            self?.calendarSource.triggerRemoteRefresh()

            try? await Task.sleep(for: .seconds(60))
            guard !Task.isCancelled else { return }
            self?.fetchAndUpdate()
        }
    }

    /// Lightweight re-fetch invoked by the post-sync cascade. Skips the
    /// remote refresh trigger (avoids infinite loop) and only emits when
    /// the event set actually changed — otherwise the UI would churn
    /// every 4 / 12 / 30 / 60 seconds after every sync.
    private func fetchAndUpdate() {
        guard settings.isCalendarSyncEnabled, calendarSource.hasAccess else { return }

        let events = fetchAndApplyOverrides()
        guard events != lastEmittedEvents else { return }

        lastSyncDate = Date()
        isStale = false
        lastEmittedEvents = events
        onEventsUpdated?(events, .live)

        Task {
            await eventCache.save(events: events)
        }
    }

    private func fetchAndApplyOverrides() -> [CalendarEvent] {
        let now = Date()
        let endDate = Calendar.current.date(byAdding: .day, value: Self.fetchWindowDays, to: now) ?? now

        var events = calendarSource.fetchEvents(
            from: now,
            to: endDate,
            onlyCalendarIds: settings.selectedCalendarIds
        )

        events = applyAllOverrides(to: events)
        return events.sorted { $0.startDate < $1.startDate }
    }

    /// Layer reminder-minute and color/context overrides onto a slice
    /// of events. Idempotent — applying the same overrides twice is a
    /// no-op, so it's safe to run on already-overlaid input (e.g. the
    /// override-applied snapshot we keep in the on-disk cache). Reused
    /// at every event-emission point: live fetch, cached load, and the
    /// re-application path triggered by user edits.
    func applyAllOverrides(to events: [CalendarEvent]) -> [CalendarEvent] {
        let overrides = overridesProvider()
        let attributes = attributeOverridesProvider()
        var result = events
        for i in result.indices {
            let uniqueId = result[i].id

            // Reminder-minute overrides keep the legacy two-step lookup
            // (per-occurrence shadows series) because the existing
            // editor writes only the per-occurrence key. Re-targeting
            // those is a separate change.
            let seriesMins = result[i].seriesId.flatMap { overrides[$0] }
            let activeMins = overrides[uniqueId] ?? seriesMins
            result[i].customReminderMinutes = (activeMins?.isEmpty ?? true) ? nil : activeMins

            // Color and context resolve against a single attribute key:
            // the series id when present, otherwise the per-occurrence
            // id. One write reaches every occurrence — the user picks a
            // color for "this 1:1," not for "this Tuesday's instance of
            // this 1:1." Applied unconditionally so removing the
            // override clears the previously-applied value instead of
            // leaving a stale cache snapshot behind.
            let attributeKey = Self.attributeKey(for: result[i])
            let attr = attributes[attributeKey] ?? EventAttributeOverride()
            result[i].colorTag = attr.colorTag
            result[i].context = attr.context
        }
        return result
    }

    /// Single key used to read and write attribute overrides for an
    /// event: the series id (if the event is part of a recurring
    /// series) or its own id otherwise. Exposed so the orchestrator
    /// can use the same resolution when it persists a user edit.
    static func attributeKey(for event: CalendarEvent) -> String {
        event.seriesId ?? event.id
    }

    /// Persist a snapshot to the on-disk cache. Called by the
    /// orchestrator after a user edit mutates the in-memory event slice
    /// so the next cold start sees the post-edit state without waiting
    /// for a live sync.
    func cacheEvents(_ events: [CalendarEvent]) {
        Task { [eventCache] in
            await eventCache.save(events: events)
        }
    }

    // MARK: - Cache

    /// Push the cached event set into the orchestrator if a live sync
    /// hasn't happened yet. Called once at startup. Re-applies overrides
    /// before emitting so that user edits made after the last live sync
    /// (which only touched the in-memory snapshot) become visible on the
    /// next cold start without waiting for connectivity.
    private func loadCachedEvents() {
        Task { @MainActor [weak self] in
            guard let self = self else { return }
            let cached = await self.eventCache.loadEvents()
            guard !cached.isEmpty, !self.hasCompletedLiveSync else { return }
            let overlaid = self.applyAllOverrides(to: cached)
            self.isUsingCache = true
            self.onEventsUpdated?(overlaid, .cache)
        }
    }
}
