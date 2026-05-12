import XCTest
@testable import Bubo
@testable import BuboDomain
@testable import BuboOptimizer

/// Tests for the additive composition model in ``SuggestionEngine``.
///
/// Two contributor types are tested independently:
/// - ``SuggestionEngine/Signal`` — user-facing, priority-ordered.
/// - ``SuggestionEngine/ContextLayer`` — silent, always-on time layers.
///
/// The composer is exercised through `signals(...)` + `contextLayers(...)` +
/// `compose(signals:layers:)`, all of which are pure statics and do not
/// require a live `ReminderService`.
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
        let suggestion = SuggestionEngine.compose(signals: [], layers: [])
        XCTAssertNil(suggestion)
    }

    /// Context layers alone (lunch/wind-down firing on time context) must not
    /// surface the banner — the banner needs a reason, and layers carry none.
    func testContextLayersAloneProduceNoSuggestion() {
        let layers = SuggestionEngine.contextLayers(hour: 17, meetingsCount: 0)
        XCTAssertFalse(layers.isEmpty)
        XCTAssertNil(SuggestionEngine.compose(signals: [], layers: layers))
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
        let layers = SuggestionEngine.contextLayers(hour: 10, meetingsCount: 6)
        let request = try! XCTUnwrap(SuggestionEngine.compose(signals: signals, layers: layers)?.request)

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
        let request = try! XCTUnwrap(SuggestionEngine.compose(signals: signals, layers: [])?.request)

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

    /// Speed is single-cardinality. Overdue (priority 100, `.quick`) beats
    /// urgent (priority 90, `.balanced`).
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
        let request = try! XCTUnwrap(SuggestionEngine.compose(signals: signals, layers: [])?.request)

        let speeds = request.intents.compactMap { intent -> Speed? in
            if case .speed(let s) = intent { return s }
            return nil
        }
        XCTAssertEqual(speeds, [.quick], "Only the highest-priority signal's speed should apply")
    }

    /// Context layers must never override a signal's cardinality choice.
    /// If a layer added `.speed(.thorough)` it would break the contract.
    /// (None of the current layers set cardinality keys, but guard the rule.)
    func testContextLayerCannotOverrideSignalCardinality() {
        let signal = SuggestionEngine.Signal(
            name: "test-signal",
            priority: 50,
            intents: [.speed(.quick)],
            reasonFragment: "test"
        )
        let layer = SuggestionEngine.ContextLayer(
            name: "rogue-layer",
            intents: [.speed(.thorough)]
        )
        let request = try! XCTUnwrap(
            SuggestionEngine.compose(signals: [signal], layers: [layer])?.request
        )
        let speeds = request.intents.compactMap { intent -> Speed? in
            if case .speed(let s) = intent { return s }
            return nil
        }
        XCTAssertEqual(speeds, [.quick])
    }

    func testHorizonLockedToToday() {
        let signals = SuggestionEngine.signals(
            hour: 9,
            meetingsCount: 0,
            todayEventsCount: 0,
            hasFocusToday: true,
            pending: Array(repeating: makeTask(), count: 3),
            urgent: [],
            overdue: []
        )
        let request = try! XCTUnwrap(SuggestionEngine.compose(signals: signals, layers: [])?.request)
        let horizons = request.intents.compactMap { intent -> Horizon? in
            if case .horizon(let h) = intent { return h }
            return nil
        }
        XCTAssertEqual(horizons, [.today])
    }

    // MARK: - Silent Time-Aware Layers

    func testLayersContributeIntentsButNotReason() {
        let signals = SuggestionEngine.signals(
            hour: 16,
            meetingsCount: 3,
            todayEventsCount: 4,
            hasFocusToday: true,
            pending: [],
            urgent: [],
            overdue: [makeTask(title: "old")]
        )
        let layers = SuggestionEngine.contextLayers(hour: 16, meetingsCount: 3)
        let suggestion = try! XCTUnwrap(SuggestionEngine.compose(signals: signals, layers: layers))

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
        let signals = SuggestionEngine.signals(
            hour: 11,
            meetingsCount: 5,
            todayEventsCount: 5,
            hasFocusToday: true,
            pending: Array(repeating: makeTask(), count: 3),
            urgent: [],
            overdue: [makeTask(title: "old")]
        )
        let suggestion = try! XCTUnwrap(SuggestionEngine.compose(signals: signals, layers: []))

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
        let suggestion = try! XCTUnwrap(SuggestionEngine.compose(signals: signals, layers: []))
        XCTAssertFalse(suggestion.reason.contains(" · "))
    }

    // MARK: - Attribution

    /// Attribution must answer "why did this intent appear?". Every intent
    /// in the final request should be owned by exactly one contributor.
    func testAttributionCoversAllIntents() {
        let signals = SuggestionEngine.signals(
            hour: 10,
            meetingsCount: 6,
            todayEventsCount: 6,
            hasFocusToday: false,
            pending: [],
            urgent: [],
            overdue: [makeTask(title: "old")]
        )
        let layers = SuggestionEngine.contextLayers(hour: 10, meetingsCount: 6)
        let suggestion = try! XCTUnwrap(SuggestionEngine.compose(signals: signals, layers: layers))

        let allAttributed = suggestion.contributions.values.flatMap { $0 }
        let attributedSet = Set(allAttributed)
        let requestSet = Set(suggestion.request.intents)
        XCTAssertEqual(attributedSet, requestSet,
                       "Every intent must be attributed to exactly one contributor")
    }

    /// Dedup attribution rule: the first contributor to add an intent owns it.
    /// With overdue (100) + pending-tasks (60) both voting `.includeBacklog`,
    /// overdue must be the credited owner.
    func testAttributionCreditsFirstContributor() {
        let signals = SuggestionEngine.signals(
            hour: 11,
            meetingsCount: 0,
            todayEventsCount: 0,
            hasFocusToday: true,
            pending: [makeTask(), makeTask(), makeTask()],
            urgent: [],
            overdue: [makeTask(title: "old")]
        )
        let suggestion = try! XCTUnwrap(SuggestionEngine.compose(signals: signals, layers: []))

        let overdueOwns = suggestion.contributions["overdue"] ?? []
        let pendingOwns = suggestion.contributions["pending-tasks"] ?? []
        XCTAssertTrue(overdueOwns.contains(.includeBacklog))
        XCTAssertFalse(pendingOwns.contains(.includeBacklog),
                       "Lower-priority signal must not re-claim a deduped intent")
    }

    // MARK: - IntentConflictDetector Integration

    /// Both the detector and the composer must key off the same
    /// ``IntentCardinalityKey``. If the composer emits a dedup'd request
    /// the detector should see zero redundancy warnings.
    func testComposedRequestHasNoCardinalityRedundancy() {
        let signals = SuggestionEngine.signals(
            hour: 11,
            meetingsCount: 5,
            todayEventsCount: 5,
            hasFocusToday: true,
            pending: Array(repeating: makeTask(), count: 3),
            urgent: [makeTask(title: "demo", deadline: Date().addingTimeInterval(3600))],
            overdue: [makeTask(title: "old")]
        )
        let layers = SuggestionEngine.contextLayers(hour: 11, meetingsCount: 5)
        let request = try! XCTUnwrap(
            SuggestionEngine.compose(signals: signals, layers: layers)?.request
        )
        let warnings = IntentConflictDetector.analyze(request.intents)
            .filter { $0.severity == .warning }
        let cardinalityWarnings = warnings.filter { conflict in
            IntentCardinalityKey.allCases.contains {
                conflict.message.contains($0.rawValue)
            }
        }
        XCTAssertTrue(cardinalityWarnings.isEmpty,
                      "Composer output must not trigger cardinality redundancy warnings")
    }
}
