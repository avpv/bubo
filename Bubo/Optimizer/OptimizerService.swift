import Foundation
import OSLog
import UserNotifications

// MARK: - Optimizer Service

/// Bridges BuboOptimizer with the rest of the app.
/// All optimization flows go through intent-based OptimizationRequest.
@MainActor
@Observable
final class OptimizerService {

    let optimizer = BuboOptimizer()
    let intentLearner = IntentLearner()

    var scenarios: [ScheduleScenario] = []
    private(set) var selectedScenarioIndex: Int? = nil
    private(set) var isOptimizing: Bool = false
    private(set) var lastOptimizationDate: Date? = nil
    private(set) var error: String? = nil

    /// The last applied snapshot for undo support.
    private(set) var lastSnapshot: AppliedSnapshot? = nil

    /// IDs of events created in the most recent application.
    /// Used by EventRowView to highlight freshly created events.
    private(set) var freshlyCreatedEventIds: Set<String> = []

    /// The active optimization request (for display and learning).
    var activeRequestName: String? = nil
    /// The full active request (for IntentLearner recording).
    private var activeRequest: OptimizationRequest? = nil

    /// Backlog service for persistent task management.
    var backlogService: BacklogService?

    /// Subgraph registry for saved pipelines.
    private(set) var subgraphRegistry: SubgraphRegistry?

    /// Suggestion engine for contextual suggestions.
    private(set) var suggestionEngine: SuggestionEngine?

    /// Trigger engine for scheduled/reactive pipeline execution.
    private(set) var triggerEngine: TriggerEngine?

    /// Energy check-in service for adaptive energy curve.
    var energyCheckInService: EnergyCheckInService?

    /// Pomodoro outcome log — records completed/abandoned sessions so
    /// `PomodoroConfigResolver` can blend past choices into new shapes.
    /// Created on first use; shared with `IntentCompiler` and
    /// `TimerScreenView`.
    let pomodoroHistory = PomodoroHistoryService()

    // MARK: - Optimizer Settings (persisted)

    var workingHoursStart: Int {
        didSet {
            if workingHoursStart >= workingHoursEnd {
                workingHoursEnd = workingHoursStart + 1
            }
            saveSettings()
        }
    }
    var workingHoursEnd: Int {
        didSet {
            if workingHoursEnd <= workingHoursStart {
                workingHoursStart = workingHoursEnd - 1
            }
            saveSettings()
        }
    }

    /// Toggle for `OptimizerPreferences.skipWeekends`. Lives on the service
    /// (not just the popover) so every surface that tweaks working hours can
    /// bind to the same source of truth, and so the setter can route the
    /// change through `savePreferences()` — otherwise a UI flip would be lost
    /// on relaunch because `optimizer.preferences` is only persisted through
    /// that call. Reads fall back to `false` (matches `effectiveSkipWeekends`).
    var skipWeekends: Bool {
        get { optimizer.preferences.skipWeekends ?? false }
        set {
            optimizer.preferences.skipWeekends = newValue
            savePreferences()
        }
    }

    /// Default duration (in minutes) applied to new backlog tasks when the
    /// user doesn't specify one (no `1h`/`30m` suffix in the title). The
    /// ghost preview and the actual create path share this value via
    /// `BacklogView`. Clamped on assignment to the same 5 min – 12 h window
    /// as `BacklogTitleParser` so the two stay consistent.
    var defaultTaskDurationMinutes: Int {
        didSet {
            let clamped = max(5, min(12 * 60, defaultTaskDurationMinutes))
            if clamped != defaultTaskDurationMinutes {
                defaultTaskDurationMinutes = clamped
                return
            }
            saveSettings()
        }
    }

    var minSlotMinutes: Int {
        FreeSlotFinder.defaultMinSlotMinutes
    }

    private let persistenceKey = "BuboOptimizerServiceSettings"
    private let preferencesKey = "BuboOptimizerPreferences"

    /// Prevents didSet -> save -> push loop when reloading cloud data.
    private var isReloadingFromCloud = false
    private var cloudSyncObserver: Any?

    init() {
        let saved = Self.loadSettings()
        self.workingHoursStart = saved.start
        self.workingHoursEnd = saved.end
        self.defaultTaskDurationMinutes = saved.defaultDuration
        if let data = UserDefaults.standard.data(forKey: "BuboOptimizerPreferences"),
           let prefs = try? JSONDecoder().decode(OptimizerPreferences.self, from: data) {
            self.optimizer.preferences = prefs
        }
        // Normalise `skipWeekends` at load. Preference field is `Bool?`
        // so older persisted JSON (pre-field) decodes to nil; flip that
        // to `true` once on first load so the UI toggle shows the same
        // value the GA will actually use, and so downstream code can
        // trust the flag without juggling nil. Persisted `false` from
        // an explicit UI flip stays `false` — we only touch nil.
        if optimizer.preferences.skipWeekends == nil {
            optimizer.preferences.skipWeekends = true
            savePreferences()
        }
        setupCloudSync()
    }

    private func setupCloudSync() {
        cloudSyncObserver = NotificationCenter.default.addObserver(
            forName: CloudSyncService.didReceiveRemoteChange,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let key = notification.object as? String else { return }
            Task { @MainActor [weak self] in
                self?.handleCloudSync(key: key)
            }
        }
    }

    private func handleCloudSync(key: String) {
        isReloadingFromCloud = true
        defer { isReloadingFromCloud = false }

        switch key {
        case persistenceKey:
            let saved = Self.loadSettings()
            workingHoursStart = saved.start
            workingHoursEnd = saved.end
            defaultTaskDurationMinutes = saved.defaultDuration
        case preferencesKey:
            if let data = UserDefaults.standard.data(forKey: preferencesKey),
               let prefs = try? JSONDecoder().decode(OptimizerPreferences.self, from: data) {
                optimizer.preferences = prefs
            }
        default:
            break
        }
    }

    var workingHours: ClosedRange<Int> {
        workingHoursStart...workingHoursEnd
    }

    // MARK: - Execute Request (Primary Entry Point)

    /// Execute an OptimizationRequest (array of composable intents).
    func executeRequest(
        _ request: OptimizationRequest,
        reminderService: ReminderService
    ) async -> OptimizationResult {
        guard let backlogSvc = backlogService else {
            return .infeasible(reason: "Backlog service not initialized")
        }

        isOptimizing = true
        defer { isOptimizing = false }
        error = nil
        activeRequestName = request.name
        activeRequest = request

        var compiler = IntentCompiler(
            optimizer: optimizer,
            reminderService: reminderService,
            backlogService: backlogSvc
        )
        compiler.subgraphRegistry = subgraphRegistry
        compiler.energyCheckInService = energyCheckInService
        compiler.pomodoroHistory = pomodoroHistory
        let result = await compiler.execute(request, defaultWorkingHours: workingHours)

        switch result {
        case .success(let optimizerResult):
            scenarios = optimizerResult.scenarios
            selectedScenarioIndex = scenarios.isEmpty ? nil : 0
            lastOptimizationDate = Date()

        case .partialSuccess(let optimizerResult, let warnings, _):
            scenarios = optimizerResult.scenarios
            selectedScenarioIndex = scenarios.isEmpty ? nil : 0
            lastOptimizationDate = Date()
            error = warnings.first

        case .noEventsToOptimize:
            error = "No events to optimize"

        case .infeasible(let reason, _, _):
            error = reason
        }

        return result
    }

    /// Instant reflow for drag-to-schedule and live preview.
    /// Ultra-fast GA (~100ms) with warm start from current schedule.
    func instantReflow(
        reminderService: ReminderService,
        movableEvents: [OptimizableEvent] = []
    ) async -> [ScheduleGene]? {
        let fixedEvents = reminderService.allEvents.filter { !$0.isLocalEvent }
        let localMovable = reminderService.localEvents
            .filter { $0.isUpcoming && $0.isMovable }
            .map { $0.toOptimizableEvent() }

        let allMovable = localMovable + movableEvents
        guard !allMovable.isEmpty else { return nil }

        let cal = Calendar.current
        let now = Date()
        let todayEnd = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: now))!

        let context = OptimizerContext(
            fixedEvents: fixedEvents,
            movableEvents: allMovable,
            workingHours: workingHours,
            planningHorizon: DateInterval(start: now, end: todayEnd),
            preferences: optimizer.preferences
        )

        return await optimizer.instantReflow(context: context)
    }

    /// Dry-run for preview — returns genes without storing results.
    func executeDryRun(
        _ request: OptimizationRequest,
        reminderService: ReminderService
    ) async -> [ScheduleGene]? {
        guard let backlogSvc = backlogService else { return nil }
        var compiler = IntentCompiler(
            optimizer: optimizer,
            reminderService: reminderService,
            backlogService: backlogSvc
        )
        compiler.subgraphRegistry = subgraphRegistry
        compiler.energyCheckInService = energyCheckInService
        compiler.pomodoroHistory = pomodoroHistory
        let result = await compiler.execute(request, defaultWorkingHours: workingHours)
        switch result {
        case .success(let r), .partialSuccess(let r, _, _):
            return r.scenarios.first?.genes
        default:
            return nil
        }
    }

    /// Week-Ahead Mock Simulator: proactively checks if all tasks fit in the week
    func runWeekMockSimulator(reminderService: ReminderService) async {
        guard let backlogSvc = backlogService else { return }
        var compiler = IntentCompiler(
            optimizer: optimizer,
            reminderService: reminderService,
            backlogService: backlogSvc
        )
        compiler.subgraphRegistry = subgraphRegistry
        compiler.energyCheckInService = energyCheckInService
        compiler.pomodoroHistory = pomodoroHistory
        
        let req = OptimizationRequest(.horizon(.week), .includeBacklog)
        let result = await compiler.execute(req, defaultWorkingHours: workingHours)
        
        if case .partialSuccess(_, let warnings, _) = result {
            let endangered = warnings.filter { $0.lowercased().contains("task") || $0.lowercased().contains("planned") }
            if !endangered.isEmpty {
                let count = endangered.count
                let content = UNMutableNotificationContent()
                content.title = "Deadlines at risk!"
                content.body = "Simulator: tasks don't fit this week. Unload the schedule?"
                content.sound = .default
                let request = UNNotificationRequest(identifier: "MockSimulator", content: content, trigger: nil)
                try? await UNUserNotificationCenter.current().add(request)
                _ = count
            }
        }
    }

    // MARK: - Apply Scenario

    func applyScenario(
        at index: Int,
        to reminderService: ReminderService,
        titleOverride: String? = nil,
        colorOverride: EventColorTag? = nil
    ) {
        guard index < scenarios.count else { return }
        let scenario = scenarios[index]
        var createdEventIds: [String] = []
        let previousGenes = optimizer.currentSchedule

        optimizer.acceptScenario(scenario)

        // Remove old calendar events for tasks being rescheduled. Two
        // sources feed the removal set: direct id matches (the typical
        // case where the new gene reuses the old event id) and every
        // previously-scheduled chunk of each task being re-optimized.
        // The second source matters when a task changes shape between
        // runs — e.g., was a single event, is now split into `_p0`+`_p1`,
        // or vice versa — so we don't orphan the prior chunks.
        var idsToRemove = Set(scenario.activeGenes.map { $0.eventId })
        if let backlogService {
            let taskIds = Set(
                scenario.activeGenes.flatMap { gene -> [String] in
                    gene.reservedTaskIds.isEmpty
                        ? [gene.groupId ?? gene.eventId]
                        : gene.reservedTaskIds
                }
            )
            for taskId in taskIds {
                guard let task = backlogService.tasks.first(where: { $0.id == taskId }) else { continue }
                idsToRemove.formUnion(task.scheduledEventIds)
                if let primary = task.scheduledEventId { idsToRemove.insert(primary) }
            }
        }
        for id in idsToRemove {
            if reminderService.localEvents.contains(where: { $0.id == id }) {
                reminderService.removeLocalEvent(id: id)
            }
        }

        let cal = Calendar.current
        for (i, gene) in scenario.activeGenes.enumerated() {
            let title: String
            if let override = titleOverride, !override.isEmpty {
                title = scenario.activeGenes.count > 1 ? "\(override) \(i + 1)" : override
            } else {
                title = gene.title
            }

            // Post-GA shape refinement: the gene already has a config (picked
            // pre-GA with `currentHour`), but the slot it actually landed in
            // may sit hours from that assumption. Re-resolve the inner shape
            // with the real start hour, keeping the gene's duration as the
            // hard budget. Changes only work/break/rounds/longBreak —
            // `gene.endTime` stays intact.
            var pomodoroConfig = gene.pomodoroConfig
            if let originalConfig = gene.pomodoroConfig {
                let budget = max(
                    PomodoroResolverTuning.default.workBounds.lowerBound,
                    Int(gene.duration / 60)
                )
                var signals = PomodoroResolveSignals()
                signals.startHour = cal.component(.hour, from: gene.startTime)
                signals.learnedConfig = pomodoroHistory.learnedConfig(forHour: signals.startHour)
                    ?? originalConfig
                pomodoroConfig = PomodoroConfigResolver.resolveShape(
                    totalMinutes: budget,
                    startHour: signals.startHour,
                    signals: signals
                )
            }

            // Snapshot the backlog tasks bound to this gene so the timer
            // can show `taskSequence[round].title` and the backlog
            // service can link every consumed task to the same event.
            let sequence: [CalendarEvent.TaskSequenceEntry] = gene.reservedTaskIds.compactMap { id in
                guard let task = backlogService?.tasks.first(where: { $0.id == id }) else {
                    return nil
                }
                return CalendarEvent.TaskSequenceEntry(taskId: id, title: task.title)
            }

            var event = CalendarEvent(
                id: gene.eventId,
                title: title,
                startDate: gene.startTime,
                endDate: gene.endTime,
                location: nil,
                description: "Created by Schedule Assistant",
                calendarName: nil,
                eventType: gene.isFocusBlock ? .pomodoro : .standard,
                colorTag: colorOverride ?? (gene.isFocusBlock ? .blue : .green)
            )
            event.pomodoroConfig = pomodoroConfig
            event.pomodoroTaskSequence = sequence
            reminderService.addLocalEvent(event)
            createdEventIds.append(event.id)
        }

        // Link backlog tasks to their scheduled events. Two shapes flow
        // through the same call:
        //   • Focus bursts: one gene carries N backlog tasks via
        //     `reservedTaskIds`. Each task points at the same pomodoro
        //     event.
        //   • Auto-chunked long tasks: N genes share a `groupId` equal
        //     to the parent backlog task id. The parent task links to
        //     every chunk's event id so unschedule/rescheduling can find
        //     them all. Plain backlog events fall through this same path
        //     as degenerate one-chunk groups.
        let focusGenes = scenario.activeGenes.filter { !$0.reservedTaskIds.isEmpty }
        let regularGenes = scenario.activeGenes.filter { $0.reservedTaskIds.isEmpty }

        for gene in focusGenes {
            for taskId in gene.reservedTaskIds {
                backlogService?.markScheduled(
                    id: taskId,
                    eventIds: [gene.eventId],
                    date: gene.startTime
                )
            }
        }

        let groupedByTask = Dictionary(grouping: regularGenes, by: { $0.groupId ?? $0.eventId })
        for (taskId, genes) in groupedByTask {
            let ordered = genes.sorted { $0.startTime < $1.startTime }
            let eventIds = ordered.map { $0.eventId }
            let earliest = ordered.first?.startTime ?? Date()
            backlogService?.markScheduled(
                id: taskId,
                eventIds: eventIds,
                date: earliest
            )
        }

        // Save undo snapshot
        lastSnapshot = AppliedSnapshot(
            requestName: activeRequestName ?? "",
            appliedAt: Date(),
            previousGenes: previousGenes,
            appliedGenes: scenario.activeGenes,
            createdEventIds: createdEventIds
        )

        freshlyCreatedEventIds = Set(createdEventIds)
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            freshlyCreatedEventIds = []
        }

        selectedScenarioIndex = index

        // Record acceptance for intent learning
        if let request = activeRequest {
            intentLearner.recordExecution(request, outcome: .accepted)
        }
    }

    func rejectScenario(at index: Int) {
        guard index < scenarios.count else { return }
        optimizer.rejectScenario(scenarios[index])

        // Record rejection for intent learning
        if let request = activeRequest {
            intentLearner.recordExecution(request, outcome: .rejected)
        }
    }

    // MARK: - Undo

    func undoLast(reminderService: ReminderService) {
        guard let snapshot = lastSnapshot else { return }
        for eventId in snapshot.createdEventIds {
            reminderService.removeLocalEvent(id: eventId)
        }
        // Unschedule backlog tasks that were linked
        for gene in snapshot.appliedGenes {
            backlogService?.unschedule(id: gene.eventId)
        }
        optimizer.currentSchedule = snapshot.previousGenes
        lastSnapshot = nil
        scenarios = []
        selectedScenarioIndex = nil
    }

    // MARK: - Scenario Info

    var selectedScenario: ScheduleScenario? {
        guard let idx = selectedScenarioIndex, idx < scenarios.count else { return nil }
        return scenarios[idx]
    }

    var comparisons: [ScenarioComparison] {
        optimizer.compareLastScenarios()
    }

    // MARK: - Setup

    func setup(reminderService: ReminderService, backlogService: BacklogService) {
        self.backlogService = backlogService
        self.subgraphRegistry = SubgraphRegistry()
        suggestionEngine = SuggestionEngine(
            reminderService: reminderService,
            backlogService: backlogService
        )
        suggestionEngine?.energyCheckInService = energyCheckInService

        // Scan saved pipelines for .energyCheckIn intents to configure prompt hours.
        if let registry = subgraphRegistry, let service = energyCheckInService {
            var hours: Set<Int> = []
            for sg in registry.subgraphs.values {
                for intent in sg.intents {
                    if case .energyCheckIn(let h) = intent {
                        hours.insert(h)
                    }
                }
            }
            if !hours.isEmpty {
                service.setPromptHours(Array(hours))
            }
        }

        triggerEngine = TriggerEngine(
            optimizerService: self,
            reminderService: reminderService
        )
        triggerEngine?.startAll()
        backlogService.carryOverUnfinished()
    }

    func reset() {
        optimizer.reset()
        scenarios = []
        selectedScenarioIndex = nil
        error = nil
        activeRequestName = nil
        lastSnapshot = nil
    }

    // MARK: - Persistence

    private struct SavedSettings: Codable {
        let start: Int
        let end: Int
        let defaultDurationMinutes: Int
    }

    private func saveSettings() {
        guard !isReloadingFromCloud else { return }
        let saved = SavedSettings(
            start: workingHoursStart,
            end: workingHoursEnd,
            defaultDurationMinutes: defaultTaskDurationMinutes
        )
        if let data = try? JSONEncoder().encode(saved) {
            UserDefaults.standard.set(data, forKey: persistenceKey)
            CloudSyncService.shared.push(persistenceKey)
        }
    }

    func savePreferences() {
        if let data = try? JSONEncoder().encode(optimizer.preferences) {
            UserDefaults.standard.set(data, forKey: preferencesKey)
            CloudSyncService.shared.push(preferencesKey)
        }
    }

    private static func loadSettings() -> (start: Int, end: Int, defaultDuration: Int) {
        guard let data = UserDefaults.standard.data(forKey: "BuboOptimizerServiceSettings"),
              let saved = try? JSONDecoder().decode(SavedSettings.self, from: data) else {
            return (start: 9, end: 18, defaultDuration: 60)
        }
        return (
            start: saved.start,
            end: saved.end,
            defaultDuration: saved.defaultDurationMinutes
        )
    }
}
