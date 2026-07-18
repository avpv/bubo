import XCTest
@testable import Bubo
@testable import BuboDomain
@testable import BuboOptimizer

/// Tests the pure, static helpers on `AppleRemindersService` — priority
/// mapping and due-date-components conversion. These are the parts of the
/// service that don't touch EventKit and can be exercised deterministically.
///
/// @MainActor: the service class is @MainActor, so even its pure statics
/// are main-actor-isolated — synchronous calls from a nonisolated test
/// class don't compile under Xcode 16's Swift.
@MainActor
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

    // MARK: - Notes / URL Codec

    func testComposeNotesReturnsNilWhenEmpty() {
        XCTAssertNil(AppleRemindersService.composeNotes(notes: nil, url: nil))
        XCTAssertNil(AppleRemindersService.composeNotes(notes: "", url: nil))
        XCTAssertNil(AppleRemindersService.composeNotes(notes: "   \n  ", url: nil))
    }

    func testComposeNotesPlainBody() {
        let composed = AppleRemindersService.composeNotes(
            notes: "Design the launch",
            url: nil
        )
        XCTAssertEqual(composed, "Design the launch")
    }

    func testComposeNotesWithURLOnly() {
        let composed = AppleRemindersService.composeNotes(
            notes: nil,
            url: URL(string: "https://example.com/spec")
        )
        XCTAssertEqual(composed, "URL: https://example.com/spec")
    }

    func testComposeNotesWithURLAndBody() {
        let composed = AppleRemindersService.composeNotes(
            notes: "Ship the thing",
            url: URL(string: "https://example.com/spec")
        )
        XCTAssertEqual(composed, "URL: https://example.com/spec\n\nShip the thing")
    }

    func testExtractURLFromNotesWithSentinel() {
        let (url, notes) = AppleRemindersService.extractURL(
            fromNotes: "URL: https://example.com/spec\n\nShip the thing"
        )
        XCTAssertEqual(url, URL(string: "https://example.com/spec"))
        XCTAssertEqual(notes, "Ship the thing")
    }

    func testExtractURLFromPlainNotesHasNoURL() {
        let (url, notes) = AppleRemindersService.extractURL(
            fromNotes: "Just a regular note"
        )
        XCTAssertNil(url)
        XCTAssertEqual(notes, "Just a regular note")
    }

    func testExtractURLRejectsInvalidSentinel() {
        // Leading "URL:" but the payload doesn't parse — keep the whole
        // string visible instead of silently dropping it.
        let (url, notes) = AppleRemindersService.extractURL(
            fromNotes: "URL: \n\nbody"
        )
        XCTAssertNil(url)
        XCTAssertEqual(notes, "URL: \n\nbody")
    }

    func testNotesURLRoundTrip() {
        let original = BacklogTask(
            title: "Draft",
            notes: "Bullet A\nBullet B",
            url: URL(string: "https://example.com/doc")
        )
        let composed = AppleRemindersService.composeNotes(
            notes: original.notes,
            url: original.url
        )
        let (url, notes) = AppleRemindersService.extractURL(fromNotes: composed)
        XCTAssertEqual(url, original.url)
        XCTAssertEqual(notes, original.notes)
    }

    // MARK: - Subtasks Codec

    func testComposeNotesWithSubtasksOnly() {
        let composed = AppleRemindersService.composeNotes(
            notes: nil,
            url: nil,
            subtasks: [
                Subtask(title: "Buy charger"),
                Subtask(title: "Pack laptop", isDone: true),
            ]
        )
        XCTAssertEqual(
            composed,
            "Subtasks:\n- [ ] Buy charger\n- [x] Pack laptop"
        )
    }

    func testComposeNotesWithURLSubtasksAndBody() {
        let composed = AppleRemindersService.composeNotes(
            notes: "Don't forget passport",
            url: URL(string: "https://example.com/trip"),
            subtasks: [Subtask(title: "Book hotel")]
        )
        XCTAssertEqual(
            composed,
            "URL: https://example.com/trip\n\nSubtasks:\n- [ ] Book hotel\n\nDon't forget passport"
        )
    }

    func testExtractAttachmentsParsesChecklist() {
        let parsed = AppleRemindersService.extractAttachments(
            fromNotes: "Subtasks:\n- [ ] First\n- [x] Second\n\nbody text"
        )
        XCTAssertNil(parsed.url)
        XCTAssertEqual(parsed.notes, "body text")
        XCTAssertEqual(parsed.subtasks.count, 2)
        XCTAssertEqual(parsed.subtasks[0].title, "First")
        XCTAssertFalse(parsed.subtasks[0].isDone)
        XCTAssertEqual(parsed.subtasks[1].title, "Second")
        XCTAssertTrue(parsed.subtasks[1].isDone)
    }

    func testExtractAttachmentsHandlesURLAndChecklist() {
        let parsed = AppleRemindersService.extractAttachments(
            fromNotes: "URL: https://example.com/trip\n\nSubtasks:\n- [ ] One\n\nbody"
        )
        XCTAssertEqual(parsed.url, URL(string: "https://example.com/trip"))
        XCTAssertEqual(parsed.notes, "body")
        XCTAssertEqual(parsed.subtasks.map(\.title), ["One"])
    }

    func testExtractAttachmentsLeavesPlainNotesIntact() {
        // No sentinels at all → original text stays in notes verbatim, not
        // misinterpreted as an empty subtask block or partial URL line.
        let parsed = AppleRemindersService.extractAttachments(
            fromNotes: "- [ ] looks like a subtask but no header"
        )
        XCTAssertNil(parsed.url)
        XCTAssertEqual(parsed.notes, "- [ ] looks like a subtask but no header")
        XCTAssertTrue(parsed.subtasks.isEmpty)
    }

    func testSubtasksRoundTripPreservesOrderAndDoneFlags() {
        let original = [
            Subtask(title: "alpha", isDone: false),
            Subtask(title: "beta", isDone: true),
            Subtask(title: "gamma", isDone: false),
        ]
        let composed = AppleRemindersService.composeNotes(
            notes: "context",
            url: URL(string: "https://example.com"),
            subtasks: original
        )
        let parsed = AppleRemindersService.extractAttachments(fromNotes: composed)
        XCTAssertEqual(parsed.url, URL(string: "https://example.com"))
        XCTAssertEqual(parsed.notes, "context")
        XCTAssertEqual(parsed.subtasks.map(\.title), original.map(\.title))
        XCTAssertEqual(parsed.subtasks.map(\.isDone), original.map(\.isDone))
    }

    func testExtractURLBackwardCompatibilityShimDropsSubtasks() {
        // The legacy two-tuple API must keep working — callers that haven't
        // migrated to `extractAttachments` see only url + notes, with the
        // subtasks block treated as part of the structured prefix and
        // therefore stripped from the notes body.
        let (url, notes) = AppleRemindersService.extractURL(
            fromNotes: "Subtasks:\n- [ ] x\n\nbody"
        )
        XCTAssertNil(url)
        XCTAssertEqual(notes, "body")
    }

    // MARK: - Tag Normalization

    func testNormalizeTagStripsHashAndLowercases() {
        XCTAssertEqual(BacklogTask.normalizeTag("#Design"), "design")
        XCTAssertEqual(BacklogTask.normalizeTag("urgent"), "urgent")
        XCTAssertEqual(BacklogTask.normalizeTag("  #Backend  "), "backend")
    }

    func testNormalizeTagJoinsInternalWhitespace() {
        XCTAssertEqual(BacklogTask.normalizeTag("home assistant"), "home-assistant")
        XCTAssertEqual(BacklogTask.normalizeTag("#multi  word  tag"), "multi-word-tag")
    }

    func testNormalizeTagReturnsNilForEmpty() {
        XCTAssertNil(BacklogTask.normalizeTag(""))
        XCTAssertNil(BacklogTask.normalizeTag("   "))
        XCTAssertNil(BacklogTask.normalizeTag("#"))
        XCTAssertNil(BacklogTask.normalizeTag("# "))
    }

    // MARK: - Tags Codec

    func testComposeNotesWithTagsOnly() {
        let composed = AppleRemindersService.composeNotes(
            notes: nil, url: nil,
            tags: ["design", "urgent"]
        )
        XCTAssertEqual(composed, "Tags: #design #urgent")
    }

    func testComposeNotesURLAndTagsAndBody() {
        let composed = AppleRemindersService.composeNotes(
            notes: "do it",
            url: URL(string: "https://example.com"),
            tags: ["work"]
        )
        XCTAssertEqual(
            composed,
            "URL: https://example.com\n\nTags: #work\n\ndo it"
        )
    }

    func testExtractAttachmentsParsesTags() {
        let parsed = AppleRemindersService.extractAttachments(
            fromNotes: "Tags: #design #urgent\n\nbody"
        )
        XCTAssertNil(parsed.url)
        XCTAssertEqual(parsed.notes, "body")
        XCTAssertEqual(parsed.tags, ["design", "urgent"])
        XCTAssertTrue(parsed.subtasks.isEmpty)
    }

    func testExtractAttachmentsHandlesAllSentinelsTogether() {
        let composed = AppleRemindersService.composeNotes(
            notes: "context line",
            url: URL(string: "https://example.com/doc"),
            subtasks: [
                Subtask(title: "first", isDone: true),
                Subtask(title: "second"),
            ],
            tags: ["alpha", "beta"]
        )
        let parsed = AppleRemindersService.extractAttachments(fromNotes: composed)
        XCTAssertEqual(parsed.url, URL(string: "https://example.com/doc"))
        XCTAssertEqual(parsed.notes, "context line")
        XCTAssertEqual(parsed.subtasks.map(\.title), ["first", "second"])
        XCTAssertEqual(parsed.subtasks.map(\.isDone), [true, false])
        XCTAssertEqual(parsed.tags, ["alpha", "beta"])
    }

    func testExtractAttachmentsTagsLineDropsBareTokens() {
        // Tokens without "#" prefix are user-typed words, not tags —
        // dropping them silently keeps the parser narrow and the
        // sentinel meaning unambiguous.
        let parsed = AppleRemindersService.extractAttachments(
            fromNotes: "Tags: #real word #other"
        )
        XCTAssertEqual(parsed.tags, ["real", "other"])
    }

    func testTagsRoundTripPreservesOrderAndCase() {
        // Stored canonical form is lowercase; once normalised on the
        // way in, round-trips keep the same shape.
        let original = ["design", "p1", "home-assistant"]
        let composed = AppleRemindersService.composeNotes(
            notes: nil, url: nil, tags: original
        )
        let parsed = AppleRemindersService.extractAttachments(fromNotes: composed)
        XCTAssertEqual(parsed.tags, original)
    }

    // MARK: - Subtask Progress

    func testSubtaskProgressEmpty() {
        let task = BacklogTask(title: "no subs")
        let progress = task.subtaskProgress
        XCTAssertEqual(progress.done, 0)
        XCTAssertEqual(progress.total, 0)
    }

    func testSubtaskProgressPartial() {
        let task = BacklogTask(
            title: "with subs",
            subtasks: [
                Subtask(title: "a", isDone: true),
                Subtask(title: "b", isDone: false),
                Subtask(title: "c", isDone: true),
            ]
        )
        let progress = task.subtaskProgress
        XCTAssertEqual(progress.done, 2)
        XCTAssertEqual(progress.total, 3)
    }
}
