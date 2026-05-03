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
    private(set) var shadowProposal: ScheduleScenario? = nil
    private(set) var shadowProposalUpdatedAt: Date? = nil
    private var shadowProposalTask: Task<Void, Never>? = nil

    /// The last applied snapshot for undo support.
    private(set) var lastSnapshot: AppliedSnapshot? = nil

    /// Lightweight summary of the most recently applied request, kept
    /// alongside `lastSnapshot` for the «reasoning surface» — the tiny
    /// «Done · why?» hint that briefly appears under `SmartActions`
    /// after a Run completes. Birman: «the optimizer is not magic — it's
    /// an explicit rule», so the UI can read this back to show the user
    /// which intents drove the change. Cleared by `undoLast`.
    private(set) var lastAppliedRequest: AppliedRequestSummary? = nil

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

    /// Working-day picker binding for `OptimizerPreferences.workingDays`.
    /// Lives on the service so every surface that tweaks working time
    /// binds to the same source of truth, and so the setter routes
    /// the change through `savePreferences()` — otherwise a UI change
    /// would be lost on relaunch. Uses Foundation's 1-indexed weekday
    /// convention (1 = Sun, …, 7 = Sat).
    var workingDays: Set<Int> {
        get { optimizer.preferences.workingDays }
        set {
            optimizer.preferences.workingDays = newValue
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
        // Persisted preferences are tried best-effort — if the on-disk
        // blob predates the current model (e.g. the old `skipWeekends`
        // Bool has been dropped and `workingDays` is now non-optional),
        // decode throws and we fall through to a fresh default preferences
        // instance. First-run after upgrade will reset other preference
        // fields too; that's the explicit "no backward compat" trade.
        if let data = UserDefaults.standard.data(forKey: "BuboOptimizerPreferences"),
           let prefs = try? JSONDecoder().decode(OptimizerPreferences.self, from: data) {
            self.optimizer.preferences = prefs
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

        // Record what was just applied for the «reasoning surface» (the
        // tiny "Done · why?" hint in `SmartActions`). The request's
        // intents drive the human-readable breakdown, the timestamp lets
        // the UI auto-fade after ~8 s. Mirrors `lastSnapshot` (used by
        // undo) but is purely advisory — no behaviour depends on it.
        if let request = activeRequest {
            lastAppliedRequest = AppliedRequestSummary(
                request: request,
                label: activeRequestName ?? request.name ?? "Optimization",
                appliedAt: Date(),
                taskCount: scenario.activeGenes.count,
                scenarioCount: scenarios.count,
                appliedScenarioIndex: index
            )
        }

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
        // Drop the reasoning-surface record too — the user just undid
        // the change, so the «Done · why?» hint pointing to it is now
        // misleading. Keeping it would describe a state that no longer
        // exists.
        lastAppliedRequest = nil
        scenarios = []
        selectedScenarioIndex = nil
    }

    // MARK: - Shadow proposal (background pre-compute)

    /// Run an `OptimizationRequest` in the background and stash the
    /// best scenario into `shadowProposal` without applying it. Cancels
    /// any previously-pending preview, so callers can fire-and-forget on
    /// every backlog edit without a debouncer (the GA itself absorbs
    /// the cost via internal early-out heuristics on identical input).
    ///
    /// The compute runs through the same `IntentCompiler` path as
    /// `executeRequest`, so locks, exclusions, working-hours and every
    /// other persistent setting apply identically. Only the result
    /// path differs — instead of writing to `scenarios` and flipping
    /// `lastOptimizationDate`, it writes to `shadowProposal` and
    /// `shadowProposalUpdatedAt` and never touches `lastSnapshot` /
    /// `lastAppliedRequest` (those drive undo + the reasoning surface,
    /// neither of which a background preview should perturb).
    ///
    /// Use sparingly — the full GA path is not free. Callers should
    /// debounce upstream (e.g. on a 600 ms timer past the last backlog
    /// keystroke). The simple implementation here is a fire-and-cancel
    /// queue: a fresh call cancels the previous task, so back-to-back
    /// calls collapse to one run on the latest input.
    ///
    /// Birman: «let the machine sweat» — the optimizer is always one beat
    /// ahead, so when the user *does* hit Run it confirms what's already
    /// visible rather than waiting for fresh thinking.
    func previewRequest(
        _ request: OptimizationRequest,
        reminderService: ReminderService
    ) {
        // Cancel any pending preview so the queue depth stays at 1.
        // Last-writer-wins is the right semantics for a UI-driven
        // pre-compute — earlier inputs are stale by the time a new one
        // lands.
        shadowProposalTask?.cancel()

        guard let backlogSvc = backlogService else { return }

        // Inject the same persistent constraints `executeRequest` adds —
        // a preview that ignores user locks would propose moves the
        // real run won't make, defeating the whole «accurate ghost»
        // purpose.
        var effectiveRequest = request
        if !lockedEventIds.isEmpty {
            effectiveRequest.add(.keepFixed(eventIds: Array(lockedEventIds)))
        }
        if !excludedEventIds.isEmpty {
            effectiveRequest.add(.exclude(eventIds: Array(excludedEventIds)))
        }

        let captured = effectiveRequest
        shadowProposalTask = Task { [weak self] in
            guard let self else { return }
            var compiler = IntentCompiler(
                optimizer: self.optimizer,
                reminderService: reminderService,
                backlogService: backlogSvc
            )
            compiler.subgraphRegistry = self.subgraphRegistry
            compiler.energyCheckInService = self.energyCheckInService
            compiler.pomodoroHistory = self.pomodoroHistory
            let result = await compiler.execute(captured, defaultWorkingHours: self.workingHours)

            // Preview ran during a Task; drop the result if cancelled
            // (a newer preview is already in flight or the caller went
            // away). MainActor hop because `shadowProposal` is on a
            // @MainActor service.
            if Task.isCancelled { return }
            await MainActor.run {
                switch result {
                case .success(let opt), .partialSuccess(let opt, _, _):
                    self.shadowProposal = opt.scenarios.first
                case .noEventsToOptimize, .infeasible:
                    self.shadowProposal = nil
                }
                self.shadowProposalUpdatedAt = Date()
            }
        }
    }

    /// Drop the current shadow proposal — used when the user starts
    /// editing in a way that invalidates it (e.g. major backlog
    /// reorder). Cheap; the preview will re-fill on the next call.
    func clearShadowProposal() {
        shadowProposalTask?.cancel()
        shadowProposalTask = nil
        shadowProposal = nil
        shadowProposalUpdatedAt = nil
    }

    // MARK: - Scenario switching (post-apply)

    /// Swap the currently-applied scenario for a different one in the
    /// same `scenarios` array, without losing the array (and without
    /// the user having to undo + re-run from scratch). Used by
    /// `SmartActions`'s reasoning-row scenario cycle: the GA returned
    /// 2-3 alternatives, the user wants to flip between them.
    ///
    /// Implementation rolls back the previously-applied scenario the
    /// same way `undoLast` does (delete created events, restore
    /// `previousGenes`, unschedule linked backlog rows), then applies
    /// the new scenario through the regular `applyScenario(at:to:)`
    /// path. The new run captures its own `lastSnapshot` whose
    /// `previousGenes` matches the *original* baseline — so a single
    /// undo from this state still rolls all the way back to before any
    /// scenario was applied, regardless of how many times the user
    /// cycled.
    ///
    /// Returns true on success, false when the inputs are out of
    /// bounds or no snapshot exists to roll back from.
    @discardableResult
    func switchToAppliedScenario(
        at index: Int,
        to reminderService: ReminderService
    ) -> Bool {
        guard let snapshot = lastSnapshot else { return false }
        guard index >= 0, index < scenarios.count else { return false }
        guard index != selectedScenarioIndex else { return true }

        // Roll back the existing apply. Identical surface area to
        // `undoLast` minus the state-clearing — we want to preserve
        // `scenarios` and `activeRequest` so the second `applyScenario`
        // below has the context it needs.
        for eventId in snapshot.createdEventIds {
            reminderService.removeLocalEvent(id: eventId)
        }
        for gene in snapshot.appliedGenes {
            backlogService?.unschedule(id: gene.eventId)
        }
        optimizer.currentSchedule = snapshot.previousGenes

        // Snapshot the scenarios array because `applyScenario` would
        // otherwise overwrite `previousGenes` with the just-restored
        // state — which we want — but downstream observers might race.
        let preservedScenarios = scenarios
        applyScenario(at: index, to: reminderService)
        if scenarios.isEmpty {
            scenarios = preservedScenarios
        }

        return true
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
