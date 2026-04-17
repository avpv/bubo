import XCTest
import SwiftData
@testable import Bubo

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

    func testSyncNowFetchesRebuildsAndEmitsEvents() throws {
        let evt = event(id: "apple_1", startsIn: 1800)
        let (coordinator, fake) = try makeCoordinator(seededEvents: [evt])

        var captured: [CalendarEvent]?
        var capturedSource: EventKitSyncCoordinator.Source?
        coordinator.onEventsUpdated = { events, source in
            captured = events
            capturedSource = source
        }

        coordinator.syncNow()

        // Calendar source gets the sync-time prod sequence — rebuild,
        // remote refresh, then a fetch. Date args on fetchEvents are
        // `now`-based so we only assert the kind for the third call.
        XCTAssertEqual(
            Array(fake.invocations.prefix(2)),
            [.rebuildStore, .triggerRemoteRefresh]
        )
        guard fake.invocations.count >= 3,
              case .fetchEvents = fake.invocations[2] else {
            XCTFail("third call should be fetchEvents, got \(fake.invocations)")
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
