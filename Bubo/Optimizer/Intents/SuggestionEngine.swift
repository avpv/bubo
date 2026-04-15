import Foundation

// MARK: - Suggestion Engine

/// Composes smart optimization requests from schedule context.
/// The user never sees 65 intents — this engine picks the right ones
/// and composes a request that just works.
///
/// Birman: "Пусть потеет машина" — the system does the thinking.
///
/// # Composition model
///
/// Each schedule signal (overdue tasks, meeting-heavy day, no focus time…)
/// is produced independently as a ``Signal``. A signal contributes:
/// - a set of intents it wants to add,
/// - a reason fragment (user-facing) or nothing (silent/time-aware),
/// - a priority so headline reasons and single-cardinality conflicts
///   resolve deterministically.
///
/// The composer merges all active signals, deduplicates exact matches,
/// and for single-cardinality categories (speed, horizon, scenarios,
/// stability) the highest-priority signal wins. This replaces the old
/// if/else cascade where a meeting-heavy day with overdue tasks would
/// silently drop the meeting-batching intents.
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

    init(reminderService: ReminderService, backlogService: BacklogService) {
        self.reminderService = reminderService
        self.backlogService = backlogService
        startSuggestionTimer()
    }

    struct Suggestion: Sendable {
        let request: OptimizationRequest
        let reason: String
    }

    // MARK: - Signal

    /// A single observation about the schedule that contributes intents.
    ///
    /// Signals are produced independently and composed additively.
    /// `reasonFragment` is empty for silent signals (time-aware layers
    /// like `protectLunch` that shouldn't show up in the banner text).
    struct Signal: Sendable, Equatable {
        let name: String
        let priority: Int
        let intents: [ScheduleIntent]
        let reasonFragment: String

        var isSilent: Bool { reasonFragment.isEmpty }
    }

    // MARK: - Evaluate

    func evaluate() {
        let now = Date()
        let cal = Calendar.current
        let hour = cal.component(.hour, from: now)
        let events = reminderService.allEvents
        let todayEnd = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: now))!
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

        suggestion = Self.compose(signals)
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
                reasonFragment: "\(pending.count) tasks to schedule"
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

        // Time-aware silent layers — no banner text, just composed intents.
        if hour >= 14 {
            out.append(Signal(
                name: "protect-lunch",
                priority: 20,
                intents: [.protectLunch()],
                reasonFragment: ""
            ))
        }

        if hour >= 16 {
            out.append(Signal(
                name: "wind-down",
                priority: 20,
                intents: [.windDown(lastHours: 2)],
                reasonFragment: ""
            ))
        }

        if meetingsCount >= 3 {
            out.append(Signal(
                name: "meeting-prep",
                priority: 20,
                intents: [.meetingPrep(minutes: 5)],
                reasonFragment: ""
            ))
        }

        return out
    }

    // MARK: - Composer

    /// Combine signals into a single suggestion.
    ///
    /// - Returns `nil` when no signal carries a user-facing reason — we won't
    ///   show the banner just because silent time-aware layers fired.
    /// - Deduplicates exact intent matches so three signals voting
    ///   `.includeBacklog` produce it once.
    /// - For single-cardinality categories (speed, horizon, scenarios,
    ///   stability) the highest-priority signal wins; lower-priority
    ///   contributions for the same category are dropped.
    /// - Reason text is the top two user-facing fragments joined with ` · `,
    ///   so a day with both overdue tasks and 5 meetings reads honestly.
    static func compose(_ signals: [Signal]) -> Suggestion? {
        let userFacing = signals.filter { !$0.isSilent }
        guard !userFacing.isEmpty else { return nil }

        let byPriority = signals.sorted { $0.priority > $1.priority }

        var composed: [ScheduleIntent] = [.horizon(.today)]
        var seenExact = Set<ScheduleIntent>([.horizon(.today)])
        var seenSingleCardinality = Set<SingleCardinalityKey>([.horizon])

        for signal in byPriority {
            for intent in signal.intents {
                if let key = singleCardinalityKey(of: intent) {
                    if seenSingleCardinality.contains(key) { continue }
                    seenSingleCardinality.insert(key)
                }
                if seenExact.contains(intent) { continue }
                seenExact.insert(intent)
                composed.append(intent)
            }
        }

        let reasonFragments = userFacing
            .sorted { $0.priority > $1.priority }
            .prefix(2)
            .map(\.reasonFragment)
        let reason = reasonFragments.joined(separator: " · ")

        return Suggestion(
            request: OptimizationRequest(composed, name: reason),
            reason: reason
        )
    }

    // MARK: - Cardinality

    /// Intent categories where only one setting makes sense per request.
    /// Multiple contributions collapse to the highest-priority signal's choice.
    private enum SingleCardinalityKey: Hashable {
        case speed
        case horizon
        case scenarios
        case stability
    }

    private static func singleCardinalityKey(of intent: ScheduleIntent) -> SingleCardinalityKey? {
        switch intent {
        case .speed: return .speed
        case .horizon: return .horizon
        case .scenarios: return .scenarios
        case .stability: return .stability
        default: return nil
        }
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

    deinit { suggestionTimer?.invalidate() }
}
