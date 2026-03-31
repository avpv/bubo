import Foundation

// MARK: - Optimizer Service

/// Bridges BuboOptimizer with ReminderService and the rest of the app.
/// All optimization calls are async to avoid blocking the main thread.
@MainActor
@Observable
final class OptimizerService {

    let optimizer = BuboOptimizer()

    var scenarios: [ScheduleScenario] = []
    private(set) var selectedScenarioIndex: Int? = nil
    private(set) var isOptimizing: Bool = false
    private(set) var lastOptimizationDate: Date? = nil
    private(set) var error: String? = nil

    // MARK: - Optimizer Settings (persisted)

    var workingHoursStart: Int {
        didSet { saveSettings() }
    }
    var workingHoursEnd: Int {
        didSet { saveSettings() }
    }
    var isEnabled: Bool {
        didSet { saveSettings() }
    }

    private let persistenceKey = "BuboOptimizerServiceSettings"

    init() {
        let saved = Self.loadSettings()
        self.workingHoursStart = saved.start
        self.workingHoursEnd = saved.end
        self.isEnabled = saved.enabled
    }

    var workingHours: ClosedRange<Int> {
        workingHoursStart...workingHoursEnd
    }

    // MARK: - Optimize Day

    func optimizeDay(
        reminderService: ReminderService,
        movableTasks: [OptimizableEvent]
    ) async {
        guard isEnabled else { return }
        isOptimizing = true
        error = nil

        let fixedEvents = reminderService.allEvents.filter { !$0.isLocalEvent }

        let result = await optimizer.optimizeToday(
            fixedEvents: fixedEvents,
            movableEvents: movableTasks,
            workingHours: workingHours
        )

        scenarios = result.scenarios
        selectedScenarioIndex = scenarios.isEmpty ? nil : 0
        isOptimizing = false
        lastOptimizationDate = Date()
    }

    // MARK: - Optimize Week

    func optimizeWeek(
        reminderService: ReminderService,
        movableTasks: [OptimizableEvent],
        participantAvailability: [String: [DateInterval]] = [:]
    ) async {
        guard isEnabled else { return }
        isOptimizing = true
        error = nil

        let fixedEvents = reminderService.allEvents.filter { !$0.isLocalEvent }

        let result = await optimizer.optimizeWeek(
            fixedEvents: fixedEvents,
            movableEvents: movableTasks,
            workingHours: workingHours,
            participantAvailability: participantAvailability
        )

        scenarios = result.scenarios
        selectedScenarioIndex = scenarios.isEmpty ? nil : 0
        isOptimizing = false
        lastOptimizationDate = Date()
    }

    // MARK: - Suggest Focus Blocks

    func suggestFocusBlocks(
        count: Int = 2,
        durationMinutes: Int = 120,
        reminderService: ReminderService
    ) async {
        isOptimizing = true
        error = nil

        let result = await optimizer.suggestFocusBlocks(
            count: count,
            durationMinutes: durationMinutes,
            fixedEvents: reminderService.allEvents,
            workingHours: workingHours
        )

        scenarios = result.scenarios
        selectedScenarioIndex = scenarios.isEmpty ? nil : 0
        isOptimizing = false
        lastOptimizationDate = Date()
    }

    // MARK: - Suggest Pomodoro Slot

    func suggestPomodoroSlot(
        config: PomodoroConfig = .classic,
        reminderService: ReminderService
    ) async {
        isOptimizing = true
        error = nil

        let result = await optimizer.suggestPomodoroSlot(
            config: config,
            fixedEvents: reminderService.allEvents,
            workingHours: workingHours
        )

        scenarios = result.scenarios
        selectedScenarioIndex = scenarios.isEmpty ? nil : 0
        isOptimizing = false
        lastOptimizationDate = Date()
    }

    // MARK: - Apply Scenario

    func applyScenario(at index: Int, to reminderService: ReminderService) {
        guard index < scenarios.count else { return }
        let scenario = scenarios[index]

        optimizer.acceptScenario(scenario)

        for gene in scenario.genes {
            let event = CalendarEvent(
                id: gene.eventId,
                title: gene.eventId,
                startDate: gene.startTime,
                endDate: gene.endTime,
                location: nil,
                description: "Created by Bubo Optimizer",
                calendarName: nil,
                eventType: gene.isFocusBlock ? .pomodoro : .standard,
                colorTag: gene.isFocusBlock ? .blue : .green
            )
            reminderService.addLocalEvent(event)
        }

        selectedScenarioIndex = index
    }

    func rejectScenario(at index: Int) {
        guard index < scenarios.count else { return }
        optimizer.rejectScenario(scenarios[index])
    }

    // MARK: - Scenario Info

    var selectedScenario: ScheduleScenario? {
        guard let idx = selectedScenarioIndex, idx < scenarios.count else { return nil }
        return scenarios[idx]
    }

    var comparisons: [ScenarioComparison] {
        optimizer.compareLastScenarios()
    }

    // MARK: - Persistence

    private struct SavedSettings: Codable {
        let start: Int
        let end: Int
        let enabled: Bool
    }

    private func saveSettings() {
        let saved = SavedSettings(start: workingHoursStart, end: workingHoursEnd, enabled: isEnabled)
        if let data = try? JSONEncoder().encode(saved) {
            UserDefaults.standard.set(data, forKey: persistenceKey)
        }
    }

    private static func loadSettings() -> (start: Int, end: Int, enabled: Bool) {
        guard let data = UserDefaults.standard.data(forKey: "BuboOptimizerServiceSettings"),
              let saved = try? JSONDecoder().decode(SavedSettings.self, from: data) else {
            return (start: 9, end: 18, enabled: true)
        }
        return (start: saved.start, end: saved.end, enabled: saved.enabled)
    }

    func reset() {
        optimizer.reset()
        scenarios = []
        selectedScenarioIndex = nil
        error = nil
    }
}
