import Foundation
import SwiftData
import os

private let logger = Logger(subsystem: "com.avpv.Bubo", category: "EventKitSyncCoordinator")

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
    private nonisolated(unsafe) var pendingPostSyncTask: Task<Void, Never>?
    private nonisolated(unsafe) var pendingAppleRefreshTask: Task<Void, Never>?
    private nonisolated(unsafe) var calendarObserver: Any?

    /// Set on first successful live sync. Guards against the cached
    /// load overwriting fresh data when both happen in a tight window.
    private var hasCompletedLiveSync: Bool = false

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
    }

    func updateSettings(_ settings: ReminderSettings) {
        self.settings = settings
    }

    // MARK: - Lifecycle

    func start() {
        loadCachedEvents()
        syncNow()
        startSyncTimer()
    }

    func stop() {
        syncTimer?.invalidate()
        syncTimer = nil
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
            logger.info("sync_skipped reason=disabled")
            syncError = "Calendar sync disabled"
            isUsingCache = false
            onEventsUpdated?([], .live)
            return
        }

        guard calendarSource.hasAccess else {
            logger.warning("sync_skipped reason=no_access")
            syncError = "Calendar access not granted"
            return
        }

        let startedAt = Date()
        logger.info("sync_started")

        isSyncing = true
        syncError = nil

        // Force EventKit to pull fresh data from remote calendar servers
        // (iCloud, Google, Exchange, CalDAV) BEFORE we read events.
        // Rebuilding the store opens a fresh IPC connection to the
        // `calendard` daemon, which often stops sending updates to
        // long-lived connections — especially while Calendar.app is
        // closed.
        calendarSource.rebuildStore()
        calendarSource.triggerRemoteRefresh()

        let events = fetchAndApplyOverrides()

        lastSyncDate = Date()
        isSyncing = false
        isUsingCache = false
        hasCompletedLiveSync = true

        onEventsUpdated?(events, .live)

        Task {
            await eventCache.save(events: events)
        }

        schedulePostSyncRefresh()

        let durationMs = Int(Date().timeIntervalSince(startedAt) * 1000)
        logger.info("sync_completed events=\(events.count) duration_ms=\(durationMs)")
    }

    /// Re-fetches events without triggering another remote refresh, on a
    /// cascading delay schedule. Calendar.app being closed makes
    /// `calendard` slow to actually pull from remote servers, so we prod
    /// it repeatedly and re-read at 4 / 12 / 30 / 60 second intervals to
    /// catch late deletes and updates that would otherwise wait until
    /// the next full sync cycle.
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

        // Flush EKEventStore's in-memory cache so we read the latest
        // state from `calendard` rather than its stale snapshot.
        calendarSource.resetCache()

        let events = fetchAndApplyOverrides()

        lastSyncDate = Date()
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

            // Both override types are applied unconditionally: when the
            // user *removes* an override, the corresponding entry leaves
            // the dictionary, and we want the value on the event to fall
            // back to "no override" (nil) — not to whatever the on-disk
            // cache last recorded. External events have no inherent
            // colorTag / context / customReminderMinutes, so resetting
            // to nil restores the calendar source's view of the world.
            let seriesMins = result[i].seriesId.flatMap { overrides[$0] }
            let activeMins = overrides[uniqueId] ?? seriesMins
            result[i].customReminderMinutes = (activeMins?.isEmpty ?? true) ? nil : activeMins

            let seriesAttrs = result[i].seriesId.flatMap { attributes[$0] }
            let attr = attributes[uniqueId] ?? seriesAttrs ?? EventAttributeOverride()
            result[i].colorTag = attr.colorTag
            result[i].context = attr.context
        }
        return result
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
