import Foundation
import BuboDomain

// MARK: - Suggestion Engine

/// Composes smart optimization requests from schedule context.
/// The user never sees 65 intents — this engine picks the right ones
/// and composes a request that just works.
///
/// Birman: «let the machine sweat» — the system does the thinking.
///
/// # Composition model
///
/// Two kinds of contributors, composed additively:
///
/// - ``Signal`` — a user-facing observation (overdue tasks, meeting-heavy
///   day…). Carries intents, a reason fragment, and a priority that
///   resolves ``IntentCardinalityKey`` conflicts.
/// - ``ContextLayer`` — a silent, always-on layer that fires on pure time
///   context (protect lunch, wind down, meeting prep). No reason, never
///   surfaces alone; loses every cardinality conflict to any signal.
///
/// The composer merges signals (highest priority first), then layers,
/// deduplicates exact intent matches, and records an attribution map
/// so the debug UI can show which contributor added which intent.
@MainActor
@Observable
final class SuggestionEngine {

    let reminderService: ReminderService
    let backlogService: BacklogService

    /// Energy check-in service — prompts the user 2-3× daily.
    var energyCheckInService: EnergyCheckInService?

    /// The single best suggestion right now (for SmartBanner).
    var suggestion: Suggestion?

    nonisolated(unsafe) private var suggestionTimer: Timer?
    /// Notification observers wired in `init` and torn down in `deinit`.
    /// Stored as an opaque list because `addObserver(forName:…)` returns
    /// `NSObjectProtocol` whose lifetime is the array's lifetime.
    nonisolated(unsafe) private var backlogObservers: [NSObjectProtocol] = []

    init(reminderService: ReminderService, backlogService: BacklogService) {
        self.reminderService = reminderService
        self.backlogService = backlogService
        startSuggestionTimer()
        wireBacklogInvalidation()
    }

    /// Subscribe to every backlog mutation that can invalidate the cached
    /// suggestion. Without this, `suggestion` could keep referencing a task
    /// the user just deleted (or completed, or scheduled) until the 15-min
    /// timer ticked — so the Smart Action would offer to "Run" something
    /// that no longer exists.
    private func wireBacklogInvalidation() {
        let names: [Notification.Name] = [
            BacklogService.taskAdded,
            BacklogService.taskRemoved,
            BacklogService.taskUpdated,
            BacklogService.taskCompleted,
            BacklogService.taskScheduleChanged,
        ]
        for name in names {
            let token = NotificationCenter.default.addObserver(
                forName: name,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.evaluate()
                }
            }
            backlogObservers.append(token)
        }
    }

    // MARK: - Suggestion

    struct Suggestion: Sendable {
        let request: OptimizationRequest
        let reason: String

        /// Which contributor added which intent. Empty arrays are omitted.
        /// Used by the debug inspector and by tests — it answers
        /// "why is `.focusBlock(120)` in this request?".
        let contributions: [String: [ScheduleIntent]]
    }

    // MARK: - Contributors

    /// A user-facing observation that warrants showing the banner.
    /// Signal priorities order both the cardinality resolution (higher wins)
    /// and the reason fragment ranking (top two surface in the banner).
    struct Signal: Sendable, Equatable {
        let name: String
        let priority: Int
        let intents: [ScheduleIntent]
        let reasonFragment: String
    }

    /// A silent, always-on contribution triggered by pure time context.
    /// Never stands alone — the composer returns `nil` if no ``Signal``
    /// fired, even when several layers match.
    struct ContextLayer: Sendable, Equatable {
        let name: String
        let intents: [ScheduleIntent]
    }

    // MARK: - Evaluate

    func evaluate() {
        let now = Date()
        let cal = Calendar.current
        let hour = cal.component(.hour, from: now)
        let events = reminderService.allEvents
        let startOfDay = cal.startOfDay(for: now)
        // Fallback to 24h after start-of-day if Calendar arithmetic fails
        // (DST/calendar edge cases) — avoids a startup crash from `!`.
        let todayEnd = cal.date(byAdding: .day, value: 1, to: startOfDay)
            ?? startOfDay.addingTimeInterval(86400)
        let todayEvents = events.filter { $0.startDate >= now && $0.startDate < todayEnd }
        let meetings = todayEvents.filter { !$0.isLocalEvent }
        let hasFocusToday = todayEvents.contains(where: { $0.eventType == .pomodoro })

        let signals = Self.signals(
            hour: hour,
            meetingsCount: meetings.count,
            todayEventsCount: todayEvents.count,
            hasFocusToday: hasFocusToday,
            pending: backlogService.pending,
            urgent: backlogService.urgent(withinDays: 2),
            overdue: backlogService.overdue
        )
        let layers = Self.contextLayers(hour: hour, meetingsCount: meetings.count)

        suggestion = Self.compose(signals: signals, layers: layers)
    }

    // MARK: - Signal Production

    /// Produce all applicable signals for the current schedule snapshot.
    /// Pure function — no access to `self` — so it's trivially testable.
    static func signals(
        hour: Int,
        meetingsCount: Int,
        todayEventsCount: Int,
        hasFocusToday: Bool,
        pending: [BacklogTask],
        urgent: [BacklogTask],
        overdue: [BacklogTask]
    ) -> [Signal] {
        var out: [Signal] = []

        if !overdue.isEmpty {
            let n = overdue.count
            out.append(Signal(
                name: "overdue",
                priority: 100,
                intents: [.includeBacklog, .findSlotsForBacklog, .speed(.quick), .scenarios(count: 1)],
                reasonFragment: "\(n) overdue task\(n == 1 ? "" : "s")"
            ))
        }

        if let first = urgent.first {
            out.append(Signal(
                name: "urgent",
                priority: 90,
                intents: [.includeBacklog, .prioritizeDeadlines(weight: 3.0), .speed(.balanced), .scenarios(count: 2)],
                reasonFragment: "\(first.title) due soon"
            ))
        }

        if meetingsCount >= 5 {
            out.append(Signal(
                name: "meetings-heavy",
                priority: 70,
                intents: [.batchMeetings(), .protectLunch(), .speed(.balanced), .scenarios(count: 2)],
                reasonFragment: "\(meetingsCount) meetings — batch them?"
            ))
        }

        if pending.count >= 3 {
            out.append(Signal(
                name: "pending-tasks",
                priority: 60,
                intents: [.includeBacklog, .findSlotsForBacklog, .speed(.quick), .scenarios(count: 1)],
                reasonFragment: "\(pending.count)\u{00A0}tasks to schedule"
            ))
        }

        if hour < 14 && !hasFocusToday {
            out.append(Signal(
                name: "no-focus",
                priority: 50,
                intents: [.focusBlock(minutes: 120, period: .morning), .findSlotsForBacklog, .speed(.quick), .scenarios(count: 1)],
                reasonFragment: "No focus time today"
            ))
        }

        if hour < 10 && todayEventsCount >= 3 {
            out.append(Signal(
                name: "organize-morning",
                priority: 40,
                intents: [.includeBacklog, .speed(.balanced), .scenarios(count: 2)],
                reasonFragment: "Organize your day"
            ))
        }

        return out
    }

    /// Produce silent time-aware layers. Pure function — testable in isolation.
    static func contextLayers(hour: Int, meetingsCount: Int) -> [ContextLayer] {
        var out: [ContextLayer] = []
        if hour >= 14 {
            out.append(ContextLayer(name: "protect-lunch", intents: [.protectLunch()]))
        }
        if hour >= 16 {
            out.append(ContextLayer(name: "wind-down", intents: [.windDown(lastHours: 2)]))
        }
        if meetingsCount >= 3 {
            out.append(ContextLayer(name: "meeting-prep", intents: [.meetingPrep(minutes: 5)]))
        }
        return out
    }

    // MARK: - Composer

    /// Combine signals and context layers into a single suggestion.
    ///
    /// - Returns `nil` when no ``Signal`` fired. Context layers without a
    ///   signal to ride on never surface — the banner needs a reason.
    /// - Signals merge first, in descending priority order, so the most
    ///   urgent observation wins single-cardinality categories
    ///   (``IntentCardinalityKey``).
    /// - Context layers merge last and only fill unseen cardinality slots;
    ///   they never override a signal's `.speed` or `.stability`.
    /// - Exact-value dedup: three signals voting `.includeBacklog` produce it
    ///   once, attributed to the first contributor.
    /// - Reason = top two signal fragments joined with ` · `.
    /// - Attribution records the final owner of each intent (first to add it).
    static func compose(signals: [Signal], layers: [ContextLayer]) -> Suggestion? {
        guard !signals.isEmpty else { return nil }

        let orderedSignals = signals.sorted { $0.priority > $1.priority }

        // Composer state: intent list, dedup sets, attribution map.
        var composed: [ScheduleIntent] = [.horizon(.today)]
        var seenExact: Set<ScheduleIntent> = [.horizon(.today)]
        var seenCardinality: Set<IntentCardinalityKey> = [.horizon]
        var contributions: [String: [ScheduleIntent]] = ["seed": [.horizon(.today)]]

        func absorb(_ source: String, _ intents: [ScheduleIntent]) {
            for intent in intents {
                if let key = intent.singleCardinalityKey {
                    if seenCardinality.contains(key) { continue }
                    seenCardinality.insert(key)
                }
                if seenExact.contains(intent) { continue }
                seenExact.insert(intent)
                composed.append(intent)
                contributions[source, default: []].append(intent)
            }
        }

        for signal in orderedSignals {
            absorb(signal.name, signal.intents)
        }
        for layer in layers {
            absorb(layer.name, layer.intents)
        }

        // Reason = top-2 user-facing fragments. Signals are already sorted by
        // priority, so just take the first two.
        let reason = orderedSignals
            .prefix(2)
            .map(\.reasonFragment)
            .joined(separator: " · ")

        return Suggestion(
            request: OptimizationRequest(composed, name: reason),
            reason: reason,
            contributions: contributions.filter { !$0.value.isEmpty }
        )
    }

    // MARK: - Timer

    private func startSuggestionTimer() {
        evaluate()
        suggestionTimer = Timer.scheduledTimer(withTimeInterval: 15 * 60, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.energyCheckInService?.evaluatePrompt()
                self?.evaluate()
            }
        }
    }

    deinit {
        suggestionTimer?.invalidate()
        for token in backlogObservers {
            NotificationCenter.default.removeObserver(token)
        }
    }
}
