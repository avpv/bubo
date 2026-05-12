import XCTest
@testable import Bubo
@testable import BuboDomain
@testable import BuboOptimizer

/// End-to-end checks for the pomodoro pipeline: gene ↔ CalendarEvent ↔
/// persisted event carry `PomodoroConfig` without loss, and the
/// `PomodoroHistoryService`-resolver loop produces stable shapes.
@MainActor
final class PomodoroIntegrationTests: XCTestCase {

    private let sampleConfig = PomodoroConfig(
        workMinutes: 30, breakMinutes: 5, rounds: 3, longBreakMinutes: 15
    )

    // MARK: Gene → CalendarEvent

    func testGeneCarriesPomodoroConfigIntoCalendarEvent() {
        let gene = ScheduleGene(
            eventId: "pom-1",
            title: "Pomodoro",
            startTime: Date(),
            duration: TimeInterval(sampleConfig.totalMinutes * 60),
            context: nil,
            energyCost: 0.6,
            priority: 0.8,
            isFocusBlock: true,
            pomodoroConfig: sampleConfig
        )
        let event = gene.toCalendarEvent(eventType: .pomodoro)
        XCTAssertEqual(event.pomodoroConfig, sampleConfig)
    }

    func testWithStartTimePreservesConfig() {
        let gene = ScheduleGene(
            eventId: "pom-1", title: "Pomodoro", startTime: Date(),
            duration: 1800, context: nil, energyCost: 0.5,
            priority: 0.5, isFocusBlock: true,
            pomodoroConfig: sampleConfig
        )
        let shifted = gene.withStartTime(Date().addingTimeInterval(3600))
        XCTAssertEqual(shifted.pomodoroConfig, sampleConfig)
    }

    // MARK: CalendarEvent → JSON roundtrip

    func testCalendarEventJSONRoundtripPreservesConfig() throws {
        var event = CalendarEvent(
            id: "p",
            title: "Pomodoro",
            startDate: Date(),
            endDate: Date().addingTimeInterval(7800),
            location: nil, description: nil, calendarName: nil,
            eventType: .pomodoro
        )
        event.pomodoroConfig = sampleConfig

        let encoded = try JSONEncoder().encode(event)
        let decoded = try JSONDecoder().decode(CalendarEvent.self, from: encoded)
        XCTAssertEqual(decoded.pomodoroConfig, sampleConfig)
    }

    func testLegacyCalendarEventDecodesWithNilConfig() throws {
        let event = CalendarEvent(
            id: "legacy",
            title: "Meeting",
            startDate: Date(),
            endDate: Date().addingTimeInterval(3600),
            location: nil, description: nil, calendarName: nil,
            eventType: .standard
        )
        let encoded = try JSONEncoder().encode(event)
        let decoded = try JSONDecoder().decode(CalendarEvent.self, from: encoded)
        XCTAssertNil(decoded.pomodoroConfig)
    }

    // MARK: Resolver ↔ history loop

    func testHistoryMedianFeedsResolver() {
        let suite = "PomodoroIntegrationTests"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.removePersistentDomain(forName: suite)

        let history = PomodoroHistoryService(defaults: defaults)
        for _ in 0..<3 {
            history.record(PomodoroHistoryEntry(
                startedAt: Date(),
                startHour: 10,
                config: PomodoroConfig(workMinutes: 30, breakMinutes: 5, rounds: 3, longBreakMinutes: 15),
                actualMinutes: 105,
                completed: true
            ))
        }

        var signals = PomodoroResolveSignals()
        signals.startHour = 10
        signals.peakEnergyHour = 10
        signals.learnedConfig = history.learnedConfig(forHour: 10)

        let cfg = PomodoroConfigResolver.resolve(signals: signals)
        // With peak-energy work=45 and learned work=30, default blend 0.3:
        // 45*0.7 + 30*0.3 = 40.5 → snap5 = 40.
        XCTAssertEqual(cfg.workMinutes, 40)
    }

    // MARK: Resolver invariants with real signals

    func testResolveShapeWithPeakHourProducesDeeperWork() {
        var signals = PomodoroResolveSignals()
        signals.peakEnergyHour = 9
        let shapeAtPeak = PomodoroConfigResolver.resolveShape(
            totalMinutes: 120, startHour: 9, signals: signals
        )
        let shapeOffPeak = PomodoroConfigResolver.resolveShape(
            totalMinutes: 120, startHour: 18, signals: signals
        )
        XCTAssertGreaterThan(shapeAtPeak.workMinutes, shapeOffPeak.workMinutes)
    }
}
