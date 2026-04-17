import XCTest
import SwiftData
@testable import Bubo

// MARK: - RemindersSyncService Tests
//
// Drive the sync service against `FakeRemindersEventSource` + an
// `InMemoryBacklogTaskStore` so no EventKit or SwiftData is involved.
// Tests cover the public sync path and the import-side writeback — the
// export path (create / update / delete reminder) is tested via the
// fake's invocation ledger.

@MainActor
final class RemindersSyncServiceTests: XCTestCase {

    // MARK: - Fixtures

    private func makeBacklogService(seed: [BacklogTask] = []) -> BacklogService {
        BacklogService(store: InMemoryBacklogTaskStore(seed: seed))
    }

    private func makeSettings(enabled: Bool = true) -> ReminderSettings {
        let settings = ReminderSettings()
        settings.isRemindersSyncEnabled = enabled
        return settings
    }

    /// Await `isSyncing` transitioning false. Necessary because `syncNow`
    /// fires an unstructured `Task` that writes results to the backlog
    /// and flips `isSyncing` asynchronously.
    private func waitForIdle(
        _ service: RemindersSyncService,
        timeout: TimeInterval = 2.0
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while service.isSyncing, Date() < deadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    // MARK: - Guards

    func testSyncNowBailsWhenFeatureDisabled() async {
        let settings = makeSettings(enabled: false)
        let fake = FakeRemindersEventSource()
        let backlog = makeBacklogService()
        let service = RemindersSyncService(
            settings: settings,
            backlogService: backlog,
            remindersSource: fake
        )

        service.syncNow()
        await waitForIdle(service)

        XCTAssertTrue(fake.invocations.isEmpty, "no fetch when feature is off")
        XCTAssertEqual(backlog.tasks.count, 0)
    }

    func testSyncNowSurfacesErrorWhenAccessMissing() async {
        let fake = FakeRemindersEventSource(hasAccess: false)
        let service = RemindersSyncService(
            settings: makeSettings(),
            backlogService: makeBacklogService(),
            remindersSource: fake
        )

        service.syncNow()
        await waitForIdle(service)

        XCTAssertEqual(service.syncError, "Reminders access not granted")
        XCTAssertTrue(fake.invocations.isEmpty)
    }

    // MARK: - Import

    func testSyncImportsNewRemindersIntoBacklog() async {
        let fake = FakeRemindersEventSource(
            hasAccess: true,
            seed: [
                (calendarItemId: "cal-1",
                 task: BacklogTask(id: "reminder_cal-1", title: "Walk dog", durationMinutes: 15, priority: .medium)),
                (calendarItemId: "cal-2",
                 task: BacklogTask(id: "reminder_cal-2", title: "Read paper", durationMinutes: 30, priority: .low)),
            ]
        )
        let backlog = makeBacklogService()
        let service = RemindersSyncService(
            settings: makeSettings(),
            backlogService: backlog,
            remindersSource: fake
        )

        service.syncNow()
        await waitForIdle(service)

        XCTAssertEqual(backlog.tasks.count, 2, "both fetched reminders imported")
        XCTAssertEqual(Set(backlog.tasks.map(\.id)), ["reminder_cal-1", "reminder_cal-2"])
    }

    func testSyncSkipsExportedTasksFromImport() async {
        // An existing backlog task has `reminderCalendarItemId` set — it
        // was exported earlier, so when we fetch reminders the matching
        // row shouldn't come back as a duplicate import.
        var exported = BacklogTask(id: "bubo-native-1", title: "Local task", durationMinutes: 30, priority: .medium)
        exported.reminderCalendarItemId = "cal-42"

        let fake = FakeRemindersEventSource(
            hasAccess: true,
            seed: [
                (calendarItemId: "cal-42",
                 task: BacklogTask(id: "reminder_cal-42", title: "Local task", durationMinutes: 30, priority: .medium)),
            ]
        )
        let backlog = makeBacklogService(seed: [exported])
        let service = RemindersSyncService(
            settings: makeSettings(),
            backlogService: backlog,
            remindersSource: fake
        )

        service.syncNow()
        await waitForIdle(service)

        XCTAssertEqual(backlog.tasks.map(\.id), ["bubo-native-1"],
            "the exported task kept its native ID; no reminder_cal-42 import")
    }
}
