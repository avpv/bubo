import Foundation

// MARK: - Optimizer Service

/// Bridges BuboOptimizer with ReminderService and the rest of the app.
/// Manages optimizer lifecycle, converts between app models and optimizer models.
@MainActor
@Observable
final class OptimizerService {

    let optimizer = BuboOptimizer()

    private(set) var scenarios: [ScheduleScenario] = []
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

    /// Optimize today's schedule given current events and movable tasks.
    func optimizeDay(
        reminderService: ReminderService,
        movableTasks: [OptimizableEvent]
    ) {
        guard isEnabled else { return }
        isOptimizing = true
        error = nil

        let fixedEvents = reminderService.allEvents.filter { !$0.isLocalEvent }

        let result = optimizer.optimizeToday(
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

    /// Optimize the full week schedule.
    func optimizeWeek(
        reminderService: ReminderService,
        movableTasks: [OptimizableEvent],
        participantAvailability: [String: [DateInterval]] = [:]
    ) {
        guard isEnabled else { return }
        isOptimizing = true
        error = nil

        let fixedEvents = reminderService.allEvents.filter { !$0.isLocalEvent }

        let result = optimizer.optimizeWeek(
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

    /// Find optimal time for focus blocks.
    func suggestFocusBlocks(
        count: Int = 2,
        durationMinutes: Int = 120,
        reminderService: ReminderService
    ) {
        isOptimizing = true
        error = nil

        let fixedEvents = reminderService.allEvents

        let result = optimizer.suggestFocusBlocks(
            count: count,
            durationMinutes: durationMinutes,
            fixedEvents: fixedEvents,
            workingHours: workingHours
        )

        scenarios = result.scenarios
        selectedScenarioIndex = scenarios.isEmpty ? nil : 0
        isOptimizing = false
        lastOptimizationDate = Date()
    }

    // MARK: - Suggest Pomodoro Slot

    /// Find optimal time for a Pomodoro session.
    func suggestPomodoroSlot(
        config: PomodoroConfig = .classic,
        reminderService: ReminderService
    ) {
        isOptimizing = true
        error = nil

        let result = optimizer.suggestPomodoroSlot(
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

    /// User accepted a scenario — apply it and record feedback.
    func applyScenario(at index: Int, to reminderService: ReminderService) {
        guard index < scenarios.count else { return }
        let scenario = scenarios[index]

        optimizer.acceptScenario(scenario)

        // Convert genes to local events and add them
        for gene in scenario.genes {
            let event = CalendarEvent(
                id: gene.eventId,
                title: gene.eventId, // Will be overridden by the actual title
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

    /// User rejected a scenario — record feedback.
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

    /// Reset optimizer state.
    func reset() {
        optimizer.reset()
        scenarios = []
        selectedScenarioIndex = nil
        error = nil
    }
}
