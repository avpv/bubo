import XCTest
@testable import Bubo

/// Tests for the additive composition model in ``SuggestionEngine``.
///
/// The production code uses signals (`overdue`, `urgent`, `meetings-heavy`,
/// `pending-tasks`, `no-focus`, `organize-morning`, plus silent time-aware
/// layers) that are produced independently and merged by the composer.
///
/// These tests exercise the composer through the static `signals(...)` +
/// `compose(_:)` pair, which is pure and does not require a `ReminderService`.
@MainActor
final class SuggestionEngineTests: XCTestCase {

    // MARK: - Helpers

    private func makeTask(
        id: String = UUID().uuidString,
        title: String = "Task",
        deadline: Date? = nil
    ) -> BacklogTask {
        BacklogTask(
            id: id,
            title: title,
            durationMinutes: 30,
            priority: .medium,
            deadline: deadline
        )
    }

    private func hasIntent(
        _ request: OptimizationRequest,
        _ predicate: (ScheduleIntent) -> Bool
    ) -> Bool {
        request.intents.contains(where: predicate)
    }

    // MARK: - Empty State

    func testNoSignalsProducesNoSuggestion() {
        let signals = SuggestionEngine.signals(
            hour: 11,
            meetingsCount: 0,
            todayEventsCount: 0,
            hasFocusToday: true,
            pending: [],
            urgent: [],
            overdue: []
        )
        XCTAssertNil(SuggestionEngine.compose(signals))
    }

    func testSilentSignalsAloneProduceNoSuggestion() {
        // 15:00 triggers `protect-lunch` silently, but nothing else —
        // the banner should stay empty.
        let signals = SuggestionEngine.signals(
            hour: 15,
            meetingsCount: 0,
            todayEventsCount: 0,
            hasFocusToday: true,
            pending: [],
            urgent: [],
            overdue: []
        )
        XCTAssertFalse(signals.isEmpty)
        XCTAssertTrue(signals.allSatisfy(\.isSilent))
        XCTAssertNil(SuggestionEngine.compose(signals))
    }

    // MARK: - Additive Composition

    /// The old cascade silently dropped meeting-batching when overdue tasks
    /// existed. The additive composer must keep both.
    func testOverdueAndMeetingHeavyDayComposesBoth() {
        let signals = SuggestionEngine.signals(
            hour: 10,
            meetingsCount: 6,
            todayEventsCount: 6,
            hasFocusToday: false,
            pending: [],
            urgent: [],
            overdue: [makeTask(title: "ship PR")]
        )
        let suggestion = SuggestionEngine.compose(signals)
        let request = try! XCTUnwrap(suggestion?.request)

        // Overdue contributes findSlotsForBacklog + includeBacklog.
        XCTAssertTrue(hasIntent(request) {
            if case .findSlotsForBacklog = $0 { return true }; return false
        })
        XCTAssertTrue(hasIntent(request) {
            if case .includeBacklog = $0 { return true }; return false
        })
        // Meeting-heavy contributes batchMeetings — the key regression test.
        XCTAssertTrue(hasIntent(request) {
            if case .batchMeetings = $0 { return true }; return false
        })
    }

    func testExactDuplicatesAreDeduped() {
        // Both overdue and pending-tasks vote for includeBacklog + findSlots.
        let signals = SuggestionEngine.signals(
            hour: 11,
            meetingsCount: 0,
            todayEventsCount: 0,
            hasFocusToday: true,
            pending: [makeTask(), makeTask(), makeTask()],
            urgent: [],
            overdue: [makeTask(title: "old")]
        )
        let request = try! XCTUnwrap(SuggestionEngine.compose(signals)?.request)

        let includeBacklogCount = request.intents.filter {
            if case .includeBacklog = $0 { return true }; return false
        }.count
        let findSlotsCount = request.intents.filter {
            if case .findSlotsForBacklog = $0 { return true }; return false
        }.count

        XCTAssertEqual(includeBacklogCount, 1, "includeBacklog must dedupe to 1")
        XCTAssertEqual(findSlotsCount, 1, "findSlotsForBacklog must dedupe to 1")
    }

    // MARK: - Single-Cardinality Resolution

    /// Speed is single-cardinality. With overdue (priority 100, `.quick`)
    /// and urgent (priority 90, `.balanced`), overdue must win.
    func testHigherPrioritySignalWinsSpeed() {
        let signals = SuggestionEngine.signals(
            hour: 11,
            meetingsCount: 0,
            todayEventsCount: 0,
            hasFocusToday: true,
            pending: [],
            urgent: [makeTask(title: "demo", deadline: Date().addingTimeInterval(3600))],
            overdue: [makeTask(title: "old")]
        )
        let request = try! XCTUnwrap(SuggestionEngine.compose(signals)?.request)

        let speeds = request.intents.compactMap { intent -> Speed? in
            if case .speed(let s) = intent { return s }
            return nil
        }
        XCTAssertEqual(speeds, [.quick], "Only the highest-priority signal's speed should apply")
    }

    func testHorizonLockedToToday() {
        // No signal adds .horizon explicitly; composer seeds it to .today.
        let signals = SuggestionEngine.signals(
            hour: 9,
            meetingsCount: 0,
            todayEventsCount: 0,
            hasFocusToday: true,
            pending: Array(repeating: makeTask(), count: 3),
            urgent: [],
            overdue: []
        )
        let request = try! XCTUnwrap(SuggestionEngine.compose(signals)?.request)
        let horizons = request.intents.compactMap { intent -> Horizon? in
            if case .horizon(let h) = intent { return h }
            return nil
        }
        XCTAssertEqual(horizons, [.today])
    }

    // MARK: - Silent Time-Aware Layers

    func testSilentLayersContributeIntentsButNotReason() {
        // 16:00, overdue task, 3 meetings → wind-down + meeting-prep + protect-lunch
        // should layer in silently; reason should only mention overdue.
        let signals = SuggestionEngine.signals(
            hour: 16,
            meetingsCount: 3,
            todayEventsCount: 4,
            hasFocusToday: true,
            pending: [],
            urgent: [],
            overdue: [makeTask(title: "old")]
        )
        let suggestion = try! XCTUnwrap(SuggestionEngine.compose(signals))

        XCTAssertTrue(hasIntent(suggestion.request) {
            if case .windDown = $0 { return true }; return false
        })
        XCTAssertTrue(hasIntent(suggestion.request) {
            if case .meetingPrep = $0 { return true }; return false
        })
        XCTAssertTrue(hasIntent(suggestion.request) {
            if case .protectLunch = $0 { return true }; return false
        })
        XCTAssertFalse(suggestion.reason.contains("lunch"))
        XCTAssertFalse(suggestion.reason.contains("wind"))
    }

    // MARK: - Reason Text

    func testReasonJoinsTopTwoFragments() {
        // overdue (pri 100) + meetings-heavy (pri 70) + pending (pri 60).
        // Reason should be overdue · meetings, dropping pending.
        let signals = SuggestionEngine.signals(
            hour: 11,
            meetingsCount: 5,
            todayEventsCount: 5,
            hasFocusToday: true,
            pending: Array(repeating: makeTask(), count: 3),
            urgent: [],
            overdue: [makeTask(title: "old")]
        )
        let suggestion = try! XCTUnwrap(SuggestionEngine.compose(signals))

        XCTAssertTrue(suggestion.reason.contains("overdue"), "reason: \(suggestion.reason)")
        XCTAssertTrue(suggestion.reason.contains("meetings"), "reason: \(suggestion.reason)")
        XCTAssertTrue(suggestion.reason.contains(" · "), "reason should join fragments: \(suggestion.reason)")
    }

    func testSingleSignalReasonHasNoSeparator() {
        let signals = SuggestionEngine.signals(
            hour: 11,
            meetingsCount: 0,
            todayEventsCount: 0,
            hasFocusToday: true,
            pending: Array(repeating: makeTask(), count: 3),
            urgent: [],
            overdue: []
        )
        let suggestion = try! XCTUnwrap(SuggestionEngine.compose(signals))
        XCTAssertFalse(suggestion.reason.contains(" · "))
    }
}
