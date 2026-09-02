import XCTest
import SwiftData
@testable import Bubo
@testable import BuboDomain
@testable import BuboOptimizer

// MARK: - EventKitSyncCoordinator Tests
//
// Drives the coordinator against `FakeCalendarEventSource` so every
// EventKit call is recorded instead of talking to the real
// `EKEventStore`. Tests assert the observable behaviour — state
// transitions (`isSyncing`, `syncError`, `lastSyncDate`), the ordered
// call sequence into the calendar source, and the event slices emitted
// through `onEventsUpdated`.

@MainActor
final class EventKitSyncCoordinatorTests: XCTestCase {

    // MARK: - Fixtures

    private func makeEventCacheContainer() throws -> ModelContainer {
        try ModelContainer(
            for: PersistedCachedEvent.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
    }

    private func event(id: String, startsIn seconds: TimeInterval) -> CalendarEvent {
        let start = Date().addingTimeInterval(seconds)
        return CalendarEvent(
            id: id,
            title: id,
            startDate: start,
            endDate: start.addingTimeInterval(3600),
            location: nil,
            description: nil,
            calendarName: nil,
            eventType: .standard
        )
    }

    private func makeCoordinator(
        settings: ReminderSettings = ReminderSettings(),
        hasAccess: Bool = true,
        seededEvents: [CalendarEvent] = []
    ) throws -> (EventKitSyncCoordinator, FakeCalendarEventSource) {
        let fake = FakeCalendarEventSource(
            hasAccess: hasAccess,
            upcomingEvents: seededEvents
        )
        let coordinator = EventKitSyncCoordinator(
            eventCacheContainer: try makeEventCacheContainer(),
            settings: settings,
            calendarSource: fake
        )
        return (coordinator, fake)
    }

    // MARK: - Guards

    func testSyncNowBailsWhenCalendarSyncDisabled() throws {
        let settings = ReminderSettings()
        settings.isCalendarSyncEnabled = false
        let (coordinator, fake) = try makeCoordinator(settings: settings)

        var captured: [CalendarEvent]?
        coordinator.onEventsUpdated = { events, _ in captured = events }

        coordinator.syncNow()

        XCTAssertEqual(coordinator.syncError, "Calendar sync disabled")
        XCTAssertEqual(captured, [], "empty slice pushed so subscribers can clear upcoming state")
        XCTAssertFalse(fake.invocations.contains(where: {
            if case .fetchEvents = $0 { return true } else { return false }
        }), "fetch must not happen when sync disabled")
    }

    func testSyncNowBailsWhenAccessRevoked() throws {
        let (coordinator, fake) = try makeCoordinator(hasAccess: false)

        var callbackFired = false
        coordinator.onEventsUpdated = { _, _ in callbackFired = true }

        coordinator.syncNow()

        XCTAssertEqual(coordinator.syncError, "Calendar access not granted")
        XCTAssertFalse(callbackFired, "no events emitted when access is missing")
        XCTAssertTrue(fake.invocations.isEmpty, "no EventKit calls made")
    }

    // MARK: - Happy path

    func testSyncNowFetchesAndEmitsEvents() throws {
        let evt = event(id: "apple_1", startsIn: 1800)
        let (coordinator, fake) = try makeCoordinator(seededEvents: [evt])

        var captured: [CalendarEvent]?
        var capturedSource: EventKitSyncCoordinator.Source?
        coordinator.onEventsUpdated = { events, source in
            captured = events
            capturedSource = source
        }

        coordinator.syncNow()

        // Calendar source gets a remote-refresh request, then a fetch.
        // Notably NO store rebuild/reset — the store must stay alive so
        // `EKEventStoreChanged` pushes keep arriving. Date args on
        // fetchEvents are `now`-based so we only assert the kind for
        // the second call.
        XCTAssertEqual(
            Array(fake.invocations.prefix(1)),
            [.triggerRemoteRefresh]
        )
        guard fake.invocations.count >= 2,
              case .fetchEvents = fake.invocations[1] else {
            XCTFail("second call should be fetchEvents, got \(fake.invocations)")
            return
        }

        XCTAssertEqual(captured?.map(\.id), ["apple_1"])
        XCTAssertEqual(capturedSource, .live)

        XCTAssertFalse(coordinator.isSyncing, "transitioned back to idle")
        XCTAssertFalse(coordinator.isUsingCache, "live sync clears the cache flag")
        XCTAssertNil(coordinator.syncError)
        XCTAssertNotNil(coordinator.lastSyncDate)
    }

    func testSyncNowAppliesReminderOverridesFromProvider() throws {
        let evt = event(id: "apple_1", startsIn: 1800)
        let (coordinator, _) = try makeCoordinator(seededEvents: [evt])

        coordinator.overridesProvider = { ["apple_1": [10, 45]] }

        var captured: [CalendarEvent]?
        coordinator.onEventsUpdated = { events, _ in captured = events }

        coordinator.syncNow()

        XCTAssertEqual(captured?.first?.customReminderMinutes, [10, 45])
    }

    func testSyncNowAppliesSeriesOverridesWhenNoExactMatch() throws {
        var evt = event(id: "apple_1_1234567", startsIn: 1800)
        evt.seriesId = "apple_series-1"
        let (coordinator, _) = try makeCoordinator(seededEvents: [evt])

        coordinator.overridesProvider = { ["apple_series-1": [5]] }

        var captured: [CalendarEvent]?
        coordinator.onEventsUpdated = { events, _ in captured = events }

        coordinator.syncNow()

        XCTAssertEqual(captured?.first?.customReminderMinutes, [5])
    }

    func testSyncNowClearsCustomMinutesWhenOverrideIsEmpty() throws {
        // Empty array = user explicitly opted out. Should push `nil` to
        // customReminderMinutes so the default interval list applies.
        var evt = event(id: "apple_1", startsIn: 1800)
        evt.customReminderMinutes = [15]
        let (coordinator, _) = try makeCoordinator(seededEvents: [evt])

        coordinator.overridesProvider = { ["apple_1": []] }

        var captured: [CalendarEvent]?
        coordinator.onEventsUpdated = { events, _ in captured = events }

        coordinator.syncNow()

        XCTAssertNil(captured?.first?.customReminderMinutes)
    }

    // MARK: - Staleness watchdog

    func testIsStaleFalseWhenNeverSynced() {
        // Never-synced is reported through syncError / permission
        // banners, not staleness.
        XCTAssertFalse(EventKitSyncCoordinator.isStale(lastSync: nil, now: Date(), intervalMinutes: 5))
    }

    func testIsStaleThresholdIsThreeIntervalsFlooredAtFifteenMinutes() {
        let now = Date()
        // 5-minute interval → threshold 15 min (floor and 3× coincide).
        XCTAssertFalse(EventKitSyncCoordinator.isStale(
            lastSync: now.addingTimeInterval(-14 * 60), now: now, intervalMinutes: 5))
        XCTAssertTrue(EventKitSyncCoordinator.isStale(
            lastSync: now.addingTimeInterval(-16 * 60), now: now, intervalMinutes: 5))
        // 1-minute interval → 3× would be 3 min, floor keeps it at 15.
        XCTAssertFalse(EventKitSyncCoordinator.isStale(
            lastSync: now.addingTimeInterval(-10 * 60), now: now, intervalMinutes: 1))
        // 30-minute interval → threshold 90 min.
        XCTAssertFalse(EventKitSyncCoordinator.isStale(
            lastSync: now.addingTimeInterval(-60 * 60), now: now, intervalMinutes: 30))
        XCTAssertTrue(EventKitSyncCoordinator.isStale(
            lastSync: now.addingTimeInterval(-91 * 60), now: now, intervalMinutes: 30))
    }

    func testWatchdogSelfHealsAndClearsStaleWhenRetrySucceeds() throws {
        let (coordinator, fake) = try makeCoordinator()
        coordinator.syncNow()
        XCTAssertFalse(coordinator.isStale)
        let callsAfterFirstSync = fake.invocations.count

        // Simulate an hour passing with the sync timer dead: the tick
        // must re-run syncNow, and the successful refresh clears the
        // flag before the UI ever sees it.
        coordinator.watchdogTick(now: Date().addingTimeInterval(3600))

        XCTAssertGreaterThan(fake.invocations.count, callsAfterFirstSync, "watchdog must retry the sync")
        XCTAssertFalse(coordinator.isStale, "successful retry clears staleness")
        XCTAssertNil(coordinator.syncError)
    }

    func testWatchdogRaisesStaleWhenRetryCannotRefresh() throws {
        let (coordinator, fake) = try makeCoordinator()
        coordinator.syncNow()
        XCTAssertNotNil(coordinator.lastSyncDate)

        // Access revoked after a healthy run: the heal attempt bails,
        // lastSyncDate stays old, and the stale flag must surface.
        fake.hasAccess = false
        coordinator.watchdogTick(now: Date().addingTimeInterval(3600))

        XCTAssertTrue(coordinator.isStale)
        XCTAssertEqual(coordinator.syncError, "Calendar access not granted")
    }

    func testWatchdogStaysQuietWhenFresh() throws {
        let (coordinator, fake) = try makeCoordinator()
        coordinator.syncNow()
        let callsAfterFirstSync = fake.invocations.count

        coordinator.watchdogTick(now: Date().addingTimeInterval(60))

        XCTAssertFalse(coordinator.isStale)
        XCTAssertEqual(fake.invocations.count, callsAfterFirstSync, "no retry while fresh")
    }

    func testWatchdogClearsStaleWhenSyncDisabled() throws {
        let settings = ReminderSettings()
        let (coordinator, _) = try makeCoordinator(settings: settings)
        coordinator.syncNow()

        settings.isCalendarSyncEnabled = false
        coordinator.watchdogTick(now: Date().addingTimeInterval(3600))

        XCTAssertFalse(coordinator.isStale, "a deliberately disabled sync is never stale")
    }

    // MARK: - Push-Connection Self-Heal

    private func rebuildCount(_ fake: FakeCalendarEventSource) -> Int {
        fake.invocations.filter { $0 == .rebuildForSelfHeal }.count
    }

    func testSelfHealRebuildsWhenDataChangedWithoutPush() throws {
        let (coordinator, fake) = try makeCoordinator(
            seededEvents: [event(id: "apple_a", startsIn: 1800)]
        )
        coordinator.onEventsUpdated = { _, _ in }
        fake.lastPushActivityAt = Date().addingTimeInterval(-3600)

        // Baseline sync — the first emission has no reference set, so
        // it can't prove the push channel dead.
        coordinator.syncNow()
        XCTAssertEqual(rebuildCount(fake), 0)

        // The event set changed while `EKEventStoreChanged` stayed
        // silent for an hour — a live connection would have announced
        // that change within seconds, so the store must be rebuilt.
        fake.upcomingEvents.append(event(id: "apple_b", startsIn: 3600))
        coordinator.syncNow()
        XCTAssertEqual(rebuildCount(fake), 1)
    }

    func testSelfHealStaysQuietWhenPushesAreFresh() throws {
        let (coordinator, fake) = try makeCoordinator(
            seededEvents: [event(id: "apple_a", startsIn: 1800)]
        )
        coordinator.onEventsUpdated = { _, _ in }

        coordinator.syncNow()
        // Data changes with recent push activity are the normal case —
        // the push itself is what usually triggers the sync.
        fake.upcomingEvents.append(event(id: "apple_b", startsIn: 3600))
        fake.lastPushActivityAt = Date()
        coordinator.syncNow()

        XCTAssertEqual(rebuildCount(fake), 0)
    }

    func testSelfHealRespectsCooldown() throws {
        let (coordinator, fake) = try makeCoordinator(
            seededEvents: [event(id: "apple_a", startsIn: 1800)]
        )
        coordinator.onEventsUpdated = { _, _ in }
        fake.lastPushActivityAt = Date().addingTimeInterval(-3600)

        coordinator.syncNow()
        fake.upcomingEvents.append(event(id: "apple_b", startsIn: 3600))
        coordinator.syncNow()
        XCTAssertEqual(rebuildCount(fake), 1)

        // Another silent diff right away: the cooldown must hold the
        // heal back so a persistent daemon problem can't cause a
        // rebuild storm.
        fake.lastPushActivityAt = Date().addingTimeInterval(-3600)
        fake.upcomingEvents.append(event(id: "apple_c", startsIn: 5400))
        coordinator.syncNow()
        XCTAssertEqual(rebuildCount(fake), 1)
    }

    func testSelfHealDirectClockDrivenWindows() throws {
        // Drive the injectable clock directly: silence just under the
        // threshold stays quiet; past it heals; cooldown expiry allows
        // the next heal.
        let (coordinator, fake) = try makeCoordinator()
        let t0 = Date()
        fake.lastPushActivityAt = t0

        coordinator.selfHealPushConnectionIfDead(
            eventsChanged: true,
            now: t0.addingTimeInterval(EventKitSyncCoordinator.pushSilenceThreshold - 1)
        )
        XCTAssertEqual(rebuildCount(fake), 0, "silence below threshold is not proof")

        let healTime = t0.addingTimeInterval(EventKitSyncCoordinator.pushSilenceThreshold + 1)
        fake.lastPushActivityAt = t0
        coordinator.selfHealPushConnectionIfDead(eventsChanged: true, now: healTime)
        XCTAssertEqual(rebuildCount(fake), 1)

        // Fake stamps lastPushActivityAt on rebuild; push it back into
        // the past to isolate the cooldown check.
        fake.lastPushActivityAt = t0
        coordinator.selfHealPushConnectionIfDead(
            eventsChanged: true,
            now: healTime.addingTimeInterval(EventKitSyncCoordinator.selfHealCooldown + 1)
        )
        XCTAssertEqual(rebuildCount(fake), 2, "cooldown expired — heal allowed again")
    }

    // MARK: - Stop

    func testStopInvalidatesTimer() throws {
        let (coordinator, _) = try makeCoordinator()
        coordinator.startSyncTimer()
        coordinator.stop()
        // No direct way to assert timer state from outside; this test
        // locks in that stop() is callable and doesn't crash. Paired
        // with deinit cleanup.
    }
}
