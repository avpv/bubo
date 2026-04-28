import SwiftUI

struct MenuBarView: View {
    @Environment(\.activeSkin) private var skin
    var settings: ReminderSettings
    var reminderService: ReminderService
    var networkMonitor: NetworkMonitor
    var optimizerService: OptimizerService
    var agentService: AgentService
    var remindersSyncService: RemindersSyncService

    @State private var navigation: Navigation = .list
    @State private var hasStartedSync = false
    @State private var toastState = ToastState()
    @State private var scrollPositionID: String?

    /// Vertical scroll offset (in points, negative as the user scrolls
    /// down) of the event list. Consumed by `AppBackgroundLayer` to
    /// drive a small parallax on the wallpaper — the background drifts
    /// at ~15% of foreground velocity, giving a depth cue that the
    /// foreground content is closer to the eye than the wallpaper.
    /// Reset to zero when leaving the list view or when Reduce Motion
    /// is on, so no extra paint cost on accessibility paths.
    @State private var listScrollY: CGFloat = 0
    @State private var colorFilter: EventColorTag? = nil
    /// Mutually exclusive with `colorFilter`. Tri-state cycle on the hollow
    /// dot button: `.all` (default) → `.onlyFree` (hide events, show only
    /// free slots so users can eyeball open time) → `.hideFree` (show events,
    /// hide the "Free · Xh" rows for a compact busy-day read).
    @State private var freeSlotFilter: FreeSlotFilter = .all

    /// When true, BacklogView will grab focus on its "Add task…" field.
    /// Set from footer / keyboard shortcut, consumed by BacklogView.
    @State private var focusTaskInput = false

    /// Shared state for backlog drag-to-schedule + ghost-preview. Owned here
    /// because both the drag source (BacklogView) and the drop targets
    /// (FreeSlotRow instances scattered across the day list) need it, and the
    /// ghost block on the timeline is rendered by this view.
    @State private var backlogCoordinator = BacklogInteractionCoordinator()

    // Command palette — the single entry point for all optimize flows.
    @State private var paletteContext: PaletteContext? = nil
    @State private var dismissedBannerIds: Set<String> = {
        let stored = UserDefaults.standard.stringArray(forKey: "BuboDismissedBannerIds") ?? []
        return Set(stored)
    }()

    /// Cached EventKit permission snapshots driving the permission banners.
    /// EventKit exposes auth status only as a non-observable static call, so
    /// the view body cannot reactively re-evaluate it. Mirroring it into
    /// `@State` (refreshed on the services' `authorizationDidChange`
    /// notifications and on appear) makes the banner disappear immediately
    /// when the user grants access via the Settings pane.
    @State private var calendarHasAccess: Bool = AppleCalendarService.hasAccess
    @State private var remindersHasAccess: Bool = AppleRemindersService.hasAccess

    /// Measured bottom edge (in the root coordinate space) of the QuickActions
    /// "Optimize" bar. We anchor the command palette overlay just below this
    /// point so the optimizer trigger stays visible while the palette is open.
    @State private var optimizerBottomY: CGFloat = 0

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Enum-based navigation state machine replaces fragile boolean flags.
    enum Navigation: Equatable {
        case list
        case detail(CalendarEvent)
        case addEvent(editing: CalendarEvent? = nil, initialType: EventType = .standard)
        case editTask(BacklogTask)
        case timer(CalendarEvent)
        case quickAddTasks
        case backlog

        var isTimer: Bool {
            if case .timer = self { return true }
            return false
        }

        static func == (lhs: Navigation, rhs: Navigation) -> Bool {
            switch (lhs, rhs) {
            case (.list, .list): return true
            case (.detail(let a), .detail(let b)): return a.id == b.id
            case (.addEvent(let a, let t1), .addEvent(let b, let t2)): return a?.id == b?.id && t1 == t2
            case (.editTask(let a), .editTask(let b)): return a.id == b.id
            case (.timer(let a), .timer(let b)): return a.id == b.id
            case (.quickAddTasks, .quickAddTasks): return true
            case (.backlog, .backlog): return true
            default: return false
            }
        }
    }

    /// Context for the command palette overlay. nil = hidden.
    struct PaletteContext: Equatable {
        var seedEvent: CalendarEvent? = nil
        var seedSlotMinutes: Int? = nil
        var seedSlotStart: Date? = nil
        var seedSlotEnd: Date? = nil
        var seedRecipeId: String? = nil
    }

    private var activeSkin: SkinDefinition { settings.selectedSkin }

    var body: some View {
        ZStack {
            AppBackgroundLayer(
                skin: activeSkin,
                wallpaper: settings.selectedWallpaper,
                customPhotoPath: settings.customBackgroundPhotoPath,
                customPhotoOpacity: settings.customBackgroundPhotoOpacity,
                customPhotoBlur: settings.customBackgroundPhotoBlur,
                parallaxY: parallaxOffset
            )

            Group {
                switch navigation {
                case .list:
                    mainContent
                        .task {
                            try? await Task.sleep(for: .milliseconds(300))
                            withAnimation(DS.Animation.smoothSpring) {
                                scrollPositionID = nil
                            }
                        }
                        .transition(
                            reduceMotion ? .opacity : .asymmetric(
                                insertion: .move(edge: .leading).combined(with: .opacity),
                                removal: .move(edge: .leading).combined(with: .opacity).combined(with: .scale(scale: 0.98))
                            )
                        )

                case .detail(let event):
                    EventDetailView(
                        event: event,
                        reminderService: reminderService,
                        onBack: { navigation = .list },
                        onEdit: { event in resolveEdit(event) },
                        onDelete: { event in
                            let deletedEvent = event
                            reminderService.removeLocalEvent(id: event.id)
                            navigation = .list
                            toastState.showSuccess("\u{201C}\(deletedEvent.title)\u{201D} deleted", icon: "trash.fill") {
                                reminderService.addLocalEvent(deletedEvent)
                            }
                            notifyScheduleChange()
                        },
                        onDeleteSeries: { event in
                            let seriesId = event.seriesId ?? event.id
                            let seriesEvent = reminderService.seriesEvent(for: event) ?? event
                            reminderService.removeLocalEvent(id: seriesId)
                            navigation = .list
                            toastState.showSuccess("All \u{201C}\(event.title)\u{201D} deleted", icon: "trash.fill") {
                                reminderService.addLocalEvent(seriesEvent)
                            }
                            notifyScheduleChange()
                        },
                        onDeleteOccurrence: { event in
                            reminderService.excludeOccurrence(occurrenceId: event.id)
                            navigation = .list
                            toastState.showSuccess("\u{201C}\(event.title)\u{201D} removed", icon: "trash.fill")
                        },
                        onTimer: { event in
                            navigation = .timer(event)
                        }
                    )
                    .transition(
                        reduceMotion ? .opacity : .asymmetric(
                            insertion: .move(edge: .trailing).combined(with: .opacity),
                            removal: .move(edge: .trailing).combined(with: .opacity).combined(with: .scale(scale: 0.98))
                        )
                    )

                case .timer(let event):
                    TimerScreenView(
                        event: event,
                        onBack: { navigation = .detail(event) },
                        onRepeat: { finishedEvent in
                            // Re-create the same pomodoro session starting now
                            var repeat_ = finishedEvent
                            repeat_.id = UUID().uuidString
                            repeat_.startDate = Date()
                            repeat_.endDate = Date().addingTimeInterval(finishedEvent.duration)
                            reminderService.addLocalEvent(repeat_)
                            navigation = .timer(repeat_)
                            toastState.showSuccess("Session restarted")
                        },
                        onScheduleNext: { _ in
                            navigation = .list
                            // Stable preset name (was hard-coded "pomodoro"
                            // which never matched the actual preset name
                            // "Pomodoro session" → palette opened empty).
                            paletteContext = PaletteContext(seedRecipeId: IntentPresets.Name.pomodoroSession)
                        },
                        onSessionEnded: { entry in
                            optimizerService.pomodoroHistory.record(entry)
                        }
                    )
                    .transition(
                        reduceMotion ? .opacity : .asymmetric(
                            insertion: .move(edge: .trailing).combined(with: .opacity),
                            removal: .move(edge: .trailing).combined(with: .opacity).combined(with: .scale(scale: 0.98))
                        )
                    )

                case .addEvent(let editing, let initialType):
                    AddEventView(
                        reminderService: reminderService,
                        editingEvent: editing,
                        initialEventType: initialType,
                        onDismiss: {
                            // Return to detail if we were editing, otherwise list
                            if let event = editing,
                               let updated = reminderService.allEvents.first(where: { $0.id == event.id }) {
                                navigation = .detail(updated)
                            } else {
                                navigation = .list
                            }
                        },
                        onSave: { isEdit in
                            // After saving an edit, return to detail view with updated data
                            if isEdit, let eventId = editing?.id,
                               let updated = reminderService.allEvents.first(where: { $0.id == eventId }) {
                                navigation = .detail(updated)
                            } else {
                                navigation = .list
                            }
                            toastState.showSuccess(isEdit ? "Event updated" : "Event created")
                            if isEdit, editing?.id != nil {
                                notifyScheduleChange()
                            }
                        },
                        settings: settings,
                        optimizerService: optimizerService
                    )
                    .transition(
                        reduceMotion ? .opacity : .asymmetric(
                            insertion: .move(edge: .trailing).combined(with: .opacity),
                            removal: .move(edge: .trailing).combined(with: .opacity).combined(with: .scale(scale: 0.98))
                        )
                    )

                case .editTask(let task):
                    if let backlog = optimizerService.backlogService {
                        // Pull the live task by id every render so external
                        // mutations (sync, completion, dependency edits in
                        // another row) don't get reverted by stale state.
                        let liveTask = backlog.tasks.first(where: { $0.id == task.id }) ?? task
                        EditTaskView(
                            task: liveTask,
                            backlogService: backlog,
                            onDismiss: { navigation = .list },
                            onSave: {
                                navigation = .list
                                toastState.showSuccess("Task updated", icon: "checkmark.circle.fill")
                            }
                        )
                        .transition(
                            reduceMotion ? .opacity : .asymmetric(
                                insertion: .move(edge: .trailing).combined(with: .opacity),
                                removal: .move(edge: .trailing).combined(with: .opacity).combined(with: .scale(scale: 0.98))
                            )
                        )
                    } else {
                        EmptyView()
                            .onAppear { navigation = .list }
                    }

                case .backlog:
                    if let backlog = optimizerService.backlogService {
                        BacklogFullscreenView(
                            backlogService: backlog,
                            optimizerService: optimizerService,
                            reminderService: reminderService,
                            onExit: { navigation = .list },
                            onEditTask: { task in navigation = .editTask(task) },
                            onUndoableAction: { message, undo in
                                toastState.showSuccess(message, icon: "arrow.uturn.backward", onUndo: undo)
                            }
                        )
                        .transition(
                            reduceMotion ? .opacity : .asymmetric(
                                insertion: .move(edge: .trailing).combined(with: .opacity),
                                removal: .move(edge: .trailing).combined(with: .opacity).combined(with: .scale(scale: 0.98))
                            )
                        )
                    } else {
                        EmptyView()
                            .onAppear { navigation = .list }
                    }

                case .quickAddTasks:
                    // Backlog is now inline — return to list and focus the task input.
                    EmptyView()
                        .onAppear {
                            navigation = .list
                            focusTaskInput = true
                        }
                }
            }
            .animation(
                reduceMotion ? DS.Animation.quick : DS.Animation.smoothSpring,
                value: navigation
            )

            // Command palette — inline overlay anchored just below the
            // QuickActions "Optimize" bar so the optimizer trigger stays
            // visible while the palette is open.
            if let context = paletteContext {
                CommandPalette(
                    optimizerService: optimizerService,
                    reminderService: reminderService,
                    agentService: agentService,
                    seedEvent: context.seedEvent,
                    seedSlotMinutes: context.seedSlotMinutes,
                    seedSlotStart: context.seedSlotStart,
                    seedSlotEnd: context.seedSlotEnd,
                    seedPreset: context.seedRecipeId.flatMap { id in IntentPresets.all.first { $0.name == id } },
                    onDismiss: {
                        withAnimation(DS.Animation.quick) { paletteContext = nil }
                    },
                    onApplied: { request, undo in
                        toastState.showSuccess(
                            "\(request.name ?? "Schedule") applied",
                            icon: "sparkles",
                            onUndo: undo
                        )
                    }
                )
                .padding(.top, max(0, optimizerBottomY))
                .transition(.opacity)
                .zIndex(10)
            }

            ToastOverlay(toastState: toastState)

            // Hidden button for ⌘K shortcut — lives outside the palette so it
            // can toggle the palette from the list.
            Button("") {
                Haptics.tap()
                withAnimation(DS.Animation.quick) {
                    if paletteContext == nil {
                        paletteContext = PaletteContext()
                    } else {
                        paletteContext = nil
                    }
                }
            }
            .keyboardShortcut("k", modifiers: .command)
            .opacity(0)
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)

            // Hidden button for ⇧⌘N shortcut — focuses the task input field.
            Button("") {
                Haptics.tap()
                focusTaskInput = true
            }
            .keyboardShortcut("n", modifiers: [.command, .shift])
            .opacity(0)
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
        }
        .skinTinted(activeSkin)
        .skinTypography(activeSkin)
        .environment(\.activeSkin, activeSkin)
        .environment(\.backlogCoordinator, backlogCoordinator)
        .environment(\.navigateHome, { navigation = .list })
        .coordinateSpace(name: menuBarRootCoordinateSpace)
        .onPreferenceChange(OptimizerBottomKey.self) { optimizerBottomY = $0 }
        .frame(width: DS.Popover.width, height: navigation.isTimer ? DS.Popover.timerHeight : DS.Popover.height)
        .onAppear {
            // Refresh permission snapshots every time the popover surfaces
            // — covers the case where the user granted access via System
            // Settings while we were closed. Cheap, idempotent, and
            // independent of the one-shot `hasStartedSync` guard below.
            refreshPermissionSnapshots()

            guard !hasStartedSync else { return }
            hasStartedSync = true
            reminderService.updateSettings(settings)
            reminderService.startSync()
            remindersSyncService.updateSettings(settings)
            remindersSyncService.startSync()
            if let backlog = optimizerService.backlogService {
                optimizerService.setup(reminderService: reminderService, backlogService: backlog)
            } else {
                assertionFailure("BacklogService should be set in App.init")
            }
            Task {
                try? await Task.sleep(for: .seconds(5)) // wait for sync
                await optimizerService.runWeekMockSimulator(reminderService: reminderService)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: AppleCalendarService.authorizationDidChange)) { note in
            // Trust the grant result if the service posted one — the
            // static EKEventStore query can still return `.notDetermined`
            // for a moment after the continuation resolves, leaving the
            // banner stuck even though access was granted.
            if let granted = note.userInfo?["granted"] as? Bool {
                if calendarHasAccess != granted { calendarHasAccess = granted }
            } else {
                refreshPermissionSnapshots()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: AppleRemindersService.authorizationDidChange)) { note in
            if let granted = note.userInfo?["granted"] as? Bool {
                if remindersHasAccess != granted { remindersHasAccess = granted }
            } else {
                refreshPermissionSnapshots()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: RemindersSyncService.didImportTasks)) { notification in
            guard let count = notification.object as? Int, count > 0 else { return }
            let noun = count == 1 ? "task" : "tasks"
            toastState.showInfo("Imported \(count)\u{00A0}\(noun) from Reminders", icon: "checklist")
        }
        .onReceive(NotificationCenter.default.publisher(for: BacklogService.taskCompleted)) { notification in
            // Fires only for user-initiated completions in Bubo (the external-
            // mirror path uses `silentlyComplete`, which bypasses this).
            guard let taskId = notification.object as? String else { return }
            let title = optimizerService.backlogService?
                .tasks.first(where: { $0.id == taskId })?.title
            let message = title.map { "\u{201C}\($0)\u{201D} marked done" } ?? "Marked done"
            toastState.showSuccess(message, icon: "checkmark.circle.fill")
        }
    }

    // MARK: - Filtered Events

    private var filteredEventsByDay: [(date: Date, events: [CalendarEvent])] {
        let base: [(date: Date, events: [CalendarEvent])]
        if let filter = colorFilter {
            base = reminderService.eventsByDay.compactMap { dayGroup in
                let filtered = dayGroup.events.filter { $0.colorTag == filter }
                return filtered.isEmpty ? nil : (date: dayGroup.date, events: filtered)
            }
        } else {
            // Keep empty day groups so users can see their free slots and
            // drop tasks into days that have no events yet.
            base = reminderService.eventsByDay
        }
        return base
    }

    /// Count of visible (non-disintegrating) events for a day group.
    private func visibleEventCount(for events: [CalendarEvent]) -> Int {
        events.filter { !reminderService.disintegratingEventIDs.contains($0.id) }.count
    }

    // MARK: - Helpers

    private var pendingTaskCount: Int {
        optimizerService.backlogService?.pending.count ?? 0
    }

    private var isScrolledFromTop: Bool {
        guard let pos = scrollPositionID else { return false }
        let allEvents = reminderService.eventsByDay.flatMap(\.events)
        let topIDs = Set(allEvents.prefix(5).map(\.id))
        return !topIDs.contains(pos)
    }

    private func resolveEdit(_ event: CalendarEvent) {
        if let seriesEvent = reminderService.seriesEvent(for: event) {
            navigation = .addEvent(editing: seriesEvent)
        } else {
            navigation = .addEvent(editing: event)
        }
    }

    private func handleDelete(_ event: CalendarEvent) {
        let deletedEvent = event
        reminderService.removeLocalEvent(id: event.id)
        toastState.showSuccess("\u{201C}\(deletedEvent.title)\u{201D} deleted", icon: "trash.fill") {
            reminderService.addLocalEvent(deletedEvent)
        }
        notifyScheduleChange()
    }

    private func notifyScheduleChange(deleted eventId: String? = nil, created: Bool = false) {
        optimizerService.suggestionEngine?.evaluate()
        // Fire reactive triggers
        if let eventId {
            Task {
                await optimizerService.triggerEngine?.onEventDeleted(eventId: eventId)
            }
        }
        if created {
            Task {
                await optimizerService.triggerEngine?.onNewEvent(eventId: "")
            }
        }
    }

    // MARK: - Convert to Pomodoro
    //
    // Direct mutation with smart defaults — no form. The user clicks
    // "Convert to Pomodoro" in the row's context menu and the event is
    // immediately converted to a Pomodoro session sized for its current
    // duration (see `PomodoroDefaults.suggested(for:)`). An undo toast
    // restores the original event in one click.
    //
    // HIG/Birman: don't open a form for a transformation the machine can
    // do correctly on its own. The user only needs to confirm or undo.
    private func convertEventToPomodoro(_ event: CalendarEvent) {
        let originalSnapshot = event
        let durationMinutes = max(0, Int(event.endDate.timeIntervalSince(event.startDate) / 60))
        let defaults = PomodoroDefaults.suggested(for: durationMinutes)

        var converted = event
        converted.eventType = .pomodoro
        // Pomodoro events store the *first segment* in start/end; the
        // recurrence rule expands the rest. Mirrors `buildPomodoroRule`
        // / Pomodoro save logic in AddEventView.
        converted.endDate = event.startDate.addingTimeInterval(TimeInterval(defaults.work * 60))
        converted.recurrenceRule = RecurrenceRule(
            frequency: .minutely,
            interval: defaults.cycleMinutes,
            end: .afterCount(defaults.rounds),
            pomodoroMode: true,
            pomodoroLongBreak: defaults.longBreak
        )

        Haptics.impact()
        reminderService.updateLocalEvent(converted)

        // Toast message reads as one human sentence: "Pomodoro: 4 × 25 min".
        // The undo restores the original event verbatim — eventType,
        // endDate, recurrenceRule — by re-applying the snapshot.
        toastState.showSuccess(
            "Pomodoro: \(defaults.rounds) \u{00D7} \(defaults.work)\u{00A0}min",
            icon: "timer",
            onUndo: { [reminderService] in
                reminderService.updateLocalEvent(originalSnapshot)
            }
        )
    }

    /// Create a focus block directly in the given slot, bypassing the optimizer.
    /// Same pattern as handleTaskDrop — direct event creation + undo toast.
    private func fillSlotWithFocus(start: Date, end: Date) {
        Haptics.tap()
        let eventId = "focus-\(UUID().uuidString)"
        let event = CalendarEvent(
            id: eventId,
            title: "Focus Time",
            startDate: start,
            endDate: end,
            location: nil,
            description: nil,
            calendarName: nil,
            eventType: .standard,
            colorTag: .blue
        )
        reminderService.addLocalEvent(event)

        let fmt = DateFormatter()
        fmt.setLocalizedDateFormatFromTemplate("H:mm")
        toastState.showSuccess(
            "Focus \(fmt.string(from: start))–\(fmt.string(from: end))",
            icon: "sparkles"
        ) {
            reminderService.removeLocalEvent(id: eventId)
        }
        notifyScheduleChange(created: true)
    }

    /// Reschedule overdue tasks into a free slot.
    /// Removes old events, creates new ones packed from slot start, registers batch undo.
    private func rescheduleOverdue(into start: Date, end: Date) {
        guard let backlog = optimizerService.backlogService else { return }
        Haptics.tap()

        let slotDuration = end.timeIntervalSince(start)
        // Pick overdue tasks sorted by deadline (soonest first), fitting into the slot.
        let sorted = backlog.overdue.sorted {
            ($0.deadline ?? .distantFuture) < ($1.deadline ?? .distantFuture)
        }
        var remaining = slotDuration
        var toReschedule: [BacklogTask] = []
        for task in sorted {
            let dur = TimeInterval(task.durationMinutes * 60)
            guard dur <= remaining else { continue }
            toReschedule.append(task)
            remaining -= dur
        }
        guard !toReschedule.isEmpty else { return }

        // Remove old events, create new ones packed sequentially from slot start.
        struct Snapshot { let task: BacklogTask; let oldEventId: String?; let newEventId: String }
        var snapshots: [Snapshot] = []
        var cursor = start
        for task in toReschedule {
            let oldEventId = task.scheduledEventId
            // Manual reschedule collapses multi-chunk layouts back into a
            // single slot, so every prior chunk has to be cleared — not
            // just the primary one `scheduledEventId` points at.
            for eid in task.scheduledEventIds {
                reminderService.removeLocalEvent(id: eid)
            }
            if let old = oldEventId, !task.scheduledEventIds.contains(old) {
                reminderService.removeLocalEvent(id: old)
            }

            let dur = TimeInterval(task.durationMinutes * 60)
            let newEventId = "task-\(task.id)"
            let event = CalendarEvent(
                id: newEventId,
                title: task.title,
                startDate: cursor,
                endDate: cursor.addingTimeInterval(dur),
                location: nil,
                description: nil,
                calendarName: nil,
                eventType: .standard,
                colorTag: .green
            )
            reminderService.addLocalEvent(event)
            backlog.markScheduled(id: task.id, eventId: newEventId, date: cursor)
            snapshots.append(Snapshot(task: task, oldEventId: oldEventId, newEventId: newEventId))
            cursor = cursor.addingTimeInterval(dur)
        }

        let count = toReschedule.count
        toastState.showSuccess(
            "Rescheduled \(count) task\(count == 1 ? "" : "s")",
            icon: "arrow.uturn.forward"
        ) {
            // Undo: remove new events, restore old events and scheduled state
            for snap in snapshots {
                reminderService.removeLocalEvent(id: snap.newEventId)
                if let old = snap.oldEventId {
                    // Restore the original event if we removed it
                    let original = CalendarEvent(
                        id: old,
                        title: snap.task.title,
                        startDate: snap.task.scheduledDate ?? start,
                        endDate: (snap.task.scheduledDate ?? start).addingTimeInterval(TimeInterval(snap.task.durationMinutes * 60)),
                        location: nil,
                        description: nil,
                        calendarName: nil,
                        eventType: .standard,
                        colorTag: .green
                    )
                    reminderService.addLocalEvent(original)
                }
                backlog.markScheduled(
                    id: snap.task.id,
                    eventId: snap.oldEventId ?? snap.newEventId,
                    date: snap.task.scheduledDate ?? start
                )
            }
        }
        notifyScheduleChange(created: true)
    }

    // MARK: - Inline Backlog

    /// Backlog section for embedding in the main timeline.
    /// Manages its own horizontal padding — do NOT wrap in additional padding.
    @ViewBuilder
    private func inlineBacklog(autoExpand: Bool = false) -> some View {
        if let backlog = optimizerService.backlogService {
            BacklogView(
                backlogService: backlog,
                optimizerService: optimizerService,
                reminderService: reminderService,
                onDeleteTask: { task in
                    let originalIndex = backlog.indexOfTask(id: task.id)
                    _ = backlog.removeTask(id: task.id)
                    toastState.showSuccess("\u{201C}\(task.title)\u{201D} deleted", icon: "trash.fill") {
                        backlog.restoreTask(task, at: originalIndex)
                    }
                },
                onEditTask: { task in
                    navigation = .editTask(task)
                },
                onEnterFullscreen: {
                    navigation = .backlog
                },
                onUndoableAction: { message, undo in
                    // Unified undo pipe for reorder / complete / context
                    // moves. Icon stays neutral ("arrow.uturn.backward") so
                    // the same toast reads as "you can undo this" across
                    // different action kinds.
                    toastState.showSuccess(message, icon: "arrow.uturn.backward", onUndo: undo)
                },
                focusRequested: $focusTaskInput,
                autoExpand: autoExpand
            )
        }
    }

    /// Handle a backlog task being dropped onto a free slot.
    /// Creates a calendar event at the slot time and marks the task as scheduled.
    private func handleTaskDrop(drag: BacklogTaskDrag, slotStart: Date, slotEnd: Date) {
        guard let backlog = optimizerService.backlogService,
              let task = backlog.tasks.first(where: { $0.id == drag.taskId }) else { return }

        // Flip the discoverability hint off — this is a real drag-to-schedule,
        // so the user has learned the gesture. Same AppStorage key that
        // BacklogView reads via @AppStorage.
        UserDefaults.standard.set(true, forKey: "BuboBacklogHasDragged")

        // End the drag session cleanly so free-slot pulses stop immediately
        // — even if the drag-preview lifecycle callback hasn't fired yet.
        backlogCoordinator.endDrag()

        // Full pre-drop snapshot — `unschedule` sets status=.pending and
        // drops both scheduledEventId/scheduledDate. If the task was
        // already `.scheduled` against a *different* event (re-scheduling
        // via drag), straight unschedule would lose that prior binding.
        // `updateTask(snapshot)` restores every field exactly.
        let taskSnapshot = task

        let duration = min(
            TimeInterval(task.durationMinutes * 60),
            slotEnd.timeIntervalSince(slotStart)
        )
        let eventId = "task-\(task.id)"
        let event = CalendarEvent(
            id: eventId,
            title: task.title,
            startDate: slotStart,
            endDate: slotStart.addingTimeInterval(duration),
            location: nil,
            description: nil,
            calendarName: nil,
            eventType: .standard,
            colorTag: .green
        )
        // Clean up any prior chunks so the drag collapses a multi-slot
        // layout into the single new slot rather than leaving orphans.
        for eid in task.scheduledEventIds where eid != eventId {
            reminderService.removeLocalEvent(id: eid)
        }
        reminderService.addLocalEvent(event)
        backlog.markScheduled(id: task.id, eventId: eventId, date: slotStart)

        let fmt = DateFormatter()
        fmt.setLocalizedDateFormatFromTemplate("H:mm")
        toastState.showSuccess(
            "\(task.title) → \(fmt.string(from: slotStart))",
            icon: "calendar.badge.plus"
        ) {
            // Undo: remove the event we just created and restore the
            // task's full pre-drop state (status, scheduledEventId,
            // scheduledDate, etc.). `updateTask(snapshot)` is a clean
            // reverse of `markScheduled` because every mutable field is
            // set back to its pre-drop value. notifyScheduleChange with
            // the event id poke the optimizer's trigger engine so it
            // sees the rollback.
            reminderService.removeLocalEvent(id: eventId)
            backlog.updateTask(taskSnapshot)
            notifyScheduleChange(deleted: eventId)
        }
        notifyScheduleChange()
    }

    // MARK: - Main Content

    private var mainContent: some View {
        ScrollViewReader { scrollProxy in
        VStack(alignment: .leading, spacing: 0) {
            PopoverHeader(
                title: dayProgressTitle,
                trailing: AnyView(
                    HStack(spacing: DS.Spacing.sm) {
                        statusIndicators

                        if isScrolledFromTop {
                            Button {
                                Haptics.tap()
                                withAnimation(DS.Animation.smoothSpring) {
                                    scrollProxy.scrollTo("eventListTop", anchor: .top)
                                }
                                Task {
                                    try? await Task.sleep(for: .milliseconds(400))
                                    withAnimation(DS.Animation.smoothSpring) {
                                        scrollPositionID = nil
                                    }
                                }
                            } label: {
                                Image(systemName: "arrow.up")
                                    .font(.system(size: DS.Size.iconSmall, weight: .semibold))
                                    .foregroundStyle(skin.resolvedTextSecondary)
                            }
                            .buttonStyle(.borderless)
                            .help("Scroll to top")
                            .accessibilityLabel("Scroll to top")
                            .transition(.scale.combined(with: .opacity))
                        }
                    }
                )
            )

            // Status messages — show at most one banner to avoid stacking (HIG: keep primary content visible)
            if !networkMonitor.isConnected {
                StatusBanner(
                    icon: "wifi.slash",
                    text: "No internet — calendar data may be outdated",
                    color: skin.resolvedWarningColor
                )
            } else if !permissionBannerSpecs.isEmpty {
                PermissionBannersCarousel(specs: permissionBannerSpecs)
                    .frame(maxWidth: .infinity, alignment: .center)
            } else if reminderService.isUsingCache {
                StatusBanner(
                    icon: "arrow.triangle.2.circlepath",
                    text: "Showing cached data",
                    color: skin.resolvedWarningColor
                )
                .frame(maxWidth: .infinity, alignment: .center)
            } else if let error = reminderService.syncError, settings.isCalendarSyncEnabled, networkMonitor.isConnected {
                StatusBanner(icon: "exclamationmark.triangle.fill", text: error, color: skin.resolvedWarningColor)
                    .frame(maxWidth: .infinity, alignment: .center)
            }

            // World Clock — only show when user has cities configured
            if !settings.worldClockCityIDs.isEmpty {
                WorldClockStripView(settings: settings)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // Filter bar — show whenever the timeline has anything to filter.
            // Color dots inside are still gated on `usedColorTags`, but the
            // free-slot toggle (hollow circle) needs to be reachable even when
            // no event is color-tagged, so users can hide / isolate the
            // "Free · Xh" rows on a plain calendar.
            if reminderService.nonDisintegratingEventCount > 0 {
                colorFilterBar
            }

            // Quick actions card — chips live in their own platter so
            // the main content area reads as a stack of grouped cards
            // (iOS Settings / macOS System Settings pattern), every one
            // of them at contentMargin from the popover edges.
            if reminderService.nonDisintegratingEventCount > 0 {
                QuickActions(
                    optimizerService: optimizerService,
                    reminderService: reminderService,
                    onExecuted: { label, undo in
                        toastState.showSuccess(label, icon: "sparkles", onUndo: undo)
                        notifyScheduleChange()
                    },
                    onError: { message in
                        toastState.showInfo(message, icon: "exclamationmark.triangle")
                    },
                    onOpenPalette: {
                        Haptics.tap()
                        withAnimation(DS.Animation.quick) {
                            paletteContext = PaletteContext()
                        }
                    }
                )
                .padding(.vertical, DS.Spacing.sm)
                .padding(.horizontal, DS.Spacing.sm)
                .frame(maxWidth: .infinity, alignment: .leading)
                .skinPlatter(activeSkin)
                .skinPlatterDepth(skin)
                // Preference key sits AFTER platter/depth but BEFORE the
                // outer padding so the command palette anchors to the
                // card's bottom edge (shadow included) rather than to
                // the outer gap below it.
                .background(
                    GeometryReader { geo in
                        Color.clear.preference(
                            key: OptimizerBottomKey.self,
                            value: geo.frame(in: .named(menuBarRootCoordinateSpace)).maxY
                        )
                    }
                )
                .padding(.horizontal, DS.Spacing.contentMargin)
                .padding(.top, DS.Spacing.md)
            }

            // Backlog card — always rendered so the "+ Add task…" input
            // stays as a persistent visual anchor even when the backlog
            // is empty. The chrome itself lives on `.skinTasksBlockChrome`
            // — same modifier the fullscreen Backlog uses, so the block
            // reads as one recognizable surface in both collapsed-on-main
            // and fullscreen states.
            inlineBacklog(autoExpand: reminderService.nonDisintegratingEventCount == 0)
                .frame(maxWidth: .infinity, alignment: .leading)
                .skinTasksBlockChrome(activeSkin)
                .padding(.horizontal, DS.Spacing.contentMargin)
                .padding(.top, DS.Spacing.md)

            // Thin separator between the Backlog card above and the
            // flat Timeline area below. Matches the visual role of
            // the SkinSeparator above the footer: a quiet one-pixel
            // rule that signals "this is where one region ends and
            // the next one begins", without reintroducing a heavy
            // card container around the Timeline. Inset by
            // `contentMargin` so it aligns with the Backlog card
            // edges above and the content axis of the Timeline below.
            // Vertical `md` top padding preserves the existing
            // Backlog → Timeline gap; the LazyVStack's own internal
            // top padding takes care of the gap below the separator.
            SkinSeparator()
                .padding(.horizontal, DS.Spacing.contentMargin)
                .padding(.top, DS.Spacing.md)

            // Events — fill remaining space so header stays pinned.
            // Timeline is intentionally NOT wrapped in a platter card:
            // it's the primary content area, and HIG canonical macOS
            // patterns (Mail message list, Finder file list, Calendar
            // event list, Reminders) put primary content directly on
            // the window surface rather than inside a nested card.
            // Cards are reserved for the secondary blocks above
            // (QuickActions, Backlog) which act like grouped-list
            // sections; Timeline fills the main area directly so it
            // reads as "the screen" rather than "one of the sections".
            // Individual event rows stay flat (no per-row platter
            // background) — also the native macOS List convention.
            Group {
                if reminderService.nonDisintegratingEventCount == 0 {
                    emptyState
                } else if filteredEventsByDay.isEmpty {
                    VStack(spacing: DS.Spacing.sm) {
                        Text(emptyFilteredStateMessage)
                            .font(.subheadline)
                            .foregroundStyle(skin.resolvedTextSecondary)
                        Button("Clear filter") {
                            colorFilter = nil
                            freeSlotFilter = .all
                        }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    eventList
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .animation(DS.Animation.smoothSpring, value: reminderService.nonDisintegratingEventCount == 0)

            SkinSeparator()
            footerActions
        }
        } // ScrollViewReader
    }

    // MARK: - Subviews

    private var statusIndicators: some View {
        HStack(spacing: DS.Spacing.sm) {
            if !networkMonitor.isConnected {
                Image(systemName: "wifi.slash")
                    .foregroundStyle(skin.resolvedDestructiveColor)
                    .font(.system(size: DS.Size.iconSmall))
                    .symbolEffect(.pulse, options: .repeating.speed(0.5))
                    .help("No internet connection")
                    .accessibilityLabel("No internet connection")
                    .transition(.scale.combined(with: .opacity))
            }

            if reminderService.isSyncing {
                ProgressView()
                    .controlSize(.mini)
                    .frame(width: DS.Size.syncIndicatorSize, height: DS.Size.syncIndicatorSize)
                    .transition(.scale.combined(with: .opacity))
            }
        }
        .animation(skin.resolvedMicroAnimation, value: networkMonitor.isConnected)
        .animation(skin.resolvedMicroAnimation, value: reminderService.isSyncing)
    }

    /// Dynamic header title showing today's progress and time until next event.
    private var dayProgressTitle: String {
        let cal = Calendar.current
        let now = Date()
        guard let todayGroup = reminderService.eventsByDay.first(where: { cal.isDateInToday($0.date) }) else {
            return "Bubo"
        }
        let todayEvents = todayGroup.events.filter { !reminderService.disintegratingEventIDs.contains($0.id) }
        let total = todayEvents.count
        guard total > 0 else { return "Bubo" }
        let done = todayEvents.filter { $0.endDate <= now }.count

        // Time until next upcoming event
        let nextSuffix: String = {
            guard let next = todayEvents.first(where: { $0.startDate > now }) else { return "" }
            let mins = Int(next.startDate.timeIntervalSince(now)) / 60
            if mins < 1 { return " \u{00B7} now" }
            if mins < 60 { return " \u{00B7} in\u{00A0}\(mins)\u{00A0}min" }
            let h = mins / 60
            let m = mins % 60
            if m == 0 { return " \u{00B7} in\u{00A0}\(h)\u{00A0}h" }
            return " \u{00B7} in\u{00A0}\(h)\u{00A0}h\u{00A0}\(m)\u{00A0}min"
        }()

        if done == 0 { return "\(total)\u{00A0}events today\(nextSuffix)" }
        if done == total { return "All\u{00A0}\(total) done" }
        return "\(done)\u{00A0}of\u{00A0}\(total)\(nextSuffix)"
    }

    /// Context-aware subtitle for the empty state.
    private var emptyStateSubtitle: String {
        let cal = Calendar.current
        let now = Date()

        // Check if there are any future events across all days (including ones currently filtered out by the time window)
        let allUpcoming = reminderService.allEvents
            .filter { $0.startDate > now }
            .sorted { $0.startDate < $1.startDate }

        if let next = allUpcoming.first {
            let interval = next.startDate.timeIntervalSince(now)
            let hours = Int(interval / 3600)
            let minutes = Int(interval / 60) % 60

            if cal.isDateInToday(next.startDate) {
                if hours > 0 {
                    return "Next: \(next.title) in\u{00A0}\(hours)\u{00A0}h\u{00A0}\(minutes)\u{00A0}min"
                }
                return "Next: \(next.title) in\u{00A0}\(minutes)\u{00A0}min"
            } else if cal.isDateInTomorrow(next.startDate) {
                let fmt = DateFormatter()
                fmt.dateFormat = "H:mm"
                return "Tomorrow: \(next.title) at\u{00A0}\(fmt.string(from: next.startDate))"
            } else {
                let fmt = DateFormatter()
                fmt.setLocalizedDateFormatFromTemplate("EEE")
                return "Next: \(next.title) on\u{00A0}\(fmt.string(from: next.startDate))"
            }
        }

        return "No upcoming events"
    }

    private var emptyState: some View {
        ScrollView {
            VStack(spacing: 0) {
                if pendingTaskCount > 0 {
                    // Tasks exist (pinned above) — keep the "no events" note
                    // compact so tasks dominate the screen.
                    HStack(spacing: DS.Spacing.sm) {
                        Image(systemName: "calendar")
                            .font(.footnote)
                            .foregroundStyle(skin.resolvedTextTertiary)
                        Text(emptyStateSubtitle)
                            .font(.footnote)
                            .foregroundStyle(skin.resolvedTextTertiary)
                        Spacer()
                        Button {
                            Haptics.tap()
                            navigation = .addEvent()
                        } label: {
                            Text("Add Event")
                                .font(.footnote.weight(.medium))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(skin.accentColor)
                    }
                    .padding(.horizontal, DS.Spacing.lg)
                    .padding(.vertical, DS.Spacing.lg)
                } else {
                    // Birman: emptiness is information too — show it quietly.
                    // No pulsing icon, no radial glow, no ceremony.
                    VStack(spacing: DS.Spacing.sm) {
                        Text("All clear")
                            .font(.headline)
                            .fontWeight(skin.resolvedHeadlineFontWeight)
                            .foregroundStyle(skin.resolvedTextPrimary)
                        Text(emptyStateSubtitle)
                            .font(.subheadline)
                            .foregroundStyle(skin.resolvedTextSecondary)
                            .lineLimit(1)
                            .truncationMode(.tail)

                        Button {
                            Haptics.tap()
                            navigation = .addEvent()
                        } label: {
                            Label("Add Event", systemImage: "plus")
                                .font(.footnote)
                                .fontWeight(.medium)
                        }
                        .buttonStyle(.action(role: .primary, size: .compact))
                        .padding(.top, DS.Spacing.md)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, DS.Spacing.xxl)
                }
            }
        }
        .scrollContentBackground(.hidden)
        .transition(.opacity.combined(with: .scale(scale: 0.95)))
    }

    /// Permissions banners shown in the popover header. Order matches a
    /// stable left-to-right reading order: Calendar first, Reminders next.
    /// When more than one entry exists, `PermissionBannersCarousel`
    /// turns into a horizontal pager.
    private var permissionBannerSpecs: [PermissionBannerSpec] {
        var specs: [PermissionBannerSpec] = []
        if settings.isCalendarSyncEnabled && !calendarHasAccess {
            specs.append(.calendar)
        }
        if settings.isRemindersSyncEnabled && !remindersHasAccess {
            specs.append(.reminders)
        }
        return specs
    }

    /// Re-reads the EventKit permission snapshots into `@State`. Called on
    /// appear and whenever the services post `authorizationDidChange`, so
    /// the banner reflects access changes from both the in-app Connect
    /// button and System Settings while the popover is open.
    ///
    /// Never downgrades a known grant to `.notDetermined` — the static
    /// EventKit query is occasionally stale right after a grant (TCC
    /// propagation lag on the shared store), and `.notDetermined` isn't
    /// reachable from `.fullAccess` without the user revoking via
    /// System Settings, which the OS reports as `.denied`. Mirrors the
    /// same guard in `SettingsViewModel.refreshRemindersAuthStatus`.
    private func refreshPermissionSnapshots() {
        let calendarStatus = AppleCalendarService.authorizationStatus
        let remindersStatus = AppleRemindersService.authorizationStatus
        let calendar = (calendarHasAccess && calendarStatus == .notDetermined)
            ? true
            : calendarStatus == .fullAccess
        let reminders = (remindersHasAccess && remindersStatus == .notDetermined)
            ? true
            : remindersStatus == .fullAccess
        if calendarHasAccess != calendar { calendarHasAccess = calendar }
        if remindersHasAccess != reminders { remindersHasAccess = reminders }
    }

    private var usedColorTags: [EventColorTag] {
        let allEvents = reminderService.eventsByDay.flatMap(\.events)
        let usedTags = Set(allEvents.compactMap(\.colorTag))
        return EventColorTag.allCases.filter { usedTags.contains($0) }
    }

    private var colorFilterBar: some View {
        let selected = colorFilter
        let anyFilter = selected != nil || freeSlotFilter.isActive
        return HStack(spacing: DS.Spacing.xs) {
            ForEach(EventColorTag.allCases, id: \.self) { tag in
                ColorDotButton(
                    tag: tag,
                    isActive: selected == tag,
                    isDimmed: anyFilter && selected != tag
                ) {
                    Haptics.tap()
                    withAnimation(skin.resolvedMicroAnimation) {
                        freeSlotFilter = .all
                        colorFilter = (colorFilter == tag) ? nil : tag
                    }
                }
            }

            // Hollow dot cycles through three free-slot filter states.
            // Mutually exclusive with the color filters above so the two
            // modes never fight each other.
            FreeSlotDotButton(
                state: freeSlotFilter,
                isDimmed: anyFilter && !freeSlotFilter.isActive
            ) {
                Haptics.tap()
                withAnimation(skin.resolvedMicroAnimation) {
                    colorFilter = nil
                    freeSlotFilter = freeSlotFilter.next()
                }
            }

            if anyFilter {
                Button {
                    Haptics.tap()
                    withAnimation(skin.resolvedMicroAnimation) {
                        colorFilter = nil
                        freeSlotFilter = .all
                    }
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12, weight: skin.resolvedSymbolWeight, design: skin.resolvedFontDesign))
                        .symbolRenderingMode(skin.resolvedSymbolRendering)
                        .foregroundStyle(skin.resolvedTextTertiary)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Clear filter")
                .transition(.scale.combined(with: .opacity))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, DS.Spacing.md)
        .frame(height: DS.Size.controlHeight)
        .skinPlatter(activeSkin)
        .skinPlatterDepth(skin)
        // Level 1: unified outer content margin — aligns with header,
        // footer, quick actions and the event list.
        .padding(.horizontal, DS.Spacing.contentMargin)
        .padding(.vertical, DS.Spacing.xs)
        .animation(skin.resolvedMicroAnimation, value: colorFilter)
        .animation(skin.resolvedMicroAnimation, value: freeSlotFilter)
    }

    /// Empty-state copy when the active filter combo prunes everything.
    /// Keyed off whichever filter is the user's last action — matches the
    /// matching "clear filter" affordance shown alongside.
    private var emptyFilteredStateMessage: String {
        switch freeSlotFilter {
        case .onlyFree: return "No free slots in working hours"
        case .hideFree: return "No events scheduled"
        case .all: return "No events with this color"
        }
    }

    /// Parallax fraction applied to `listScrollY` before it reaches the
    /// wallpaper. 0.15 was tuned by hand: noticeably alive without
    /// inducing the dizzying «UI is sliding under glass» feel that comes
    /// with values past ~0.25. Returns 0 when Reduce Motion is on or
    /// when the user is not on the list view (so navigating away resets
    /// the wallpaper to its calm position).
    private var parallaxOffset: CGFloat {
        guard navigation == .list, !reduceMotion else { return 0 }
        let raw = listScrollY * 0.15
        // Clamp absolute parallax to ±40pt so even a long backlog scroll
        // never drives the wallpaper outside the 8% overscan margin
        // baked into `WallpaperBackgroundLayer.parallaxOverscan`.
        return max(-40, min(40, raw))
    }

    private var eventList: some View {
        ScrollView {
            // Timeline is not a platter card (see mainContent), so this
            // LazyVStack owns its own horizontal margin via
            // `contentMargin` — putting event rows, day headers, and
            // smart banners on the same 16pt vertical axis as the
            // QuickActions card, the Backlog card, the header, and the
            // footer. Gestalt: outer space (between day groups) > inner
            // space (row to row inside a day) — handled by the `lg`
            // sibling spacing plus a SkinSeparator between groups.
            LazyVStack(alignment: .leading, spacing: DS.Spacing.lg) {
                // One banner at a time — energy check-in when pending,
                // otherwise optimizer suggestion. §2: density, not stacking.
                if optimizerService.energyCheckInService?.pendingCheckIn == true {
                    EnergyCheckInBanner(
                        onRecord: { level in
                            withAnimation(DS.Animation.quick) {
                                optimizerService.energyCheckInService?.record(
                                    energyLevel: level,
                                    from: reminderService
                                )
                            }
                        },
                        onDismiss: {
                            withAnimation(DS.Animation.quick) {
                                optimizerService.energyCheckInService?.dismissCheckIn()
                            }
                        }
                    )
                } else if let suggestion = activeBannerSuggestion {
                    SmartBanner(
                        request: suggestion.request,
                        reason: suggestion.reason,
                        onRun: {
                            runQuickAction(suggestion.request, label: suggestion.reason)
                        },
                        onDismiss: {
                            withAnimation(DS.Animation.quick) {
                                optimizerService.suggestionEngine?.suggestion = nil
                            }
                        }
                    )
                }

                // Once-per-user drag-onboarding lives on the first free slot
                // of the earliest day group, and only while the backlog
                // actually has something to drag. See
                // `FreeSlotRow.canShowDragHint`.
                let backlogHasPending = !(optimizerService.backlogService?.pending.isEmpty ?? true)
                let firstDayDate = filteredEventsByDay.first?.date
                ForEach(filteredEventsByDay, id: \.date) { dayGroup in
                    if dayGroup.date != firstDayDate {
                        // Inset by `sm` so the divider sits between day
                        // groups without running all the way to the
                        // popover edges — matches native macOS List
                        // section dividers inside a scrollable area.
                        SkinSeparator()
                    }
                    dayGroupSection(
                        dayGroup,
                        showDragHintOnFirstSlot: backlogHasPending && dayGroup.date == firstDayDate
                    )
                }
            }
            .padding(.horizontal, DS.Spacing.contentMargin)
            .padding(.vertical, DS.Spacing.md)
            .scrollTargetLayout()
            .id("eventListTop")
            .animation(DS.Animation.smoothSpring, value: reminderService.disintegratingEventIDs)
            // Read the LazyVStack's position inside the scroll view's
            // coordinate space. As the user scrolls down, `minY` grows
            // negative; we feed that straight into `listScrollY`, then
            // `parallaxOffset` applies the dampening + clamp.
            .onGeometryChange(for: CGFloat.self) { proxy in
                proxy.frame(in: .named("eventListScroll")).minY
            } action: { newValue in
                listScrollY = newValue
            }
        }
        .coordinateSpace(.named("eventListScroll"))
        .scrollPosition(id: $scrollPositionID)
        .scrollContentBackground(.hidden)
    }

    // MARK: - Day Group Section (extracted for release-mode type checker)

    @ViewBuilder
    private func dayGroupSection(
        _ dayGroup: (date: Date, events: [CalendarEvent]),
        showDragHintOnFirstSlot: Bool = false
    ) -> some View {
        let visibleCount = visibleEventCount(for: dayGroup.events)

        DaySectionHeader(date: dayGroup.date, count: visibleCount)
            // `sm` leading keeps the day title hanging 8pt out from the
            // first event's accent bar — same column as the free-slot
            // dashed guide. Level 1: top padding is now applied by the
            // SkinSeparator above instead of this header, so the
            // outer-between-groups space (LazyVStack spacing `lg` +
            // separator) stays bigger than the inner space to the first
            // event of the day.
            .padding(.horizontal, DS.Spacing.sm)

        // Filter interaction:
        // • colorFilter active → events already pruned to one tag, so the
        //   remaining "gaps" are filled by events of other colors in the real
        //   timeline. Rendering them as Free slots would be misleading, so
        //   hide them.
        // • freeSlotFilter == .onlyFree → hide events entirely and show only
        //   the real free slots, so users can eyeball open time at a glance.
        // • freeSlotFilter == .hideFree → keep events, suppress the
        //   "Free · Xh" rows so a busy day reads as a compact list.
        let shouldComputeFreeSlots = colorFilter == nil && freeSlotFilter != .hideFree
        let freeSlots: [(start: Date, end: Date)] = shouldComputeFreeSlots
            ? FreeSlotFinder.slots(
                for: dayGroup.events,
                on: dayGroup.date,
                workingHours: optimizerService.workingHours
            )
            : []

        let ghost = ghostForDay(dayGroup.date)
        let interleaved = interleave(
            events: dayGroup.events,
            freeSlots: freeSlots,
            ghost: ghost,
            includeEvents: freeSlotFilter != .onlyFree
        )
        // Pick the first `.slot` item's id inside this day — only that row
        // gets the onboarding hint. Precomputing keeps the ForEach body a
        // pure function of the item and avoids per-iteration scanning.
        let hintSlotId: String? = showDragHintOnFirstSlot
            ? interleaved.first(where: { if case .slot = $0 { return true } else { return false } })?.id
            : nil

        // During a backlog-task drag, events are not valid drop targets.
        // Collapse them into a single «N events · Xh booked» header so the
        // free slots (the real targets) and the expanded task list above
        // share the vertical space. One header > N thin slivers — Бирман:
        // «свернуть в строку-заголовок, а не уменьшать всё пропорционально».
        if backlogCoordinator.isDraggingTask && !dayGroup.events.isEmpty && freeSlotFilter != .onlyFree {
            collapsedEventsHeader(for: dayGroup.events)
        }

        ForEach(interleaved, id: \.id) { item in
            switch item {
            case .event(let event):
                // Skip per-event rendering while a task is being dragged;
                // the summary header above stands in for the whole group.
                if backlogCoordinator.isDraggingTask {
                    EmptyView()
                } else {
                EventRowView(
                    event: event,
                    reminderService: reminderService,
                    onEdit: { event in resolveEdit(event) },
                    onDelete: { event in handleDelete(event) },
                    onDeleteOccurrence: { event in
                        reminderService.excludeOccurrence(occurrenceId: event.id)
                        toastState.showSuccess("\u{201C}\(event.title)\u{201D} removed", icon: "trash.fill")
                    },
                    onDeleteSeries: { event in
                        let seriesId = event.seriesId ?? event.id
                        reminderService.removeLocalEvent(id: seriesId)
                        toastState.showSuccess("All \u{201C}\(event.title)\u{201D} deleted", icon: "trash.fill")
                    },
                    onTap: { event in
                        navigation = .detail(event)
                    },
                    onCompleteTask: { event in
                        var completed = event
                        completed.taskStatus = .done
                        completed.completedAt = Date()
                        reminderService.updateLocalEvent(completed)
                        toastState.showSuccess("Task completed", icon: "checkmark.circle.fill")
                    },
                    onFindBetterTime: { event in
                        withAnimation(DS.Animation.quick) {
                            paletteContext = PaletteContext(seedEvent: event)
                        }
                    },
                    onSplitTask: { _ in
                        withAnimation(DS.Animation.quick) {
                            paletteContext = PaletteContext(seedRecipeId: "split-task")
                        }
                    },
                    onProtectBlock: { event in
                        let request = OptimizationRequest(
                            .keepFixed(eventIds: [event.id]),
                            .horizon(.today), .speed(.quick), .scenarios(count: 1),
                            name: "Protect Block"
                        )
                        Task {
                            _ = await optimizerService.executeRequest(request, reminderService: reminderService)
                            toastState.showSuccess("Focus block protected", icon: "shield.fill")
                        }
                    },
                    onAddPrep: { event in
                        withAnimation(DS.Animation.quick) {
                            paletteContext = PaletteContext(seedEvent: event, seedRecipeId: "prep-meeting")
                        }
                    },
                    onConvertToPomodoro: { event in
                        convertEventToPomodoro(event)
                    },
                    isFreshlyCreated: optimizerService.freshlyCreatedEventIds.contains(event.id)
                )
                }
            case .slot(let start, let end):
                // Ghost suppression: when the shared coordinator already
                // has a ghost block starting at this slot's start (user
                // is hovering a dragged task over it, or typing into the
                // backlog input) — skip the "Free · Xh" row so we don't
                // double-render the same time as two rows.
                if let ghost, ghost.start == start {
                    EmptyView()
                } else {
                    FreeSlotRow(
                        start: start,
                        end: end,
                        onFillTapped: { _ in
                            let backlog = optimizerService.backlogService
                            let hasPending = !(backlog?.pending.isEmpty ?? true)
                            let hasOverdue = !(backlog?.overdue.isEmpty ?? true)

                            if !hasPending && !hasOverdue {
                                // No tasks at all → direct focus fill.
                                fillSlotWithFocus(start: start, end: end)
                            } else if !hasPending && hasOverdue {
                                // Only overdue → reschedule directly, no palette.
                                rescheduleOverdue(into: start, end: end)
                            } else {
                                // Pending tasks (maybe overdue too) → show palette for choice.
                                withAnimation(DS.Animation.quick) {
                                    paletteContext = PaletteContext(
                                        seedSlotMinutes: Int(end.timeIntervalSince(start) / 60),
                                        seedSlotStart: start,
                                        seedSlotEnd: end
                                    )
                                }
                            }
                        },
                        onTaskDropped: { drag in
                            handleTaskDrop(drag: drag, slotStart: start, slotEnd: end)
                        },
                        canShowDragHint: item.id == hintSlotId
                    )
                }
            case .ghost(let start, let end, let title):
                GhostEventRow(start: start, end: end, title: title)
                    .transition(.opacity.combined(with: .scale(scale: 0.96)))
            }
        }
    }

    /// One-line collapsed summary of a day's events — rendered in place
    /// of the individual `EventRowView`s while the user is dragging a
    /// backlog task. Free slots remain visible as drop targets, so the
    /// timeline area reduces to «где занято + куда можно положить».
    @ViewBuilder
    private func collapsedEventsHeader(for events: [CalendarEvent]) -> some View {
        let bookedMinutes = events.reduce(0) { acc, event in
            acc + max(0, Int(event.endDate.timeIntervalSince(event.startDate) / 60))
        }
        HStack(spacing: DS.Spacing.sm) {
            // Three stacked hash marks echo the booked-time feel without
            // any one event's title dominating — the whole group reads as
            // a single «block».
            Image(systemName: "rectangle.stack.fill")
                .font(.footnote)
                .foregroundStyle(activeSkin.resolvedTextTertiary)
            Text("\(events.count) event\(events.count == 1 ? "" : "s") · \(DS.formatMinutes(bookedMinutes)) booked")
                .font(.footnote)
                .foregroundStyle(activeSkin.resolvedTextSecondary)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.vertical, DS.Spacing.xs)
        .padding(.horizontal, DS.Spacing.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .transition(.opacity.combined(with: .move(edge: .top)))
        .accessibilityLabel("\(events.count) booked events totalling \(DS.formatMinutes(bookedMinutes))")
    }

    // MARK: - List Items (events + free slots interleaved)

    /// A row in the day list — either a real event, an empty slot, or the
    /// typed-ghost block that previews where a backlog task would land.
    private enum DayListItem: Identifiable {
        case event(CalendarEvent)
        case slot(Date, Date)
        case ghost(Date, Date, String)

        var id: String {
            switch self {
            case .event(let e): return "event:\(e.id)"
            case .slot(let s, let e): return "slot:\(s.timeIntervalSinceReferenceDate)-\(e.timeIntervalSinceReferenceDate)"
            case .ghost(let s, let e, _): return "ghost:\(s.timeIntervalSinceReferenceDate)-\(e.timeIntervalSinceReferenceDate)"
            }
        }
    }

    /// Interleaves events, free-slot pairs, and the optional ghost preview
    /// chronologically so the list reads top-to-bottom like a real timeline.
    private func interleave(
        events: [CalendarEvent],
        freeSlots: [(start: Date, end: Date)],
        ghost: (start: Date, end: Date, title: String)? = nil,
        includeEvents: Bool = true
    ) -> [DayListItem] {
        var result: [DayListItem] = includeEvents ? events.map(DayListItem.event) : []
        result += freeSlots.map { DayListItem.slot($0.start, $0.end) }
        if let ghost {
            result.append(.ghost(ghost.start, ghost.end, ghost.title))
        }
        result.sort { startOf($0) < startOf($1) }
        return result
    }

    private func startOf(_ item: DayListItem) -> Date {
        switch item {
        case .event(let e): return e.startDate
        case .slot(let s, _): return s
        case .ghost(let s, _, _): return s
        }
    }

    /// Ghost payload for the given day, if the coordinator has one and its
    /// start date falls within this day. Returns nil otherwise so the row
    /// is only rendered under the day it actually belongs to.
    private func ghostForDay(_ date: Date) -> (start: Date, end: Date, title: String)? {
        guard let slot = backlogCoordinator.ghostSlot,
              let title = backlogCoordinator.ghostTitle,
              !title.isEmpty,
              Calendar.current.isDate(slot.start, inSameDayAs: date) else {
            return nil
        }
        return (slot.start, slot.end, title)
    }

    // MARK: - Smart Banner

    /// Mapping from `SuggestionEngine.Signal.name` to the set of
    /// `QuickActionCandidate.id`s that surface the same intent in the
    /// QuickActions chip row. The two systems were named independently —
    /// `pending-tasks` here is `schedule-tasks` there — so we keep an
    /// explicit table rather than a brittle name-prefix match.
    ///
    /// Used by `activeBannerSuggestion` below to suppress the banner when
    /// the dynamic ranker has already raised the same recipe to top-3:
    /// otherwise the user sees «4 tasks to schedule [Run]» as both a
    /// chip *and* a banner immediately below the Tasks card, which was
    /// the original «тройной Schedule» complaint.
    private static let suggestionToQuickActionIDs: [String: Set<String>] = [
        "overdue": ["overdue"],
        "urgent": ["deadlines"],
        "meetings-heavy": ["batch-meetings"],
        "pending-tasks": ["schedule-tasks"],
        // Focus has two surface variants in the ranker — the user's own
        // history picks one of them per `focusVariantCandidate()`. Either
        // counts as the same suggestion being shown.
        "no-focus": ["focus", "pomodoro"],
        "organize-morning": ["organize"],
    ]

    /// True when the suggestion's primary contribution is already surfaced
    /// in the top-3 QuickActions chips. We reuse the production
    /// `QuickActionRanker` so suppression follows the same context-aware
    /// scoring the chips do — no risk of the chip and the banner
    /// disagreeing on what's «in the top».
    private func isSuggestionSurfacedInQuickActions(_ suggestion: SuggestionEngine.Suggestion) -> Bool {
        guard let backlog = optimizerService.backlogService else { return false }
        let ranker = QuickActionRanker(
            backlogService: backlog,
            reminderService: reminderService,
            intentLearner: optimizerService.intentLearner
        )
        let topIds = Set(ranker.rank(limit: 3).map(\.action.id))

        for signalName in suggestion.contributions.keys {
            if let actionIds = Self.suggestionToQuickActionIDs[signalName],
               !actionIds.isDisjoint(with: topIds) {
                return true
            }
        }
        return false
    }

    /// The first non-dismissed suggested recipe from the monitor, or nil
    /// when nothing is worth suggesting. Returns nil also when the same
    /// intent is already shown as a top-3 QuickAction — Бирман: «один
    /// CTA, не три», иначе главный экран начинает дублировать сам себя.
    private var activeBannerSuggestion: SuggestionEngine.Suggestion? {
        guard let suggestion = optimizerService.suggestionEngine?.suggestion else { return nil }
        if isSuggestionSurfacedInQuickActions(suggestion) { return nil }
        return suggestion
    }

    /// Execute a request immediately — no palette, no configuration.
    /// One tap → done → undo toast. Birman: "sequential magic."
    private func runQuickAction(_ request: OptimizationRequest, label: String) {
        Task {
            let result = await optimizerService.executeRequest(request, reminderService: reminderService)
            if case .success = result, !optimizerService.scenarios.isEmpty {
                optimizerService.applyScenario(at: 0, to: reminderService)
                toastState.showSuccess(label, icon: "sparkles") {
                    optimizerService.undoLast(reminderService: reminderService)
                }
                notifyScheduleChange()
            } else if let error = result.errorMessage {
                toastState.showInfo(error, icon: "exclamationmark.triangle")
            }
        }
    }

    private var footerActions: some View {
        // Level 4 (final, footer polish): match AddEventView's footer
        // byte-for-byte on the pieces that CAN match without changing
        // semantics. Default HStack spacing (8), no redundant
        // `frame(maxWidth: .infinity)` (HStack + Spacer already flexes
        // to parent width), primary CTA on `.flexible` size so the
        // button is visually dominant — HIG: primary actions should
        // be the most prominent control on screen. The More menu stays
        // `borderlessButton` because it's a utility menu, not a peer
        // to the primary action.
        HStack {
            Menu {
                Button {
                    Haptics.tap()
                    reminderService.syncNow()
                    toastState.showInfo("Refreshing\u{2026}", icon: "arrow.clockwise")
                } label: {
                    Label("Refresh Calendars", systemImage: "arrow.clockwise")
                }
                .keyboardShortcut("r", modifiers: .command)

                OpenSettingsButton()
                    .keyboardShortcut(",", modifiers: .command)
                Divider()
                Button("Quit Bubo", role: .destructive) {
                    NSApplication.shared.terminate(nil)
                }
                .keyboardShortcut("q", modifiers: .command)
            } label: {
                HStack(spacing: DS.Spacing.xs) {
                    Image(systemName: "ellipsis.circle")
                    Text("More")
                }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(skin.resolvedTextSecondary)
            .symbolRenderingMode(.monochrome)
            .tint(activeSkin.resolvedToolbarTint)
            .help("More")

            Spacer()

            // Primary CTA — `.flexible` size (default) = minWidth 100,
            // `lg` internal horizontal padding. Same treatment as
            // AddEventView's Add Event button, so both screens'
            // primary actions carry equal visual weight.
            // Birman: Pomodoro — это режим выполнения фокус-блока, а не
            // отдельный тип объекта. Раньше "New Pomodoro" жил здесь, в
            // одной строке с "New Event" и "New Task", как будто это
            // равноправный объект. Теперь Pomodoro включается toggle'ом
            // внутри формы события — один правильный вход.
            Menu {
                Button {
                    Haptics.tap()
                    navigation = .addEvent()
                } label: {
                    // HIG: surface keyboard shortcut hints in menu items so
                    // users can graduate from clicking to typing.
                    Label("New Event   \u{2318}N", systemImage: "calendar.badge.plus")
                }
                Button {
                    Haptics.tap()
                    focusTaskInput = true
                } label: {
                    Label("New Task   \u{21E7}\u{2318}N", systemImage: "plus.circle")
                }
            } label: {
                Label("Add", systemImage: "plus")
            } primaryAction: {
                Haptics.tap()
                navigation = .addEvent()
            }
            .buttonStyle(.action(role: .primary))
            .help("Add a new event (\u{2318}N)")
            .keyboardShortcut("n", modifiers: .command)
        }
        .padding(.horizontal, DS.Spacing.contentMargin)
        .frame(height: DS.Size.actionFooterHeight)
        .skinBarBackground(activeSkin)
    }
}

// MARK: - Settings Button

private struct OpenSettingsButton: View {
    var iconOnly: Bool = false
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Button {
            Haptics.tap()
            NSApp.keyWindow?.close()
            openSettings()
            NSApp.activate()
        } label: {
            if iconOnly {
                Image(systemName: "gear")
            } else {
                Label("Settings", systemImage: "gear")
            }
        }
    }
}

// MARK: - Permission banners
//
// One banner = a single capsule pill, identical to the previous Calendar
// affordance. Two or more = a horizontal pager with a small dot indicator,
// so the secondary message lives in the same vertical slot as the primary
// one rather than stacking and pushing the day list down.
//
// Apple HIG: surface multiple notices sequentially in one container with a
// discoverable indicator; never stack chrome over primary content.
// Birman: ничего лишнего — пока баннер один, никакого пейджера и точек нет;
// они появляются только когда действительно есть, между чем переключаться.

private struct PermissionBannerSpec: Identifiable, Equatable {
    let id: String
    let icon: String
    let title: LocalizedStringKey
    let accessibilityLabel: String
    let pane: SettingsView.SettingsPane

    static let calendar = PermissionBannerSpec(
        id: "calendar",
        icon: "calendar.badge.exclamationmark",
        title: "Calendar access not granted",
        accessibilityLabel: "Calendar access not granted. Open settings to grant access.",
        pane: .calendars
    )

    static let reminders = PermissionBannerSpec(
        id: "reminders",
        icon: "checklist",
        title: "Reminders access not granted",
        accessibilityLabel: "Reminders access not granted. Open settings to grant access.",
        pane: .appleReminders
    )
}

/// The capsule pill itself. Visual language is preserved verbatim from
/// the original `CalendarAccessBanner` so users who only ever see one
/// banner notice no change.
private struct PermissionBannerLabel: View {
    let spec: PermissionBannerSpec

    @Environment(\.openSettings) private var openSettings
    @Environment(\.activeSkin) private var skin

    var body: some View {
        Button {
            Haptics.tap()
            NSApp.keyWindow?.close()
            SettingsViewModel.pendingPane = spec.pane
            openSettings()
            NSApp.activate()
            NotificationCenter.default.post(
                name: SettingsViewModel.navigateToPaneNotification,
                object: spec.pane
            )
        } label: {
            HStack(spacing: DS.Spacing.sm) {
                Image(systemName: spec.icon)
                    .foregroundStyle(skin.resolvedWarningColor)
                    .font(.footnote)
                    .symbolRenderingMode(.hierarchical)
                Text(spec.title)
                    .font(.footnote)
                    .foregroundStyle(skin.resolvedTextPrimary)
                Spacer(minLength: DS.Spacing.sm)
                Image(systemName: "chevron.right")
                    .font(.footnote)
                    .foregroundStyle(skin.resolvedTextTertiary)
            }
            .padding(.horizontal, DS.Spacing.md)
            .padding(.vertical, DS.Spacing.sm)
            .adaptiveBadgeFill(skin.resolvedWarningColor)
            .clipShape(Capsule())
            // Permission pill rides on the card plane (z1) inside the popover.
            .elevation(.z1, skin: skin)
        }
        .buttonStyle(.plain)
        // Level 1: unified outer content margin so the pill hangs on the
        // same vertical axis as the rest of the popover chrome.
        .padding(.horizontal, DS.Spacing.contentMargin)
        .accessibilityLabel(spec.accessibilityLabel)
    }
}

/// Hosts one or more permission banners. A single spec renders the bare
/// pill; two or more render as a paged horizontal scroll with a quiet
/// dot indicator beneath.
private struct PermissionBannersCarousel: View {
    let specs: [PermissionBannerSpec]

    @State private var currentID: String?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if specs.count == 1, let only = specs.first {
                PermissionBannerLabel(spec: only)
            } else {
                VStack(spacing: DS.Spacing.xs) {
                    ScrollView(.horizontal) {
                        HStack(spacing: 0) {
                            ForEach(specs) { spec in
                                PermissionBannerLabel(spec: spec)
                                    .containerRelativeFrame(.horizontal)
                                    .id(spec.id)
                            }
                        }
                        .scrollTargetLayout()
                    }
                    .scrollTargetBehavior(.paging)
                    .scrollIndicators(.hidden)
                    .scrollPosition(id: $currentID)

                    PermissionBannerPageDots(
                        count: specs.count,
                        activeIndex: activeIndex
                    )
                }
                .onAppear {
                    if currentID == nil { currentID = specs.first?.id }
                }
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Permissions required. Swipe to switch between \(specs.count) banners.")
            }
        }
        .padding(.vertical, DS.Spacing.xs)
        .transition(
            reduceMotion
                ? .opacity
                : .move(edge: .top).combined(with: .opacity)
        )
    }

    private var activeIndex: Int {
        guard let id = currentID,
              let i = specs.firstIndex(where: { $0.id == id })
        else { return 0 }
        return i
    }
}

/// Page indicator. Deliberately tiny and quiet — the dots inform, the
/// pill is the figure. Filled = active, hairline-faint = inactive.
private struct PermissionBannerPageDots: View {
    let count: Int
    let activeIndex: Int

    @Environment(\.activeSkin) private var skin

    var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<count, id: \.self) { i in
                Circle()
                    .fill(
                        i == activeIndex
                            ? skin.resolvedTextSecondary
                            : skin.resolvedTextTertiary.opacity(0.4)
                    )
                    .frame(width: 5, height: 5)
                    .animation(DS.Animation.quick, value: activeIndex)
            }
        }
        .accessibilityHidden(true)
    }
}

/// Bottom-Y of the optimizer entry strip — the inline QuickActions card on
/// `.list`, or the fullscreen Backlog's block header on `.backlog`. The
/// command palette anchors itself below this Y so the «Optimize ⌘K» trigger
/// that opened it stays visible and the palette feels glued to its origin.
///
/// Internal (not fileprivate) so the fullscreen Backlog, which lives in its
/// own file, can publish into the same key — switching surfaces shouldn't
/// make the palette float over the popover header.
struct OptimizerBottomKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

let menuBarRootCoordinateSpace = "MenuBarViewRoot"
