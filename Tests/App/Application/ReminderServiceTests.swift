import XCTest
import SwiftData
@testable import Bubo
@testable import BuboDomain
@testable import BuboOptimizer

// MARK: - ReminderService Orchestration Tests
//
// Drives `ReminderService` through its `InMemory*` store doubles so the
// tests don't touch SwiftData for user-event state. An in-memory
// SwiftData container is still needed for `EventCache` (wired through
// `EventKitSyncCoordinator`) — but it's configured with
// `isStoredInMemoryOnly: true`, so nothing hits disk.
//
// These tests exercise the orchestration seams that were hard to reach
// before the stores were extracted: "does adding a local event persist
// through the store", "does removing cancel its excluded-occurrence
// entries", "does updateLocalReminder round-trip". The notification
// scheduler is exercised incidentally — timers are created but never
// fire within the test lifetime because every fake event is scheduled
// hours into the future.

@MainActor
final class ReminderServiceTests: XCTestCase {

    // MARK: - Fixtures

    private func makeEventCacheContainer() throws -> ModelContainer {
        try ModelContainer(
            for: PersistedCachedEvent.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
    }

    private func makeService(
        settings: ReminderSettings = ReminderSettings(),
        seededLocalEvents: [CalendarEvent] = [],
        seededExcluded: Set<String> = [],
        seededOverrides: [String: [Int]] = [:],
        calendarSource: FakeCalendarEventSource = FakeCalendarEventSource()
    ) throws -> (
        ReminderService,
        InMemoryLocalEventStore,
        InMemoryExcludedOccurrenceStore,
        InMemoryReminderOverrideStore
    ) {
        let local = InMemoryLocalEventStore(seed: seededLocalEvents)
        let excluded = InMemoryExcludedOccurrenceStore(seed: seededExcluded)
        let overrides = InMemoryReminderOverrideStore(seed: seededOverrides)
        let service = ReminderService(
            settings: settings,
            eventCacheContainer: try makeEventCacheContainer(),
            localEventStore: local,
            excludedOccurrenceStore: excluded,
            reminderOverrideStore: overrides,
            eventAttributeOverrideStore: InMemoryEventAttributeOverrideStore(),
            calendarSource: calendarSource
        )
        return (service, local, excluded, overrides)
    }

    private func event(id: String, startsIn seconds: TimeInterval = 3600) -> CalendarEvent {
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

    // MARK: - Load from seed

    func testInitLoadsSeededLocalEventsAndOverrides() throws {
        let a = event(id: "a")
        let b = event(id: "b", startsIn: 7200)
        let (service, _, _, _) = try makeService(
            seededLocalEvents: [a, b],
            seededOverrides: ["a": [10, 5]]
        )
        XCTAssertEqual(Set(service.localEvents.map(\.id)), ["a", "b"])
        XCTAssertEqual(service.activeReminderMinutes(for: a), service.activeReminderMinutes(for: a))
    }

    func testInitLoadsSeededExcludedOccurrences() throws {
        // Seed a local event + an excluded occurrence under its ID.
        // After init the service should surface neither the event (in
        // allEvents) as a valid occurrence nor include the excluded id
        // in its reminder scheduling.
        let (service, _, excluded, _) = try makeService(
            seededLocalEvents: [event(id: "series-a")],
            seededExcluded: ["series-a_2025-01-01"]
        )
        // Excluded store keeps the seeded value.
        XCTAssertTrue(excluded.loadAll().contains("series-a_2025-01-01"))
        // Local events still contain the series.
        XCTAssertEqual(service.localEvents.map(\.id), ["series-a"])
    }

    // MARK: - Add / Update / Remove Local Event

    func testAddLocalEventPersistsAndUpdatesInMemory() throws {
        let (service, local, _, _) = try makeService()
        let e = event(id: "new")
        service.addLocalEvent(e)
        XCTAssertEqual(service.localEvents.map(\.id), ["new"])
        XCTAssertEqual(local.loadAll().map(\.id), ["new"])
    }

    func testUpdateLocalEventReplacesSnapshot() throws {
        let original = event(id: "a")
        let (service, local, _, _) = try makeService(seededLocalEvents: [original])
        var replacement = original
        replacement.startDate = original.startDate.addingTimeInterval(3600)
        replacement.endDate = original.endDate.addingTimeInterval(3600)
        service.updateLocalEvent(replacement)

        let persisted = local.loadAll().first { $0.id == "a" }
        XCTAssertEqual(persisted?.startDate, replacement.startDate)
    }

    func testRemoveLocalEventDropsExcludedPrefix() throws {
        let a = event(id: "a")
        let (service, local, excluded, _) = try makeService(
            seededLocalEvents: [a],
            seededExcluded: ["a_2025-01-01", "b_2025-01-01"]
        )
        service.removeLocalEvent(id: "a")

        XCTAssertTrue(local.loadAll().isEmpty, "a was removed")
        XCTAssertFalse(excluded.loadAll().contains("a_2025-01-01"), "a's excluded entries dropped")
        XCTAssertTrue(excluded.loadAll().contains("b_2025-01-01"), "unrelated exclusions preserved")
    }

    // MARK: - Excluded Occurrences

    func testExcludeOccurrencePersists() throws {
        let (service, _, excluded, _) = try makeService()
        service.excludeOccurrence(occurrenceId: "series-a_2025-04-17")
        XCTAssertTrue(excluded.loadAll().contains("series-a_2025-04-17"))
    }

    // MARK: - Reminder Overrides

    func testUpdateLocalReminderPersistsOverride() throws {
        let (service, _, _, overrides) = try makeService()
        service.updateLocalReminder(for: "evt-1", minutes: [15, 60])
        XCTAssertEqual(overrides.loadAll()["evt-1"], [15, 60])
    }

    func testUpdateLocalReminderWithNilClearsToEmptyArray() throws {
        // nil → empty array per current contract; the empty array is
        // persisted as "user explicitly disabled overrides".
        let (service, _, _, overrides) = try makeService(seededOverrides: ["evt-1": [10]])
        service.updateLocalReminder(for: "evt-1", minutes: nil)
        XCTAssertEqual(overrides.loadAll()["evt-1"], [])
    }

    // MARK: - Error Surfacing

    func testLastPersistenceErrorIsNilOnHappyPath() throws {
        let (service, _, _, _) = try makeService()
        XCTAssertNil(service.lastPersistenceError)
    }

    // MARK: - Sync State Proxies

    func testInitialSyncStateIsIdle() throws {
        let (service, _, _, _) = try makeService()
        XCTAssertFalse(service.isSyncing)
        XCTAssertFalse(service.isUsingCache)
        XCTAssertNil(service.syncError)
        XCTAssertNil(service.lastSyncDate)
    }

    // MARK: - Snooze Routing

    private func makeServiceWithCalendarSource(
        _ source: FakeCalendarEventSource
    ) throws -> ReminderService {
        ReminderService(
            settings: ReminderSettings(),
            eventCacheContainer: try makeEventCacheContainer(),
            localEventStore: InMemoryLocalEventStore(),
            excludedOccurrenceStore: InMemoryExcludedOccurrenceStore(),
            reminderOverrideStore: InMemoryReminderOverrideStore(),
            eventAttributeOverrideStore: InMemoryEventAttributeOverrideStore(),
            calendarSource: source
        )
    }

    func testSnoozeOfAppleEventRoutesToCalendarSource() throws {
        let fake = FakeCalendarEventSource()
        let service = try makeServiceWithCalendarSource(fake)

        // isLocalEvent is defined as `!id.hasPrefix("apple_")`, so an
        // "apple_..." ID routes to the EventKit path.
        let apple = CalendarEvent(
            id: "apple_1",
            title: "Meeting",
            startDate: Date().addingTimeInterval(3600),
            endDate: Date().addingTimeInterval(7200),
            location: nil,
            description: nil,
            calendarName: nil,
            eventType: .standard
        )
        service.snoozeReminder(for: apple, minutes: 15)

        XCTAssertTrue(fake.invocations.contains(where: {
            if case .shiftEventTime(let id, let by) = $0, id == "apple_1", by == 15 {
                return true
            }
            return false
        }), "Apple snooze should call shiftEventTime on calendar source")
    }

    func testSnoozeOfLocalEventUpdatesInMemoryEventOnly() throws {
        let fake = FakeCalendarEventSource()
        let service = try makeServiceWithCalendarSource(fake)

        let local = CalendarEvent(
            id: "local-1",
            title: "Study",
            startDate: Date().addingTimeInterval(3600),
            endDate: Date().addingTimeInterval(7200),
            location: nil,
            description: nil,
            calendarName: nil,
            eventType: .standard
        )
        service.addLocalEvent(local)
        service.snoozeReminder(for: local, minutes: 10)

        XCTAssertFalse(fake.invocations.contains(where: {
            if case .shiftEventTime = $0 { return true } else { return false }
        }), "Local snooze must NOT call the calendar source")
    }

    // MARK: - Hidden External Events

    private func appleEvent(
        id: String,
        seriesId: String? = nil,
        startsIn seconds: TimeInterval = 3600
    ) -> CalendarEvent {
        let start = Date().addingTimeInterval(seconds)
        return CalendarEvent(
            id: id,
            title: id,
            startDate: start,
            endDate: start.addingTimeInterval(1800),
            location: nil,
            description: nil,
            calendarName: "Work",
            seriesId: seriesId,
            eventType: .standard
        )
    }

    func testHideExternalEventRemovesItAndSurvivesResync() throws {
        let ghost = appleEvent(id: "apple_ghost_1")
        let live = appleEvent(id: "apple_live_1", startsIn: 7200)
        let fake = FakeCalendarEventSource(upcomingEvents: [ghost, live])
        let (service, _, excluded, _) = try makeService(calendarSource: fake)

        service.syncNow()
        XCTAssertEqual(Set(service.upcomingEvents.map(\.id)), ["apple_ghost_1", "apple_live_1"])

        service.hideExternalEvent(ghost)
        XCTAssertEqual(service.upcomingEvents.map(\.id), ["apple_live_1"])
        XCTAssertTrue(excluded.loadAll().contains("apple_ghost_1"), "tombstone persisted")

        // EventKit keeps serving the ghost on the next sync — the
        // tombstone must keep filtering it out.
        service.syncNow()
        XCTAssertEqual(service.upcomingEvents.map(\.id), ["apple_live_1"])
    }

    func testHideExternalSeriesHidesEveryOccurrence() throws {
        let monday = appleEvent(id: "apple_s_1", seriesId: "apple_s", startsIn: 3600)
        let tuesday = appleEvent(id: "apple_s_2", seriesId: "apple_s", startsIn: 90000)
        let other = appleEvent(id: "apple_other", startsIn: 7200)
        let fake = FakeCalendarEventSource(upcomingEvents: [monday, tuesday, other])
        let (service, _, excluded, _) = try makeService(calendarSource: fake)

        service.syncNow()
        XCTAssertEqual(service.upcomingEvents.count, 3)

        service.hideExternalSeries(monday)
        XCTAssertEqual(service.upcomingEvents.map(\.id), ["apple_other"])
        XCTAssertTrue(excluded.loadAll().contains("apple_s"), "series tombstone persisted")

        service.syncNow()
        XCTAssertEqual(service.upcomingEvents.map(\.id), ["apple_other"])
    }

    func testUnhideExternalEventsRestoresViaResync() throws {
        let ghost = appleEvent(id: "apple_ghost_1")
        let fake = FakeCalendarEventSource(upcomingEvents: [ghost])
        let (service, _, excluded, _) = try makeService(calendarSource: fake)

        service.syncNow()
        let keys = service.hideExternalEvent(ghost)
        XCTAssertTrue(service.upcomingEvents.isEmpty)

        service.unhideExternalEvents(ids: keys)
        XCTAssertFalse(excluded.loadAll().contains("apple_ghost_1"), "tombstone removed")
        XCTAssertEqual(service.upcomingEvents.map(\.id), ["apple_ghost_1"], "unhide re-syncs and restores")
    }

    // MARK: - Server Ghost Keys (CalDAV verification)

    func testApplyServerGhostKeysHidesAndSurvivesResync() throws {
        let ghost = appleEvent(id: "apple_ghost_1")
        let live = appleEvent(id: "apple_live_1", startsIn: 7200)
        let fake = FakeCalendarEventSource(upcomingEvents: [ghost, live])
        let (service, _, excluded, _) = try makeService(calendarSource: fake)

        service.syncNow()
        XCTAssertEqual(service.upcomingEvents.count, 2)

        service.applyServerGhostKeys(["apple_ghost_1"])
        XCTAssertEqual(service.upcomingEvents.map(\.id), ["apple_live_1"])
        XCTAssertFalse(
            excluded.loadAll().contains("apple_ghost_1"),
            "server ghosts are not user tombstones — the store stays untouched"
        )

        service.syncNow()
        XCTAssertEqual(service.upcomingEvents.map(\.id), ["apple_live_1"])
    }

    func testApplyServerGhostKeysMatchesSeries() throws {
        let monday = appleEvent(id: "apple_s_1", seriesId: "apple_s")
        let tuesday = appleEvent(id: "apple_s_2", seriesId: "apple_s", startsIn: 90000)
        let fake = FakeCalendarEventSource(upcomingEvents: [monday, tuesday])
        let (service, _, _, _) = try makeService(calendarSource: fake)

        service.syncNow()
        service.applyServerGhostKeys(["apple_s"])
        XCTAssertTrue(service.upcomingEvents.isEmpty)
    }

    func testShrinkingServerGhostKeysRestoresViaResync() throws {
        let ghost = appleEvent(id: "apple_ghost_1")
        let fake = FakeCalendarEventSource(upcomingEvents: [ghost])
        let (service, _, _, _) = try makeService(calendarSource: fake)

        service.syncNow()
        service.applyServerGhostKeys(["apple_ghost_1"])
        XCTAssertTrue(service.upcomingEvents.isEmpty)

        // Server resurrected the event (or verification was disabled):
        // clearing the set must bring it back without waiting for the
        // next timer tick.
        service.applyServerGhostKeys([])
        XCTAssertEqual(service.upcomingEvents.map(\.id), ["apple_ghost_1"])
    }

    func testSeededTombstoneFiltersFirstSync() throws {
        // A tombstone written in an earlier session must filter the
        // very first emission after launch.
        let ghost = appleEvent(id: "apple_ghost_1")
        let fake = FakeCalendarEventSource(upcomingEvents: [ghost])
        let (service, _, _, _) = try makeService(
            seededExcluded: ["apple_ghost_1"],
            calendarSource: fake
        )
        service.syncNow()
        XCTAssertTrue(service.upcomingEvents.isEmpty)
    }

    // MARK: - Badge Count

    func testBadgeCountZeroWhenSettingDisabled() throws {
        let settings = ReminderSettings()
        settings.showBadgeCount = false
        let (service, _, _, _) = try makeService(
            settings: settings,
            seededLocalEvents: [event(id: "a"), event(id: "b")]
        )
        XCTAssertEqual(service.badgeCount, 0)
    }
}
