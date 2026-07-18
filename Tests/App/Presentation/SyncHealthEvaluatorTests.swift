import XCTest
@testable import Bubo

// MARK: - SyncHealthEvaluator Tests
//
// Pure-logic table tests for the menu-bar failure mark — every input
// combination is a plain function call, no services involved.

final class SyncHealthEvaluatorTests: XCTestCase {

    private func warning(
        isConnected: Bool = true,
        calendarSyncEnabled: Bool = true,
        calendarSyncError: String? = nil,
        calendarSyncStale: Bool = false,
        cloudSyncWarning: Bool = false
    ) -> Bool {
        SyncHealthEvaluator.menuBarWarning(
            isConnected: isConnected,
            calendarSyncEnabled: calendarSyncEnabled,
            calendarSyncError: calendarSyncError,
            calendarSyncStale: calendarSyncStale,
            cloudSyncWarning: cloudSyncWarning
        )
    }

    func testHealthyStateShowsNoMark() {
        XCTAssertFalse(warning())
    }

    func testCalendarSyncErrorShowsMark() {
        XCTAssertTrue(warning(calendarSyncError: "Calendar access not granted"))
    }

    func testStalePipelineShowsMark() {
        XCTAssertTrue(warning(calendarSyncStale: true))
    }

    func testCloudWarningShowsMark() {
        XCTAssertTrue(warning(cloudSyncWarning: true))
    }

    func testDisabledCalendarSyncSuppressesCalendarSignals() {
        // A deliberately disabled integration is not a failure.
        XCTAssertFalse(warning(
            calendarSyncEnabled: false,
            calendarSyncError: "Calendar sync disabled",
            calendarSyncStale: true
        ))
    }

    func testOfflineGatesEverythingOff() {
        // Offline is environmental — the Wi-Fi menu owns that signal,
        // and errors produced while offline are noise until it returns.
        XCTAssertFalse(warning(
            isConnected: false,
            calendarSyncError: "boom",
            calendarSyncStale: true,
            cloudSyncWarning: true
        ))
    }
}
