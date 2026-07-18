import Foundation
import OSLog
import UserNotifications
import BuboDomain
import BuboOptimizer

// MARK: - Optimizer Service

/// Bridges BuboOptimizer with the rest of the app.
/// All optimization flows go through intent-based OptimizationRequest.
@MainActor
@Observable
final class OptimizerService {

    let optimizer = BuboOptimizer()
    let intentLearner = IntentLearner()

    // MARK: - Persisted settings (stored properties live here; the
    // didSet observers, computed `workingDays`/`workingHours`, and the
    // CloudKit-driven sync helpers live in `OptimizerService+Settings`.)

    // Both bounds clamp to the same invariants the per-day setter
    // (`setWorkingHours(on:)`) enforces: start 0…22, end 1…23,
    // start < end preserved by pushing the other bound. Without the
    // range clamps, start = 23 pushed end to 24 and end = 0 pushed
    // start to −1 — both persisted, synced to CloudKit, and turned
    // every `calendar.date(bySettingHour:)` consumer (capacity ring,
    // free slots, boundary rows) into a nil. The clamp-and-return
    // pattern mirrors `defaultTaskDurationMinutes` below: the
    // reassignment re-enters didSet exactly once with a valid value.
    var workingHoursStart: Int {
        didSet {
            let clamped = max(0, min(22, workingHoursStart))
            if clamped != workingHoursStart {
                workingHoursStart = clamped
                return
            }
            if workingHoursStart >= workingHoursEnd {
                workingHoursEnd = workingHoursStart + 1
            }
            saveSettings()
        }
    }
    var workingHoursEnd: Int {
        didSet {
            let clamped = max(1, min(23, workingHoursEnd))
            if clamped != workingHoursEnd {
                workingHoursEnd = clamped
                return
            }
            if workingHoursEnd <= workingHoursStart {
                workingHoursStart = workingHoursEnd - 1
            }
            saveSettings()
        }
    }
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

    /// One day's working-hours shape, for per-day overrides.
    struct DayWorkingHours: Codable, Equatable {
        var start: Int
        var end: Int
    }

    /// Per-day working-hours overrides, keyed by `Self.dayKey(for:)`
    /// («2026-07-15»). The timeline's inline boundary handles write
    /// here: adjusting one day's boundary is a decision about THAT day
    /// and must not rewrite the global rule for every other day — the
    /// default lives in Settings → Optimizer and keeps governing every
    /// day without an entry. Entries that land back on the default are
    /// dropped; past days are pruned at load. Resolution and mutation
    /// live in `OptimizerService+Settings`, persistence in
    /// `OptimizerService+Persistence`.
    var workingHoursOverrides: [String: DayWorkingHours] {
        didSet { saveWorkingHoursOverrides() }
    }

    let persistenceKey = "BuboOptimizerServiceSettings"
    let preferencesKey = "BuboOptimizerPreferences"
    let workingHoursOverridesKey = "BuboWorkingHoursDayOverrides"

    /// Prevents didSet -> save -> push loop when reloading cloud data.
    var isReloadingFromCloud = false
    var cloudSyncObserver: Any?

    init() {
        let saved = Self.loadSettings()
        self.workingHoursStart = saved.start
        self.workingHoursEnd = saved.end
        self.defaultTaskDurationMinutes = saved.defaultDuration
        self.workingHoursOverrides = Self.loadWorkingHoursOverrides()
        // Persisted preferences are tried best-effort — if the on-disk
        // blob predates the current model, decoding throws and we fall
        // through to a fresh default preferences instance.
        if let data = UserDefaults.standard.data(forKey: "BuboOptimizerPreferences"),
           let prefs = try? JSONDecoder().decode(OptimizerPreferences.self, from: data) {
            self.optimizer.preferences = prefs
        }
        setupCloudSync()
    }

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

    /// Drop entries from `lockedEventIds` / `excludedEventIds` whose
    /// underlying events no longer exist in the reminder service. Keeps
    /// the persistent maps from accumulating stale ids over time —
    /// otherwise a year-old deleted event id stays in UserDefaults
    /// forever.
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
        guard !staleLocked.isEmpty || !staleExcluded.isEmpty else { return }
        lockedEventIds.subtract(staleLocked)
        excludedEventIds.subtract(staleExcluded)
        persist(lockedEventIds, key: Self.lockedEventIdsKey)
        persist(excludedEventIds, key: Self.excludedEventIdsKey)
    }

    /// IDs of events created in the most recent application.
    /// Used by EventRowView to highlight freshly created events.
    var freshlyCreatedEventIds: Set<String> = []

    /// The active optimization request (for display and learning).
    var activeRequestName: String? = nil
    /// The full active request (for IntentLearner recording).
    var activeRequest: OptimizationRequest? = nil

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

    /// Roll a single applied snapshot back: delete what the apply
    /// created, re-add what it deleted, and restore backlog link state
    /// by *task id* (the key `markScheduled` used — gene event ids are
    /// not task ids for focus blocks and chunked tasks). Shared by
    /// `undoLast` and `switchToAppliedScenario`; ordering matters —
    /// created events go first so an event id reused across runs comes
    /// back with its pre-apply content.
    func rollbackApplied(_ snapshot: AppliedSnapshot, reminderService: ReminderService) {
        for eventId in snapshot.createdEventIds {
            reminderService.removeLocalEvent(id: eventId)
        }
        for event in snapshot.removedEvents {
            reminderService.addLocalEvent(event)
        }
        for link in snapshot.previousTaskLinks {
            if link.scheduledEventIds.isEmpty {
                backlogService?.unschedule(id: link.taskId)
            } else {
                backlogService?.markScheduled(
                    id: link.taskId,
                    eventIds: link.scheduledEventIds,
                    date: link.scheduledDate ?? snapshot.appliedAt
                )
            }
        }
        optimizer.currentSchedule = snapshot.previousGenes
    }

    func undoLast(reminderService: ReminderService) {
        guard let snapshot = lastSnapshot else { return }
        rollbackApplied(snapshot, reminderService: reminderService)
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
