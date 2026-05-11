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
    var selectedScenarioIndex: Int? = nil
    var isOptimizing: Bool = false
    var lastOptimizationDate: Date? = nil
    var error: String? = nil

    /// Background «what would the optimizer do right now?» proposal,
    /// kept fresh by `previewRequest(_:reminderService:)`. Never applied
    /// automatically — it's purely a read for UI surfaces that want to
    /// show the user where things would go *before* they hit Run:
    ///
    /// - The per-task ghost-slot `→ HH:MM` in `BacklogTaskRow` (today
    ///   filled by a naive greedy walk; this slot lets it use the GA's
    ///   real per-task `start` once a debounce wires `previewRequest` to
    ///   backlog edits).
    /// - The «would tip past 17:00» subtext in `SmartActions` Hard rows.
    /// - The ghost-card overlay on the timeline (planned).
    ///
    /// Birman: «let the machine sweat» — the system constantly keeps
    /// a ready plan in the background; the user sees the outcome, not the command.
    /// Cleared by `previewRequest` itself when the run fails or
    /// returns no scenarios. Distinct from `scenarios` so a
    /// background pre-compute can't race a user-initiated apply.
    // `shadowProposal*` setters are internal (not `private(set)`) so the
    // sibling `OptimizerService+ShadowProposals` extension can stamp
    // pre-compute results without routing through a delegating method.
    // External consumers should still treat these as read-only.
    var shadowProposal: ScheduleScenario? = nil
    var shadowProposalUpdatedAt: Date? = nil
    var shadowProposalTask: Task<Void, Never>? = nil

    /// The last applied snapshot for undo support.
    var lastSnapshot: AppliedSnapshot? = nil

    /// Lightweight summary of the most recently applied request, kept
    /// alongside `lastSnapshot` for the «reasoning surface» — the tiny
    /// «Done · why?» hint that briefly appears under `SmartActions`
    /// after a Run completes. Birman: «the optimizer is not magic — it's
    /// an explicit rule», so the UI can read this back to show the user
    /// which intents drove the change. Cleared by `undoLast`.
    var lastAppliedRequest: AppliedRequestSummary? = nil

    /// Set of event ids the user has explicitly locked via the per-row
    /// lock affordance in `EventRowView`. Persisted in `UserDefaults`
    /// so locks survive app relaunches. Read by `executeRequest` to
    /// inject an implicit `.keepFixed(eventIds: ...)` intent into every
    /// optimizer run, so the GA never moves these events on user-
    /// triggered passes. Mirrors what would otherwise require typing
    /// «keep this event fixed» into the command palette for each one.
    /// Birman: «rules are objects on the screen» — the lock icon IS
    /// the intent.
    private(set) var lockedEventIds: Set<String> = OptimizerService.loadIds(key: OptimizerService.lockedEventIdsKey)

    /// Set of event ids the user has explicitly **excluded** from
    /// optimization via the per-event context menu in `EventRowView`.
    /// Persisted in `UserDefaults` like `lockedEventIds`. The two sets
    /// are semantically distinct — locked = «pin in place», excluded =
    /// «pretend it doesn't exist» — so the GA receives both intents
    /// when both are non-empty. An event in both sets behaves like
    /// excluded (the stricter intent wins inside the IntentCompiler).
    private(set) var excludedEventIds: Set<String> = OptimizerService.loadIds(key: OptimizerService.excludedEventIdsKey)

    private static let lockedEventIdsKey = "BuboOptimizerLockedEventIds"
    private static let excludedEventIdsKey = "BuboOptimizerExcludedEventIds"

    private static func loadIds(key: String) -> Set<String> {
        guard let raw = UserDefaults.standard.array(forKey: key) as? [String] else {
            return []
        }
        return Set(raw)
    }

    private func persist(_ ids: Set<String>, key: String) {
        UserDefaults.standard.set(Array(ids), forKey: key)
    }

    /// Toggle this event's locked state. Source-of-truth for the per-
    /// row lock affordance. Persists immediately so the next launch
    /// reflects the user's choice.
    func toggleLock(eventId: String) {
        if lockedEventIds.contains(eventId) {
            lockedEventIds.remove(eventId)
        } else {
            lockedEventIds.insert(eventId)
        }
        persist(lockedEventIds, key: Self.lockedEventIdsKey)
    }

    /// Toggle this event's excluded state. Companion to `toggleLock` for
    /// the «exclude from optimization» context-menu item in EventRowView.
    func toggleExclude(eventId: String) {
        if excludedEventIds.contains(eventId) {
            excludedEventIds.remove(eventId)
        } else {
            excludedEventIds.insert(eventId)
        }
        persist(excludedEventIds, key: Self.excludedEventIdsKey)
    }

    /// Whether this event is currently locked. Cheap O(1) lookup —
    /// safe to call from `EventRowView` on every render.
    func isLocked(eventId: String) -> Bool {
        lockedEventIds.contains(eventId)
    }

    func isExcluded(eventId: String) -> Bool {
        excludedEventIds.contains(eventId)
    }

    /// Per-event «flex» percentage (0/25/50). 0 = rigid (default — the
    /// optimizer keeps the duration as-is). 25 / 50 mean «GA may shrink
    /// or grow this event by ±N% of its current duration via a per-
    /// event `.flexDuration(...)` injected when the user runs an
    /// optimizer pass scoped to this event». UserDefaults-backed map
    /// keyed by event id. Stored as `[String: Int]` — anything else
    /// would require migration.
    private(set) var flexPercentByEventId: [String: Int] = OptimizerService.loadFlexMap()

    private static let flexMapKey = "BuboOptimizerFlexPercentByEventId"

    private static func loadFlexMap() -> [String: Int] {
        guard let raw = UserDefaults.standard.dictionary(forKey: flexMapKey) as? [String: Int] else {
            return [:]
        }
        return raw
    }

    private func persistFlexMap() {
        UserDefaults.standard.set(flexPercentByEventId, forKey: Self.flexMapKey)
    }

    /// Set the flex percentage for an event (0 / 25 / 50 are the
    /// canonical UI values, but any 0…100 is accepted). 0 removes the
    /// entry entirely so the persistent dict doesn't accumulate
    /// «rigid» records.
    func setFlex(percent: Int, eventId: String) {
        let clamped = max(0, min(100, percent))
        if clamped == 0 {
            flexPercentByEventId.removeValue(forKey: eventId)
        } else {
            flexPercentByEventId[eventId] = clamped
        }
        persistFlexMap()
    }

    func flex(eventId: String) -> Int {
        flexPercentByEventId[eventId] ?? 0
    }

    /// Build a per-event `.flexDuration(min, max)` intent for one
    /// specific event using its stored flex percent and the event's
    /// own duration. Returns nil when the event isn't flex-marked
    /// (rigid is the default), so callers can `compactMap` over a
    /// list of events to build a list of intents.
    ///
    /// Caller convention: the resulting intent should be combined
    /// with `.onlyOptimize(eventIds: [event.id])` so the global
    /// `flexDuration` semantics are scoped to just this event in the
    /// resulting Run. The service does not auto-inject these on every
    /// `executeRequest` (the global semantics would over-flex
    /// everything else); callers explicitly opt in via per-event
    /// flows like `runQuickAction`'s flex-this-event path.
    func flexIntent(for event: CalendarEvent) -> ScheduleIntent? {
        let percent = flex(eventId: event.id)
        guard percent > 0 else { return nil }
        let durationMinutes = max(1, Int(event.endDate.timeIntervalSince(event.startDate) / 60))
        let lower = max(5, durationMinutes - durationMinutes * percent / 100)
        let upper = durationMinutes + durationMinutes * percent / 100
        return .flexDuration(minMinutes: lower, maxMinutes: upper)
    }

    /// Drop entries from `lockedEventIds` / `excludedEventIds` /
    /// `flexPercentByEventId` whose underlying events no longer exist
    /// in the reminder service. Keeps the persistent maps from
    /// accumulating stale ids over time — otherwise a year-old
    /// deleted event id stays in UserDefaults forever.
    ///
    /// Called from `MenuBarView.runAutoDeferIfNeeded` so the cleanup
    /// runs at most once per calendar day, on the same trigger that
    /// already does once-a-day backlog hygiene. No undo — these are
    /// pure id-string removals; their absence has no observable effect
    /// (the events are gone anyway).
    func pruneStaleEventConstraints(reminderService: ReminderService) {
        let liveIds = Set(reminderService.allEvents.map(\.id))
        let staleLocked = lockedEventIds.subtracting(liveIds)
        let staleExcluded = excludedEventIds.subtracting(liveIds)
        let staleFlex = Set(flexPercentByEventId.keys).subtracting(liveIds)
        guard !staleLocked.isEmpty || !staleExcluded.isEmpty || !staleFlex.isEmpty else { return }
        lockedEventIds.subtract(staleLocked)
        excludedEventIds.subtract(staleExcluded)
        for id in staleFlex { flexPercentByEventId.removeValue(forKey: id) }
        persist(lockedEventIds, key: Self.lockedEventIdsKey)
        persist(excludedEventIds, key: Self.excludedEventIdsKey)
        persistFlexMap()
    }

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
        // Drop the reasoning-surface record too — the user just undid
        // the change, so the «Done · why?» hint pointing to it is now
        // misleading. Keeping it would describe a state that no longer
        // exists.
        lastAppliedRequest = nil
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

}
