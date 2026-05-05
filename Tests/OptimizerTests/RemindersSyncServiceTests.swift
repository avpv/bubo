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

    // MARK: - Schedule Alarms (iPhone / iPad ringing)

    /// Pull just the schedule-update calls out of the recorded ledger so
    /// each test can assert against alarm dates without sifting through
    /// the full invocation list.
    private func scheduleInvocations(_ fake: FakeRemindersEventSource) -> [(dueDate: Date?, alarmDates: [Date])] {
        fake.invocations.compactMap { call in
            if case let .updateSchedule(_, dueDate, alarmDates) = call {
                return (dueDate, alarmDates)
            }
            return nil
        }
    }

    /// Wait long enough for the synchronous notification observer to fire
    /// the queued main-actor task that runs the schedule writeback.
    private func waitForObservers() async {
        try? await Task.sleep(nanoseconds: 50_000_000)
    }

    /// Build a date in the near future at HH:MM local time so alarms
    /// don't get filtered out for being in the past.
    private func futureDate(hour: Int, minute: Int = 0, daysFromNow: Int = 1) -> Date {
        let cal = Calendar.current
        let target = cal.date(byAdding: .day, value: daysFromNow, to: Date())!
        return cal.date(
            bySettingHour: hour,
            minute: minute,
            second: 0,
            of: target
        )!
    }

    func testScheduleWritebackInstallsNoAlarmsWhenOptedOut() async {
        let task = BacklogTask(id: "reminder_cal-1", title: "Walk dog", durationMinutes: 30, priority: .medium)
        let fake = FakeRemindersEventSource(
            hasAccess: true,
            seed: [(calendarItemId: "cal-1", task: task)]
        )
        let backlog = makeBacklogService(seed: [task])
        let settings = makeSettings()
        settings.remindersScheduleAlarms = false

        _ = RemindersSyncService(
            settings: settings,
            backlogService: backlog,
            remindersSource: fake
        )

        let due = futureDate(hour: 14)
        backlog.markScheduled(id: task.id, eventIds: ["evt-1"], date: due)
        await waitForObservers()

        let calls = scheduleInvocations(fake)
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls.first?.dueDate, due)
        XCTAssertEqual(calls.first?.alarmDates, [], "no alarms when toggle is off")
    }

    func testScheduleWritebackInstallsAtTimeAndLeadAlarms() async {
        let task = BacklogTask(id: "reminder_cal-1", title: "Walk dog", durationMinutes: 30, priority: .medium)
        let fake = FakeRemindersEventSource(
            hasAccess: true,
            seed: [(calendarItemId: "cal-1", task: task)]
        )
        let backlog = makeBacklogService(seed: [task])
        let settings = makeSettings()
        settings.remindersScheduleAlarms = true
        settings.remindersScheduleAlarmLeadMinutes = [
            ReminderInterval(minutes: 10),
            ReminderInterval(minutes: 1),
        ]

        _ = RemindersSyncService(
            settings: settings,
            backlogService: backlog,
            remindersSource: fake
        )

        let due = futureDate(hour: 14)
        backlog.markScheduled(id: task.id, eventIds: ["evt-1"], date: due)
        await waitForObservers()

        let calls = scheduleInvocations(fake)
        XCTAssertEqual(calls.count, 1)
        let expected: Set<Date> = [
            due,
            due.addingTimeInterval(-10 * 60),
            due.addingTimeInterval(-1 * 60),
        ]
        XCTAssertEqual(Set(calls.first?.alarmDates ?? []), expected,
            "at-time alarm + every enabled lead-time")
    }

    func testScheduleWritebackSkipsDisabledLeadIntervals() async {
        let task = BacklogTask(id: "reminder_cal-1", title: "Walk dog", durationMinutes: 30, priority: .medium)
        let fake = FakeRemindersEventSource(
            hasAccess: true,
            seed: [(calendarItemId: "cal-1", task: task)]
        )
        let backlog = makeBacklogService(seed: [task])
        let settings = makeSettings()
        settings.remindersScheduleAlarms = true
        settings.remindersScheduleAlarmLeadMinutes = [
            ReminderInterval(minutes: 10, isEnabled: false),
            ReminderInterval(minutes: 5, isEnabled: true),
        ]

        _ = RemindersSyncService(
            settings: settings,
            backlogService: backlog,
            remindersSource: fake
        )

        let due = futureDate(hour: 14)
        backlog.markScheduled(id: task.id, eventIds: ["evt-1"], date: due)
        await waitForObservers()

        let alarms = scheduleInvocations(fake).first?.alarmDates ?? []
        XCTAssertEqual(Set(alarms), [due, due.addingTimeInterval(-5 * 60)])
    }

    func testScheduleWritebackSkipsAlarmsForAllDayDate() async {
        // Midnight local time = no meaningful time component → date-only
        // deadline → no alarms (we won't ring the user's phone at 00:00).
        let task = BacklogTask(id: "reminder_cal-1", title: "Read book", durationMinutes: 60, priority: .medium)
        let fake = FakeRemindersEventSource(
            hasAccess: true,
            seed: [(calendarItemId: "cal-1", task: task)]
        )
        let backlog = makeBacklogService(seed: [task])
        let settings = makeSettings()
        settings.remindersScheduleAlarms = true

        _ = RemindersSyncService(
            settings: settings,
            backlogService: backlog,
            remindersSource: fake
        )

        let midnight = futureDate(hour: 0, minute: 0, daysFromNow: 1)
        backlog.markScheduled(id: task.id, eventIds: ["evt-1"], date: midnight)
        await waitForObservers()

        let calls = scheduleInvocations(fake)
        XCTAssertEqual(calls.first?.alarmDates, [],
            "all-day / midnight schedule never installs alarms")
    }

    func testScheduleWritebackDropsPastAlarmDates() async {
        // Schedule 30s in the future with a 10-min lead → at-time stays,
        // T-10 is in the past and must be filtered out.
        let task = BacklogTask(id: "reminder_cal-1", title: "Imminent", durationMinutes: 5, priority: .medium)
        let fake = FakeRemindersEventSource(
            hasAccess: true,
            seed: [(calendarItemId: "cal-1", task: task)]
        )
        let backlog = makeBacklogService(seed: [task])
        let settings = makeSettings()
        settings.remindersScheduleAlarms = true
        settings.remindersScheduleAlarmLeadMinutes = [ReminderInterval(minutes: 10)]

        _ = RemindersSyncService(
            settings: settings,
            backlogService: backlog,
            remindersSource: fake
        )

        let imminent = Date().addingTimeInterval(30)
        backlog.markScheduled(id: task.id, eventIds: ["evt-1"], date: imminent)
        await waitForObservers()

        let alarms = scheduleInvocations(fake).first?.alarmDates ?? []
        XCTAssertEqual(alarms, [imminent], "T-10 dropped because it's in the past")
    }

    func testScheduleWritebackClearsAlarmsWhenUnscheduled() async {
        var task = BacklogTask(id: "reminder_cal-1", title: "Walk dog", durationMinutes: 30, priority: .medium)
        task.deadline = nil
        let fake = FakeRemindersEventSource(
            hasAccess: true,
            seed: [(calendarItemId: "cal-1", task: task)]
        )
        let backlog = makeBacklogService(seed: [task])
        let settings = makeSettings()
        settings.remindersScheduleAlarms = true

        _ = RemindersSyncService(
            settings: settings,
            backlogService: backlog,
            remindersSource: fake
        )

        backlog.unschedule(id: task.id)
        await waitForObservers()

        let calls = scheduleInvocations(fake)
        XCTAssertEqual(calls.last?.dueDate, nil)
        XCTAssertEqual(calls.last?.alarmDates, [], "unscheduling clears alarms")
    }

    func testFlippingAlarmToggleSweepsScheduledTasks() async {
        var task = BacklogTask(id: "reminder_cal-1", title: "Walk dog", durationMinutes: 30, priority: .medium)
        let due = futureDate(hour: 14)
        task.scheduledDate = due
        task.scheduledEventId = "evt-1"
        task.status = .scheduled

        let fake = FakeRemindersEventSource(
            hasAccess: true,
            seed: [(calendarItemId: "cal-1", task: task)]
        )
        let backlog = makeBacklogService(seed: [task])
        let settings = makeSettings()
        settings.remindersScheduleAlarms = false
        // Pin the lead list so we're asserting at-time only, regardless
        // of whatever default the settings init seeded from intervals.
        settings.remindersScheduleAlarmLeadMinutes = []

        _ = RemindersSyncService(
            settings: settings,
            backlogService: backlog,
            remindersSource: fake
        )

        // Flip the toggle on. Settings posts `settingsDidChange` after a
        // 300ms debounce, which the sync service observes and uses to
        // re-apply the schedule for every linked scheduled task as a
        // single batched EventKit transaction.
        settings.remindersScheduleAlarms = true
        try? await Task.sleep(nanoseconds: 500_000_000)

        let batches: [[ScheduleUpdate]] = fake.invocations.compactMap { call in
            if case let .batchSchedule(updates) = call { return updates }
            return nil
        }
        XCTAssertEqual(batches.count, 1, "sweep emitted exactly one batch")
        XCTAssertEqual(batches.first?.count, 1, "exactly one task in the batch")
        XCTAssertEqual(batches.first?.first?.dueDate, due)
        XCTAssertEqual(Set(batches.first?.first?.alarmDates ?? []), [due])
    }

    func testSweepBatchesMultipleScheduledTasksIntoOneCall() async {
        // Two scheduled linked tasks — the sweep must emit a single
        // `applyScheduleUpdates` invocation containing both, not one
        // `updateReminderSchedule` per task.
        var t1 = BacklogTask(id: "reminder_cal-1", title: "T1", durationMinutes: 30, priority: .medium)
        let due1 = futureDate(hour: 14)
        t1.scheduledDate = due1
        t1.scheduledEventId = "evt-1"
        t1.status = .scheduled

        var t2 = BacklogTask(id: "reminder_cal-2", title: "T2", durationMinutes: 30, priority: .medium)
        let due2 = futureDate(hour: 16)
        t2.scheduledDate = due2
        t2.scheduledEventId = "evt-2"
        t2.status = .scheduled

        let fake = FakeRemindersEventSource(
            hasAccess: true,
            seed: [
                (calendarItemId: "cal-1", task: t1),
                (calendarItemId: "cal-2", task: t2),
            ]
        )
        let backlog = makeBacklogService(seed: [t1, t2])
        let settings = makeSettings()
        settings.remindersScheduleAlarms = false
        settings.remindersScheduleAlarmLeadMinutes = []

        _ = RemindersSyncService(
            settings: settings,
            backlogService: backlog,
            remindersSource: fake
        )

        settings.remindersScheduleAlarms = true
        try? await Task.sleep(nanoseconds: 500_000_000)

        let perTaskWritebacks = fake.invocations.filter {
            if case .updateSchedule = $0 { return true }
            return false
        }
        XCTAssertTrue(perTaskWritebacks.isEmpty,
            "sweep must not fall through to per-task writebacks")

        let batches: [[ScheduleUpdate]] = fake.invocations.compactMap { call in
            if case let .batchSchedule(updates) = call { return updates }
            return nil
        }
        XCTAssertEqual(batches.count, 1, "exactly one batch transaction")
        XCTAssertEqual(batches.first?.count, 2, "both scheduled tasks in the same batch")
    }

    func testDefaultLeadMinutesMirrorMeetingIntervals() {
        // Fresh ReminderSettings should seed the iPhone alarm lead-times
        // from the meeting reminder intervals. Tests against the default
        // intervals (20, 2) — if those defaults change, this test
        // intentionally tracks the new shape.
        let settings = ReminderSettings()
        XCTAssertEqual(
            settings.remindersScheduleAlarmLeadMinutes.map(\.minutes),
            settings.intervals.map(\.minutes),
            "lead-times default to a copy of the meeting intervals"
        )
        XCTAssertEqual(
            settings.remindersScheduleAlarmLeadMinutes.map(\.isEnabled),
            settings.intervals.map(\.isEnabled)
        )
    }

    // MARK: - Existing import tests

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
