import XCTest
import SwiftData
@testable import Bubo

/// Tests the model-layer changes that support Apple Reminders two-way sync:
/// - `reminderCalendarItemId` round-trip through `PersistedBacklogTask`
/// - `silentlyUpdateReminderMapping` and `silentlyUpdate` on `BacklogService`
/// - `taskAdded` / `taskUpdated` notifications
///
/// End-to-end EventKit behaviour is covered by manual QA — the EventKit
/// store can't run without a signed macOS app context.
@MainActor
final class RemindersSyncModelTests: XCTestCase {

    private static let persistenceKey = "BuboBacklogTasks"
    private var savedState: Data?
    private var service: BacklogService!

    override func setUp() async throws {
        try await super.setUp()
        savedState = UserDefaults.standard.data(forKey: Self.persistenceKey)
        UserDefaults.standard.removeObject(forKey: Self.persistenceKey)

        let container = try ModelContainer(
            for: PersistedLocalEvent.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        service = BacklogService(modelContainer: container)
    }

    override func tearDown() async throws {
        service = nil
        if let savedState {
            UserDefaults.standard.set(savedState, forKey: Self.persistenceKey)
        } else {
            UserDefaults.standard.removeObject(forKey: Self.persistenceKey)
        }
        savedState = nil
        try await super.tearDown()
    }

    // MARK: - reminderCalendarItemId Round-trip

    func testPersistedTaskPreservesReminderCalendarItemId() {
        var task = BacklogTask(id: "task-1", title: "Buy milk")
        task.reminderCalendarItemId = "apple-reminder-id-abc"

        let persisted = PersistedBacklogTask(from: task, sortOrder: 0)
        let decoded = persisted.toBacklogTask()

        XCTAssertEqual(decoded.reminderCalendarItemId, "apple-reminder-id-abc")
    }

    func testPersistedTaskPreservesNilReminderMapping() {
        let task = BacklogTask(id: "task-2", title: "No reminder")
        let persisted = PersistedBacklogTask(from: task, sortOrder: 0)
        let decoded = persisted.toBacklogTask()

        XCTAssertNil(decoded.reminderCalendarItemId)
    }

    func testUpdateFromPropagatesReminderMapping() {
        let task = BacklogTask(id: "task-3", title: "Original")
        let persisted = PersistedBacklogTask(from: task, sortOrder: 0)

        var updated = task
        updated.reminderCalendarItemId = "new-reminder-id"
        persisted.update(from: updated)

        XCTAssertEqual(persisted.reminderCalendarItemId, "new-reminder-id")
    }

    // MARK: - silentlyUpdateReminderMapping

    func testSilentlyUpdateReminderMappingSetsId() {
        let task = BacklogTask(id: "task-silent-1", title: "Test")
        service.addTask(task)

        service.silentlyUpdateReminderMapping(
            taskId: "task-silent-1",
            reminderCalendarItemId: "new-id"
        )

        let stored = service.tasks.first { $0.id == "task-silent-1" }
        XCTAssertEqual(stored?.reminderCalendarItemId, "new-id")
    }

    func testSilentlyUpdateReminderMappingDoesNotPostTaskUpdated() {
        let task = BacklogTask(id: "task-silent-2", title: "Test")
        service.addTask(task)

        let expectation = expectation(description: "taskUpdated should NOT fire")
        expectation.isInverted = true
        let observer = NotificationCenter.default.addObserver(
            forName: BacklogService.taskUpdated,
            object: nil,
            queue: .main
        ) { _ in expectation.fulfill() }
        defer { NotificationCenter.default.removeObserver(observer) }

        service.silentlyUpdateReminderMapping(
            taskId: "task-silent-2",
            reminderCalendarItemId: "id"
        )

        wait(for: [expectation], timeout: 0.25)
    }

    func testSilentlyUpdateReminderMappingIgnoresUnknownTaskId() {
        // Should not crash or throw for non-existent task.
        service.silentlyUpdateReminderMapping(
            taskId: "ghost-task",
            reminderCalendarItemId: "id"
        )
        XCTAssertTrue(service.tasks.filter { $0.reminderCalendarItemId == "id" }.isEmpty)
    }

    func testSilentlyUpdateReminderMappingCanClearMapping() {
        var task = BacklogTask(id: "task-silent-3", title: "Test")
        task.reminderCalendarItemId = "initial-id"
        service.addTask(task)

        service.silentlyUpdateReminderMapping(
            taskId: "task-silent-3",
            reminderCalendarItemId: nil
        )

        let stored = service.tasks.first { $0.id == "task-silent-3" }
        XCTAssertNil(stored?.reminderCalendarItemId)
    }

    // MARK: - silentlyUpdate

    func testSilentlyUpdateAppliesFieldChangesWithoutNotification() {
        let task = BacklogTask(id: "task-silent-4", title: "Original")
        service.addTask(task)

        let expectation = expectation(description: "taskUpdated should NOT fire")
        expectation.isInverted = true
        let observer = NotificationCenter.default.addObserver(
            forName: BacklogService.taskUpdated,
            object: nil,
            queue: .main
        ) { _ in expectation.fulfill() }
        defer { NotificationCenter.default.removeObserver(observer) }

        var updated = task
        updated.title = "Changed"
        updated.priority = .high
        service.silentlyUpdate(updated)

        wait(for: [expectation], timeout: 0.25)

        let stored = service.tasks.first { $0.id == "task-silent-4" }
        XCTAssertEqual(stored?.title, "Changed")
        XCTAssertEqual(stored?.priority, .high)
    }

    // MARK: - Notifications

    func testAddTaskPostsTaskAddedNotification() {
        let expectation = expectation(description: "taskAdded fires")
        let observer = NotificationCenter.default.addObserver(
            forName: BacklogService.taskAdded,
            object: nil,
            queue: .main
        ) { notification in
            if (notification.object as? String) == "task-notif-1" {
                expectation.fulfill()
            }
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        service.addTask(BacklogTask(id: "task-notif-1", title: "Foo"))
        wait(for: [expectation], timeout: 1.0)
    }

    func testUpdateTaskPostsTaskUpdatedNotification() {
        let task = BacklogTask(id: "task-notif-2", title: "Foo")
        service.addTask(task)

        let expectation = expectation(description: "taskUpdated fires")
        let observer = NotificationCenter.default.addObserver(
            forName: BacklogService.taskUpdated,
            object: nil,
            queue: .main
        ) { notification in
            if (notification.object as? String) == "task-notif-2" {
                expectation.fulfill()
            }
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        var updated = task
        updated.title = "Changed"
        service.updateTask(updated)

        wait(for: [expectation], timeout: 1.0)
    }

    func testRemoveTaskPostsTaskRemovedWithFullTask() {
        var task = BacklogTask(id: "task-notif-3", title: "To remove")
        task.reminderCalendarItemId = "reminder-to-delete"
        service.addTask(task)

        let expectation = expectation(description: "taskRemoved fires with full task")
        let observer = NotificationCenter.default.addObserver(
            forName: BacklogService.taskRemoved,
            object: nil,
            queue: .main
        ) { notification in
            if let removed = notification.object as? BacklogTask,
               removed.id == "task-notif-3",
               removed.reminderCalendarItemId == "reminder-to-delete" {
                expectation.fulfill()
            }
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        _ = service.removeTask(id: "task-notif-3")
        wait(for: [expectation], timeout: 1.0)
    }
}

// MARK: - ReminderSettings New Fields

final class ReminderSettingsExportFieldsTests: XCTestCase {

    func testExportSettingsDefaultToDisabled() {
        let settings = ReminderSettings()
        XCTAssertFalse(settings.remindersExportEnabled)
        XCTAssertNil(settings.remindersExportListId)
        XCTAssertFalse(settings.remindersDeletionSync)
    }

    func testExportSettingsRoundTripThroughCodable() throws {
        let settings = ReminderSettings()
        settings.remindersExportEnabled = true
        settings.remindersExportListId = "list-abc-123"
        settings.remindersDeletionSync = true

        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(ReminderSettings.self, from: data)

        XCTAssertTrue(decoded.remindersExportEnabled)
        XCTAssertEqual(decoded.remindersExportListId, "list-abc-123")
        XCTAssertTrue(decoded.remindersDeletionSync)
    }

    func testDecodingLegacyPayloadWithoutExportFieldsSucceeds() throws {
        // Old builds don't emit the new keys. Decoding must succeed with
        // default values so existing users don't lose their settings.
        let legacyJSON = """
        {
            "intervals": [],
            "syncIntervalMinutes": 5,
            "showFullScreenAlert": true,
            "showSystemNotification": true,
            "selectedCalendarIds": [],
            "isCalendarSyncEnabled": true,
            "selectedSkinID": "system",
            "selectedWallpaperID": "none",
            "customBackgroundPhotoPath": "",
            "customBackgroundPhotoOpacity": 0.25,
            "customBackgroundPhotoBlur": 2,
            "showBadgeCount": true,
            "badgeCountMode": "wholeDay",
            "badgeTimeWindowHours": 8,
            "isRemindersSyncEnabled": false,
            "selectedRemindersListIds": [],
            "remindersCompletionSync": true,
            "remindersDefaultDurationMinutes": 60,
            "isWorldClockEnabled": false,
            "worldClockCityIDs": []
        }
        """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(ReminderSettings.self, from: legacyJSON)
        XCTAssertFalse(decoded.remindersExportEnabled)
        XCTAssertNil(decoded.remindersExportListId)
        XCTAssertFalse(decoded.remindersDeletionSync)
    }
}
