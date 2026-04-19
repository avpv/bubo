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
        XCTAssertEqual(cfg.workMinutes, 15)
    }

    func testNearPeakEnergyStretchesWork() {
        var signals = PomodoroResolveSignals()
        signals.currentHour = 10
        signals.peakEnergyHour = 10
        let cfg = PomodoroConfigResolver.resolve(signals: signals)
        XCTAssertGreaterThanOrEqual(cfg.workMinutes, 45)
    }

    func testFarFromPeakShrinksWork() {
        var signals = PomodoroResolveSignals()
        signals.currentHour = 18
        signals.peakEnergyHour = 9
        let cfg = PomodoroConfigResolver.resolve(signals: signals)
        XCTAssertLessThanOrEqual(cfg.workMinutes, 25)
    }

    func testDeepWorkHintLengthensWork() {
        var signals = PomodoroResolveSignals()
        signals.wantsDeepWork = true
        let cfg = PomodoroConfigResolver.resolve(signals: signals)
        XCTAssertGreaterThanOrEqual(cfg.workMinutes, 45)
    }

    func testHighStoryPointsLengthensWork() {
        var signals = PomodoroResolveSignals()
        signals.taskStoryPoints = 13
        let cfg = PomodoroConfigResolver.resolve(signals: signals)
        XCTAssertGreaterThanOrEqual(cfg.workMinutes, 45)
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
        let cases: [PomodoroResolveSignals] = [
            PomodoroResolveSignals(),
            {
                var s = PomodoroResolveSignals()
                s.isLowEnergy = true; s.availableMinutes = 10; return s
            }(),
            {
                var s = PomodoroResolveSignals()
                s.wantsDeepWork = true; s.peakEnergyHour = 10; s.currentHour = 10
                s.taskStoryPoints = 13; s.availableMinutes = 500; return s
            }(),
        ]
        for signals in cases {
            let cfg = PomodoroConfigResolver.resolve(signals: signals)
            XCTAssertGreaterThanOrEqual(cfg.workMinutes, PomodoroConfigResolver.minWorkMinutes)
            XCTAssertLessThanOrEqual(cfg.workMinutes, PomodoroConfigResolver.maxWorkMinutes)
            XCTAssertGreaterThanOrEqual(cfg.breakMinutes, PomodoroConfigResolver.minBreakMinutes)
            XCTAssertLessThanOrEqual(cfg.breakMinutes, PomodoroConfigResolver.maxBreakMinutes)
            XCTAssertGreaterThanOrEqual(cfg.rounds, PomodoroConfigResolver.minRounds)
            XCTAssertLessThanOrEqual(cfg.rounds, PomodoroConfigResolver.maxRounds)
            XCTAssertEqual(cfg.workMinutes % 5, 0)
            XCTAssertEqual(cfg.breakMinutes % 5, 0)
        }
    }

    // MARK: Pure

    func testResolverIsPure() {
        var signals = PomodoroResolveSignals()
        signals.currentHour = 10
        signals.peakEnergyHour = 10
        signals.availableMinutes = 120
        let a = PomodoroConfigResolver.resolve(signals: signals)
        let b = PomodoroConfigResolver.resolve(signals: signals)
        XCTAssertEqual(a, b)
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
