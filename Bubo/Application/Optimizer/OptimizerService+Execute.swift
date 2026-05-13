import Foundation
import UserNotifications
import BuboDomain
import BuboOptimizer

// MARK: - Execute Request (Primary Entry Point)
//
// executeRequest is the canonical pipeline; instantReflow / dry-run /
// preview / apply-previewed / week-mock are thin variants on top.
// Extracted from OptimizerService.swift.

extension OptimizerService {

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

        // Inject the user's locked event ids as an implicit
        // `.keepFixed(...)` so every optimizer pass respects the
        // per-event lock affordance set in `EventRowView`. Original
        // `request` is captured for `activeRequest` (used by the
        // reasoning surface) before mutation, so the user-visible
        // intent list stays clean — locks are infrastructure, not a
        // narrative bullet point. Birman: «rules that are visible on
        // the screen should not be echoed in the narration».
        var effectiveRequest = request
        if !lockedEventIds.isEmpty {
            effectiveRequest.add(.keepFixed(eventIds: Array(lockedEventIds)))
        }
        if !excludedEventIds.isEmpty {
            effectiveRequest.add(.exclude(eventIds: Array(excludedEventIds)))
        }

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
        let result = await compiler.execute(effectiveRequest, defaultWorkingHours: workingHours)

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

    /// Run the GA like `executeRequest` but DO NOT publish the result
    /// onto `scenarios` and DO NOT apply anything. Returns every
    /// scenario the GA produced so the caller can present alternatives
    /// (e.g. the per-task ⌥-click «show me other slots» popover).
    /// Distinct from `executeDryRun` which only returns the top genes.
    /// The returned scenarios can later be committed via
    /// `applyPreviewedScenario(_:to:)`.
    func previewScenarios(
        _ request: OptimizationRequest,
        reminderService: ReminderService
    ) async -> [ScheduleScenario] {
        guard let backlogSvc = backlogService else { return [] }
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
            return r.scenarios
        default:
            return []
        }
    }

    /// Commit a scenario that was produced by `previewScenarios` (i.e.
    /// not the one currently sitting on `scenarios`). Routes through
    /// the same `applyScenario(at:to:)` machinery — undo, snapshot
    /// bookkeeping and learner feedback all behave identically.
    func applyPreviewedScenario(
        _ scenario: ScheduleScenario,
        to reminderService: ReminderService,
        titleOverride: String? = nil,
        colorOverride: EventColorTag? = nil
    ) {
        scenarios = [scenario]
        selectedScenarioIndex = 0
        lastOptimizationDate = Date()
        applyScenario(
            at: 0,
            to: reminderService,
            titleOverride: titleOverride,
            colorOverride: colorOverride
        )
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
}
