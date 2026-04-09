import Foundation

// MARK: - Suggestion Engine

/// Evaluates the current schedule context and suggests relevant
/// optimization requests. Replaces RecipeMonitor + RecipeSurface + RecipeCondition.
///
/// Instead of matching conditions to preset recipes, this engine
/// composes intents dynamically based on what it observes.
@MainActor
@Observable
final class SuggestionEngine {

    let reminderService: ReminderService
    let backlogService: BacklogService

    /// Currently suggested optimization request (shown in SmartBanner).
    private(set) var suggestion: Suggestion?

    private var suggestionTimer: Timer?

    init(reminderService: ReminderService, backlogService: BacklogService) {
        self.reminderService = reminderService
        self.backlogService = backlogService
        startSuggestionTimer()
    }

    struct Suggestion: Sendable {
        let request: OptimizationRequest
        let reason: String
    }

    // MARK: - Evaluate

    func evaluate() {
        let now = Date()
        let cal = Calendar.current
        let hour = cal.component(.hour, from: now)
        let events = reminderService.allEvents
        let pendingTasks = backlogService.pending

        // Priority 1: Overdue backlog tasks
        let overdue = backlogService.overdue
        if !overdue.isEmpty {
            suggestion = Suggestion(
                request: OptimizationRequest(
                    .includeBacklog, .findSlotsForBacklog,
                    .horizon(.today), .speed(.quick), .scenarios(count: 1),
                    name: "Schedule \(overdue.count) overdue task\(overdue.count == 1 ? "" : "s")"
                ),
                reason: "\(overdue.count) overdue task\(overdue.count == 1 ? "" : "s") need scheduling"
            )
            return
        }

        // Priority 2: Urgent deadlines (within 2 days)
        let urgent = backlogService.urgent(withinDays: 2)
        if !urgent.isEmpty {
            suggestion = Suggestion(
                request: .deadlineMode,
                reason: "\(urgent.count) task\(urgent.count == 1 ? "" : "s") due within 2 days"
            )
            return
        }

        // Priority 3: Unscheduled backlog tasks
        if pendingTasks.count >= 3 {
            suggestion = Suggestion(
                request: .scheduleBacklog,
                reason: "\(pendingTasks.count) tasks waiting to be scheduled"
            )
            return
        }

        // Priority 4: Meeting-heavy day
        let todayEnd = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: now))!
        let todayMeetings = events.filter { event in
            event.startDate >= now && event.startDate < todayEnd
            && !event.isLocalEvent  // external = meetings
        }
        if todayMeetings.count >= 5 {
            suggestion = Suggestion(
                request: .batchMeetingsPreset,
                reason: "\(todayMeetings.count) meetings today — batch them?"
            )
            return
        }

        // Priority 5: No focus time today
        let todayFocus = events.filter { event in
            event.startDate >= now && event.startDate < todayEnd
            && event.isLocalEvent
            && event.eventType == .pomodoro
        }
        if todayFocus.isEmpty && hour < 14 {
            suggestion = Suggestion(
                request: .findFocus(),
                reason: "No focus time scheduled today"
            )
            return
        }

        // Priority 6: Morning suggestion — organize the day
        if hour < 10 {
            let localToday = events.filter { $0.startDate >= now && $0.startDate < todayEnd && $0.isLocalEvent }
            if localToday.count >= 3 || !pendingTasks.isEmpty {
                suggestion = Suggestion(
                    request: .organizeDay,
                    reason: "Start the day — organize your schedule"
                )
                return
            }
        }

        // No suggestion needed
        suggestion = nil
    }

    // MARK: - Auto-trigger on schedule changes

    func onEventDeleted() async -> OptimizationRequest? {
        IntentPresets.onEventDeleted
    }

    func onEventMoved() async -> OptimizationRequest? {
        IntentPresets.onEventMoved
    }

    // MARK: - Timer

    private func startSuggestionTimer() {
        evaluate()
        suggestionTimer = Timer.scheduledTimer(withTimeInterval: 15 * 60, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.evaluate()
            }
        }
    }

    deinit {
        suggestionTimer?.invalidate()
    }
}
