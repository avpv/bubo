import XCTest
@testable import Bubo
@testable import BuboDomain
@testable import BuboOptimizer

final class QuickActionRankerTests: XCTestCase {

    // MARK: - combinedScore

    func testCombinedScoreZeroContextBoostYieldsZero() {
        // Even popular actions should be hidden when context is irrelevant.
        let score = QuickActionRanker.combinedScore(
            points: 10.0, contextBoost: 0.0, hoursSinceRelevant: 0
        )
        XCTAssertEqual(score, 0.0)
    }

    func testCombinedScoreDecaysOverTime() {
        let fresh = QuickActionRanker.combinedScore(
            points: 1.0, contextBoost: 1.0, hoursSinceRelevant: 0
        )
        let old = QuickActionRanker.combinedScore(
            points: 1.0, contextBoost: 1.0, hoursSinceRelevant: 24
        )
        XCTAssertGreaterThan(fresh, old)
    }

    func testCombinedScoreContextBoostIsMultiplicative() {
        let low = QuickActionRanker.combinedScore(
            points: 1.0, contextBoost: 1.0, hoursSinceRelevant: 0
        )
        let high = QuickActionRanker.combinedScore(
            points: 1.0, contextBoost: 2.0, hoursSinceRelevant: 0
        )
        XCTAssertEqual(high, low * 2.0, accuracy: 0.0001)
    }

    // MARK: - usagePoints

    func testUsagePointsBaselineForNewAction() {
        // Never-used: 0 frequency, 0 history → base 1.0 + 50% default × 2 = 2.0
        let points = QuickActionRanker.usagePoints(frequency: 0, accepts: 0, rejects: 0)
        XCTAssertEqual(points, 2.0, accuracy: 0.0001)
    }

    func testUsagePointsRewardsAcceptance() {
        let allRejected = QuickActionRanker.usagePoints(frequency: 0, accepts: 0, rejects: 5)
        let allAccepted = QuickActionRanker.usagePoints(frequency: 0, accepts: 5, rejects: 0)
        XCTAssertGreaterThan(allAccepted, allRejected)
    }

    func testUsagePointsRewardsFrequency() {
        let rare = QuickActionRanker.usagePoints(frequency: 0, accepts: 1, rejects: 1)
        let frequent = QuickActionRanker.usagePoints(frequency: 10, accepts: 1, rejects: 1)
        XCTAssertEqual(frequent - rare, 3.0, accuracy: 0.0001)
    }

    // MARK: - contextScore — counts-based signals

    func testContextScoreOverdueZeroWhenEmpty() {
        XCTAssertEqual(score(.overdueExists, overdue: 0), 0)
    }

    func testContextScoreOverdueGrowsAndCaps() {
        XCTAssertEqual(score(.overdueExists, overdue: 1), 1.5, accuracy: 0.0001)
        XCTAssertEqual(score(.overdueExists, overdue: 2), 2.0, accuracy: 0.0001)
        XCTAssertLessThanOrEqual(score(.overdueExists, overdue: 100), 3.0)
    }

    func testContextScoreUrgentZeroAndCapped() {
        XCTAssertEqual(score(.urgentDeadline, urgent: 0), 0)
        XCTAssertGreaterThan(score(.urgentDeadline, urgent: 1), 0)
        XCTAssertLessThanOrEqual(score(.urgentDeadline, urgent: 50), 3.0)
    }

    func testContextScorePendingZeroAndCapped() {
        XCTAssertEqual(score(.pendingTasks, pending: 0), 0)
        XCTAssertGreaterThan(score(.pendingTasks, pending: 1), 0)
        XCTAssertLessThanOrEqual(score(.pendingTasks, pending: 100), 2.5)
    }

    func testContextScoreMeetingHeavyTriggersAtFiveAndCaps() {
        XCTAssertEqual(score(.meetingHeavy, meetings: 4), 0)
        XCTAssertGreaterThan(score(.meetingHeavy, meetings: 5), 0)
        XCTAssertLessThanOrEqual(score(.meetingHeavy, meetings: 50), 2.5)
    }

    // MARK: - contextScore — focus

    func testContextScoreNoFocusZeroWhenFocusExists() {
        XCTAssertEqual(score(.noFocusToday, hour: 9, hasFocus: true), 0)
    }

    func testContextScoreNoFocusBoundaries() {
        // Buckets: [<10: 2.5][10–13: 1.8][14–16: 0.8][17+: 0]
        XCTAssertEqual(score(.noFocusToday, hour: 9), 2.5)
        XCTAssertEqual(score(.noFocusToday, hour: 10), 1.8)
        XCTAssertEqual(score(.noFocusToday, hour: 13), 1.8)
        XCTAssertEqual(score(.noFocusToday, hour: 14), 0.8)
        XCTAssertEqual(score(.noFocusToday, hour: 16), 0.8)
        XCTAssertEqual(score(.noFocusToday, hour: 17), 0)
        XCTAssertEqual(score(.noFocusToday, hour: 20), 0)
    }

    // MARK: - contextScore — pure time-of-day signals

    func testContextScoreMorningOrganize() {
        XCTAssertEqual(score(.morningOrganize, hour: 8), 2.0)
        XCTAssertEqual(score(.morningOrganize, hour: 10), 1.0)
        XCTAssertEqual(score(.morningOrganize, hour: 12), 0)
    }

    func testContextScorePlanTomorrow() {
        XCTAssertEqual(score(.planTomorrow, hour: 10), 0)
        XCTAssertEqual(score(.planTomorrow, hour: 14), 0.5)
        XCTAssertEqual(score(.planTomorrow, hour: 17), 1.5)
    }

    func testContextScoreLowEnergy() {
        XCTAssertEqual(score(.lowEnergy, hour: 10), 0)
        XCTAssertEqual(score(.lowEnergy, hour: 14), 1.5)
        XCTAssertEqual(score(.lowEnergy, hour: 16), 0)
    }

    func testContextScoreAlwaysAvailable() {
        XCTAssertEqual(score(.alwaysAvailable, hour: 0), 0.3)
    }

    // MARK: - reason

    func testReasonForOverdueIncludesCount() {
        let r = reason(.overdueExists, overdue: 3)
        XCTAssertTrue(r.contains("3"))
        XCTAssertTrue(r.lowercased().contains("overdue"))
    }

    func testReasonHandlesSingularPlural() {
        XCTAssertTrue(reason(.urgentDeadline, urgent: 1).contains("1 deadline within"))
        XCTAssertTrue(reason(.urgentDeadline, urgent: 5).contains("5 deadlines within"))
    }

    func testReasonForPendingIncludesCount() {
        let r = reason(.pendingTasks, pending: 7)
        XCTAssertTrue(r.contains("7"))
        XCTAssertTrue(r.lowercased().contains("schedule"))
    }

    func testReasonForMeetingsIncludesCount() {
        let r = reason(.meetingHeavy, meetings: 6)
        XCTAssertTrue(r.contains("6"))
        XCTAssertTrue(r.lowercased().contains("meeting"))
    }

    func testReasonAlwaysAvailableIsEmpty() {
        // Tooltip falls back to the chip label, not a tautological «Always
        // available» — the QuickActions view handles that by checking
        // `reason.isEmpty`.
        XCTAssertEqual(reason(.alwaysAvailable), "")
    }

    // MARK: - Helpers

    /// Builds a `ContextInputs` with caller-supplied overrides and delegates
    /// to the static scorer. Keeps individual tests focused on one signal.
    private func score(
        _ signal: ContextSignal,
        overdue: Int = 0,
        urgent: Int = 0,
        pending: Int = 0,
        meetings: Int = 0,
        hour: Int = 9,
        hasFocus: Bool = false
    ) -> Double {
        let inputs = QuickActionRanker.ContextInputs(
            overdueCount: overdue,
            urgentCount: urgent,
            pendingCount: pending,
            hour: hour,
            hasFocusToday: hasFocus,
            meetingsTodayCount: meetings
        )
        return QuickActionRanker.contextScore(for: signal, inputs: inputs)
    }

    /// Same shape as `score` but for the new `reason` static helper —
    /// keeps reason tests as one-liners.
    private func reason(
        _ signal: ContextSignal,
        overdue: Int = 0,
        urgent: Int = 0,
        pending: Int = 0,
        meetings: Int = 0,
        hour: Int = 9,
        hasFocus: Bool = false
    ) -> String {
        let inputs = QuickActionRanker.ContextInputs(
            overdueCount: overdue,
            urgentCount: urgent,
            pendingCount: pending,
            hour: hour,
            hasFocusToday: hasFocus,
            meetingsTodayCount: meetings
        )
        return QuickActionRanker.reason(for: signal, inputs: inputs)
    }
}
