import XCTest
@testable import Bubo

final class PomodoroConfigResolverTests: XCTestCase {

    // MARK: Defaults

    func testDefaultsProduceClassicShape() {
        let signals = PomodoroResolveSignals()
        let cfg = PomodoroConfigResolver.resolve(signals: signals)

        XCTAssertEqual(cfg.workMinutes % 5, 0)
        XCTAssertEqual(cfg.breakMinutes % 5, 0)
        XCTAssertGreaterThanOrEqual(cfg.rounds, 1)
        XCTAssertLessThanOrEqual(cfg.rounds, 8)
        XCTAssertLessThanOrEqual(cfg.totalMinutes, 180)
    }

    // MARK: Energy

    func testLowEnergyShrinksWork() {
        var signals = PomodoroResolveSignals()
        signals.isLowEnergy = true
        let cfg = PomodoroConfigResolver.resolve(signals: signals)
        XCTAssertEqual(cfg.workMinutes, PomodoroResolverTuning.default.lowEnergyWork)
    }

    func testNearPeakEnergyStretchesWork() {
        var signals = PomodoroResolveSignals()
        signals.startHour = 10
        signals.peakEnergyHour = 10
        let cfg = PomodoroConfigResolver.resolve(signals: signals)
        XCTAssertGreaterThanOrEqual(cfg.workMinutes, PomodoroResolverTuning.default.nearPeakWork)
    }

    func testFarFromPeakShrinksWork() {
        var signals = PomodoroResolveSignals()
        signals.startHour = 18
        signals.peakEnergyHour = 9
        let cfg = PomodoroConfigResolver.resolve(signals: signals)
        XCTAssertLessThanOrEqual(cfg.workMinutes, PomodoroResolverTuning.default.defaultWork)
    }

    func testDeepWorkHintLengthensWork() {
        var signals = PomodoroResolveSignals()
        signals.wantsDeepWork = true
        let cfg = PomodoroConfigResolver.resolve(signals: signals)
        XCTAssertGreaterThanOrEqual(cfg.workMinutes, PomodoroResolverTuning.default.nearPeakWork)
    }

    func testHighStoryPointsLengthensWork() {
        var signals = PomodoroResolveSignals()
        signals.taskStoryPoints = 13
        let cfg = PomodoroConfigResolver.resolve(signals: signals)
        XCTAssertGreaterThanOrEqual(cfg.workMinutes, PomodoroResolverTuning.default.nearPeakWork)
    }

    // MARK: Deadline

    func testTightDeadlineReducesBreaks() {
        var baseline = PomodoroResolveSignals()
        baseline.taskEstimateMinutes = 90
        let baselineCfg = PomodoroConfigResolver.resolve(signals: baseline)

        var tight = baseline
        tight.deadlineDaysAway = 0
        let tightCfg = PomodoroConfigResolver.resolve(signals: tight)

        XCTAssertLessThanOrEqual(tightCfg.breakMinutes, baselineCfg.breakMinutes)
    }

    // MARK: Slot budget

    func testTightSlotFitsWithinBudget() {
        var signals = PomodoroResolveSignals()
        signals.availableMinutes = 30
        let cfg = PomodoroConfigResolver.resolve(signals: signals)
        XCTAssertLessThanOrEqual(cfg.totalMinutes, 30)
        XCTAssertGreaterThanOrEqual(cfg.rounds, 1)
    }

    func testVeryTightSlotFallsBackToSingleShortRound() {
        var signals = PomodoroResolveSignals()
        signals.availableMinutes = 20
        let cfg = PomodoroConfigResolver.resolve(signals: signals)
        XCTAssertLessThanOrEqual(cfg.totalMinutes, 20)
        XCTAssertEqual(cfg.rounds, 1)
        XCTAssertEqual(cfg.longBreakMinutes, 0)
    }

    func testLargeSlotAllowsLongBreak() {
        var signals = PomodoroResolveSignals()
        signals.availableMinutes = 240
        let cfg = PomodoroConfigResolver.resolve(signals: signals)
        XCTAssertGreaterThan(cfg.longBreakMinutes, 0)
        XCTAssertGreaterThanOrEqual(cfg.rounds, 3)
    }

    // MARK: Task estimate

    func testSmallTaskTrimsRounds() {
        var big = PomodoroResolveSignals()
        big.taskEstimateMinutes = 180
        let bigCfg = PomodoroConfigResolver.resolve(signals: big)

        var small = PomodoroResolveSignals()
        small.taskEstimateMinutes = 40
        let smallCfg = PomodoroConfigResolver.resolve(signals: small)

        XCTAssertLessThan(smallCfg.rounds, bigCfg.rounds)
    }

    // MARK: Bounds

    func testBoundsAlwaysRespected() {
        let tuning = PomodoroResolverTuning.default
        let cases: [PomodoroResolveSignals] = [
            PomodoroResolveSignals(),
            {
                var s = PomodoroResolveSignals()
                s.isLowEnergy = true; s.availableMinutes = 10; return s
            }(),
            {
                var s = PomodoroResolveSignals()
                s.wantsDeepWork = true; s.peakEnergyHour = 10; s.startHour = 10
                s.taskStoryPoints = 13; s.availableMinutes = 500; return s
            }(),
        ]
        for signals in cases {
            let cfg = PomodoroConfigResolver.resolve(signals: signals)
            XCTAssertGreaterThanOrEqual(cfg.workMinutes, tuning.workBounds.lowerBound)
            XCTAssertLessThanOrEqual(cfg.workMinutes, tuning.workBounds.upperBound)
            XCTAssertGreaterThanOrEqual(cfg.breakMinutes, tuning.breakBounds.lowerBound)
            XCTAssertLessThanOrEqual(cfg.breakMinutes, tuning.breakBounds.upperBound)
            XCTAssertGreaterThanOrEqual(cfg.rounds, tuning.roundBounds.lowerBound)
            XCTAssertLessThanOrEqual(cfg.rounds, tuning.roundBounds.upperBound)
            XCTAssertEqual(cfg.workMinutes % 5, 0)
            XCTAssertEqual(cfg.breakMinutes % 5, 0)
        }
    }

    // MARK: Pure

    func testResolverIsPure() {
        var signals = PomodoroResolveSignals()
        signals.startHour = 10
        signals.peakEnergyHour = 10
        signals.availableMinutes = 120
        let a = PomodoroConfigResolver.resolve(signals: signals)
        let b = PomodoroConfigResolver.resolve(signals: signals)
        XCTAssertEqual(a, b)
    }

    // MARK: Two-phase API

    func testResolveDurationFitsBudget() {
        var signals = PomodoroResolveSignals()
        signals.availableMinutes = 60
        let duration = PomodoroConfigResolver.resolveDuration(signals: signals)
        XCTAssertLessThanOrEqual(duration, 60)
        XCTAssertGreaterThanOrEqual(duration, PomodoroResolverTuning.default.workBounds.lowerBound)
        XCTAssertEqual(duration % 5, 0)
    }

    func testResolveShapeUsesSuppliedHour() {
        var signals = PomodoroResolveSignals()
        signals.peakEnergyHour = 9
        // `signals.startHour` says current hour = far from peak, but the
        // shape call overrides with hour=9 (peak) — should stretch work.
        signals.startHour = 18
        let shape = PomodoroConfigResolver.resolveShape(
            totalMinutes: 130,
            startHour: 9,
            signals: signals
        )
        XCTAssertGreaterThanOrEqual(shape.workMinutes, PomodoroResolverTuning.default.nearPeakWork)
    }

    func testResolveShapeNeverExceedsBudget() {
        var signals = PomodoroResolveSignals()
        signals.wantsDeepWork = true
        signals.peakEnergyHour = 10
        // Large work desired but tiny budget: shape must still fit.
        let shape = PomodoroConfigResolver.resolveShape(
            totalMinutes: 50, startHour: 10, signals: signals
        )
        XCTAssertLessThanOrEqual(shape.totalMinutes, 50)
    }

    // MARK: Tuning override

    func testCustomTuningChangesBounds() {
        var tuning = PomodoroResolverTuning.default
        tuning.workBounds = 10...30
        var signals = PomodoroResolveSignals()
        signals.wantsDeepWork = true
        signals.peakEnergyHour = 10
        signals.startHour = 10
        let cfg = PomodoroConfigResolver.resolve(signals: signals, tuning: tuning)
        XCTAssertLessThanOrEqual(cfg.workMinutes, 30)
        XCTAssertGreaterThanOrEqual(cfg.workMinutes, 10)
    }

    // MARK: Learning blend

    func testLearnedConfigBlendsIntoWork() {
        var signals = PomodoroResolveSignals()
        signals.isLowEnergy = false
        signals.peakEnergyHour = 10
        signals.startHour = 10  // would normally pick 45
        signals.learnedConfig = PomodoroConfig(
            workMinutes: 25, breakMinutes: 5, rounds: 4, longBreakMinutes: 15
        )
        let cfg = PomodoroConfigResolver.resolve(signals: signals)
        // With default blend=0.3: expected ≈ 45*0.7 + 25*0.3 = 39 → snap5 = 40
        XCTAssertEqual(cfg.workMinutes, 40)
    }

    // MARK: Total minutes formula

    func testPomodoroConfigTotalMinutes() {
        let cfg = PomodoroConfig(workMinutes: 25, breakMinutes: 5, rounds: 4, longBreakMinutes: 15)
        // 25*4 + 5*3 + 15 = 100 + 15 + 15 = 130
        XCTAssertEqual(cfg.totalMinutes, 130)

        let single = PomodoroConfig(workMinutes: 25, breakMinutes: 5, rounds: 1, longBreakMinutes: 0)
        XCTAssertEqual(single.totalMinutes, 25)
    }
}
