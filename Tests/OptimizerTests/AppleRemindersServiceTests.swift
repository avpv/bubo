import XCTest
@testable import Bubo

/// Tests the pure, static helpers on `AppleRemindersService` — priority
/// mapping and due-date-components conversion. These are the parts of the
/// service that don't touch EventKit and can be exercised deterministically.
final class AppleRemindersServiceTests: XCTestCase {

    // MARK: - Bubo → Apple Priority Mapping

    func testBuboToApplePriorityHigh() {
        XCTAssertEqual(AppleRemindersService.appleRemindersPriority(from: .high), 1)
    }

    func testBuboToApplePriorityMedium() {
        XCTAssertEqual(AppleRemindersService.appleRemindersPriority(from: .medium), 5)
    }

    func testBuboToApplePriorityLow() {
        XCTAssertEqual(AppleRemindersService.appleRemindersPriority(from: .low), 9)
    }

    // MARK: - Apple → Bubo Priority Mapping

    func testAppleToBuboPriorityNone() {
        // 0 = none (no priority set) → treat as medium default
        XCTAssertEqual(AppleRemindersService.buboPriority(fromAppleReminders: 0), .medium)
    }

    func testAppleToBuboPriorityHighRange() {
        for raw in 1...4 {
            XCTAssertEqual(
                AppleRemindersService.buboPriority(fromAppleReminders: raw), .high,
                "Raw \(raw) should map to .high"
            )
        }
    }

    func testAppleToBuboPriorityMediumExact() {
        XCTAssertEqual(AppleRemindersService.buboPriority(fromAppleReminders: 5), .medium)
    }

    func testAppleToBuboPriorityLowRange() {
        for raw in 6...9 {
            XCTAssertEqual(
                AppleRemindersService.buboPriority(fromAppleReminders: raw), .low,
                "Raw \(raw) should map to .low"
            )
        }
    }

    // MARK: - Round-trip Priority (Bubo → Apple → Bubo)

    func testPriorityRoundTripPreservesValue() {
        for priority in TaskPriority.allCases {
            let raw = AppleRemindersService.appleRemindersPriority(from: priority)
            let back = AppleRemindersService.buboPriority(fromAppleReminders: raw)
            XCTAssertEqual(
                back, priority,
                "\(priority) should round-trip via raw=\(raw)"
            )
        }
    }

    // MARK: - Due Date Components (granularity preservation)

    func testDueDateComponentsForDateOnlyMidnight() {
        // Date at exactly midnight local time → should be date-only
        let cal = Calendar.current
        let midnight = cal.date(from: DateComponents(year: 2026, month: 4, day: 15))!

        let comps = AppleRemindersService.dueDateComponents(from: midnight)

        XCTAssertEqual(comps.year, 2026)
        XCTAssertEqual(comps.month, 4)
        XCTAssertEqual(comps.day, 15)
        // Hour/minute should NOT be set — this is date-only
        XCTAssertNil(comps.hour)
        XCTAssertNil(comps.minute)
    }

    func testDueDateComponentsForDateWithTime() {
        // Date at 3:30 PM → should include time
        let cal = Calendar.current
        let afternoon = cal.date(from: DateComponents(
            year: 2026, month: 4, day: 15, hour: 15, minute: 30
        ))!

        let comps = AppleRemindersService.dueDateComponents(from: afternoon)

        XCTAssertEqual(comps.year, 2026)
        XCTAssertEqual(comps.month, 4)
        XCTAssertEqual(comps.day, 15)
        XCTAssertEqual(comps.hour, 15)
        XCTAssertEqual(comps.minute, 30)
    }

    func testDueDateComponentsForOneMinutePastMidnight() {
        // 00:01 should be treated as timed, not date-only
        let cal = Calendar.current
        let justAfterMidnight = cal.date(from: DateComponents(
            year: 2026, month: 4, day: 15, hour: 0, minute: 1
        ))!

        let comps = AppleRemindersService.dueDateComponents(from: justAfterMidnight)

        XCTAssertEqual(comps.hour, 0)
        XCTAssertEqual(comps.minute, 1)
    }

    // MARK: - Reminders ID Extraction

    func testRemindersIdExtractsFromPrefixedId() {
        let id = AppleRemindersService.remindersId(from: "reminder_ABC-123-DEF")
        XCTAssertEqual(id, "ABC-123-DEF")
    }

    func testRemindersIdReturnsNilForBuboNativeId() {
        // Bubo-native task IDs are UUIDs with no prefix
        let id = AppleRemindersService.remindersId(from: "550e8400-e29b-41d4-a716-446655440000")
        XCTAssertNil(id)
    }

    func testRemindersIdReturnsNilForEmptyInput() {
        XCTAssertNil(AppleRemindersService.remindersId(from: ""))
    }
}
