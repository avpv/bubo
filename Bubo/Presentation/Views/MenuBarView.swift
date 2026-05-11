import SwiftUI

struct MenuBarView: View {
    @Environment(\.activeSkin) private var skin
    var settings: ReminderSettings
    var reminderService: ReminderService
    var networkMonitor: NetworkMonitor
    var optimizerService: OptimizerService
    var agentService: AgentService
    var remindersSyncService: RemindersSyncService

    @Environment(\.openSettings) private var openSettings

    @State private var navigation: MenuBarNavigation = .list
    @State private var hasStartedSync = false
    /// Day-rollover timer for `AutoDeferService` — fires shortly past
    /// midnight so the «left popover open overnight» case picks up the
    /// new day's deferral pass without requiring the user to reopen
    /// the popover. Stored as state so the lifecycle tracks the view's
    /// — created in `onAppear`, invalidated in `onDisappear`. Without
    /// this, AutoDefer only ran on popover-open, which missed users
    /// who keep the menu bar pinned overnight.
    @State private var dayRolloverTimer: Timer? = nil
    /// Becomes true 3\u{00A0}s after the first popover open, regardless of
    /// whether the EventKit sync has produced events yet. Used to escalate
    /// the «Syncing calendars…» panel into «Sync taking long» so the user
    /// has a path to action when the system actually is stuck.
    @State private var initialSyncTimeoutFired = false
    /// Becomes true the first time `reminderService` reports a non-empty
    /// event list, marking the sync as «produced something». Used to drop
    /// out of the syncing panel once data lands, even before the 3\u{00A0}s
    /// timeout. Once latched, never resets — the panel is one-shot per
    /// app launch, not a recurring spinner on every empty state.
    @State private var initialSyncDataArrived = false
    @State private var toastState = ToastState()
    @State private var scrollPositionID: String?

    /// Day currently anchored by the popover header's day-nav cluster.
    /// `nil` means «we haven't navigated explicitly yet» — treated as
    /// today for the purposes of the Today button's dimmed state. Set
    /// by tapping `← / Today / →`; reset to nil if the focused day
    /// drops out of `filteredEventsByDay` (e.g. via colour filter).
    @State private var focusedDayDate: Date?

    /// Extra days appended to the timeline horizon by the «Load more
    /// days» button at the bottom of the list. Each tap adds one week
    /// (7 days); capped at `Self.extraDaysCap` so the cost of building
    /// LazyVStack content stays bounded. Resets when the popover is
    /// recreated (so the next session starts on the default window).
    @State private var extraDaysShown: Int = 0

    /// Hard ceiling on `extraDaysShown` — 12 weeks beyond the default
    /// `fetchWindowDays`. Far enough out to plan a quarter, short
    /// enough that the LazyVStack doesn't grow unbounded.
    private static let extraDaysCap: Int = 84

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

    /// Shared state for backlog drag-to-schedule + ghost-preview. Owned here
    /// because both the drag source (BacklogView) and the drop targets
    /// (FreeSlotRow instances scattered across the day list) need it, and the
    /// ghost block on the timeline is rendered by this view.
    @State private var backlogCoordinator = BacklogInteractionCoordinator()

    /// Per-minute time tick used to drive the «happening now» highlight on
    /// `EventRowView`. Updated by the `everyMinuteTimer` subscription so
    /// every row in the day can read a single shared `Date` instead of
    /// each instantiating its own timer.
    @State private var nowTick: Date = Date()
    private let everyMinuteTimer = Timer.publish(every: 60, on: .main, in: .common).autoconnect()

    /// Drives the quick-capture popover anchored on the SmartActionsBar's
    /// Backlog chip. Lifted to MenuBarView so the global ⇧⌘N shortcut
    /// can flip it from outside (chip click flips its own internal
    /// state via the same binding).
    @State private var showingQuickCapture: Bool = false

    /// Day for which the user has dismissed the «Roll forward» banner.
    /// Per-session only: a fresh launch tomorrow re-evaluates from
    /// scratch (the banner gating already requires after-hours +
    /// non-empty unfinished, so it won't nag mid-day).
    @State private var rollForwardDismissedDay: Date? = nil

    // Command palette — the single entry point for all optimize flows.
    @State private var paletteContext: MenuBarPaletteContext? = nil
    @State private var dismissedBannerIds: Set<String> = {
        let stored = UserDefaults.standard.stringArray(forKey: "BuboDismissedBannerIds") ?? []
        return Set(stored)
    }()

    /// J10: ISO-8601 day string («2026-05-01») that the user already
    /// dismissed the end-of-day prompt for. Stored in UserDefaults so
    /// closing + reopening the popover doesn't resurrect the banner the
    /// same evening. Read once on appear, written on the dismiss tap.
    @AppStorage("BuboEODBannerDismissedDay") private var eodDismissedDay: String = ""

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

    // `Navigation` and `PaletteContext` extracted to file scope in
    // `Views/MenuBarNavigation.swift` and `Views/MenuBarPaletteContext.swift`
    // — see `MenuBarNavigation` and `MenuBarPaletteContext`.


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
                        },
                        onReschedule: { event in
                            navigation = .list
                            paletteContext = MenuBarPaletteContext(seedEvent: event)
                        },
                        onExtend: { event in
                            navigation = .list
                            Task {
                                await runQuickAction(
                                    OptimizationRequest(
                                        .onlyOptimize(eventIds: [event.id]),
                                        .findSlotsForBacklog,
                                        .horizon(.today), .speed(.quick), .scenarios(count: 1),
                                        name: "Extend"
                                    ),
                                    label: "Extended \u{201C}\(event.title)\u{201D}"
                                )
                            }
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
                            paletteContext = MenuBarPaletteContext(seedRecipeId: IntentPresets.Name.pomodoroSession)
                        },
                        onSessionEnded: { entry in
                            optimizerService.pomodoroHistory.record(entry)
                        },
                        onAdjustEndDate: { event, deltaMinutes in
                            // Scrub-the-ring extends/shortens `endDate` only.
                            // We re-fetch the current event so successive
                            // scrubs compose correctly (each delta applies
                            // to the latest end-date, not to a stale capture).
                            // Clamp the new end-date to «now + 60s» so the
                            // user can never scrub the timer past the
                            // present moment and have it auto-end mid-drag.
                            guard var current = reminderService.localEvents.first(where: { $0.id == event.id }) else { return }
                            let proposed = current.endDate.addingTimeInterval(TimeInterval(deltaMinutes * 60))
                            let floor = Date().addingTimeInterval(60)
                            current.endDate = max(proposed, floor)
                            reminderService.updateLocalEvent(current)
                            let signed = deltaMinutes > 0 ? "+\(deltaMinutes)\u{00A0}min" : "\(deltaMinutes)\u{00A0}min"
                            toastState.showSuccess("End time \(signed)", icon: "timer")
                        },
                        onShiftSchedule: { event, deltaMinutes in
                            // J9: vertical-drag pause. Shift BOTH
                            // start and end forward by `deltaMinutes`
                            // — the work segment resumes from where
                            // it was, just N minutes later in wall
                            // time. Re-fetch the current event so
                            // multiple pauses compose correctly. Undo
                            // toast restores the prior schedule.
                            guard let current = reminderService.localEvents.first(where: { $0.id == event.id }) else { return }
                            let priorStart = current.startDate
                            let priorEnd = current.endDate
                            var shifted = current
                            shifted.startDate = priorStart.addingTimeInterval(TimeInterval(deltaMinutes * 60))
                            shifted.endDate = priorEnd.addingTimeInterval(TimeInterval(deltaMinutes * 60))
                            reminderService.updateLocalEvent(shifted)
                            toastState.showSuccess(
                                "Paused +\(deltaMinutes)\u{00A0}min",
                                icon: "pause.circle"
                            ) {
                                guard var rolled = reminderService.localEvents.first(where: { $0.id == event.id }) else { return }
                                rolled.startDate = priorStart
                                rolled.endDate = priorEnd
                                reminderService.updateLocalEvent(rolled)
                            }
                        }
                    )
                    .transition(
                        reduceMotion ? .opacity : .asymmetric(
                            insertion: .move(edge: .trailing).combined(with: .opacity),
                            removal: .move(edge: .trailing).combined(with: .opacity).combined(with: .scale(scale: 0.98))
                        )
                    )

                case .addEvent(let editing, let initialType, let prefillFrom):
                    AddEventView(
                        prefillFromEvent: prefillFrom,
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

                case .newTask(let prefillTitle, let prefillDuration):
                    if let backlog = optimizerService.backlogService {
                        NewTaskView(
                            prefillTitle: prefillTitle,
                            prefillDuration: prefillDuration,
                            defaultDuration: optimizerService.defaultTaskDurationMinutes,
                            backlogService: backlog,
                            onDismiss: { navigation = .list },
                            onSave: { _ in
                                navigation = .list
                                toastState.showSuccess("Task added", icon: "checkmark.circle.fill")
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
                            onCreateTaskWithDetails: { prefillTitle, prefillDuration in
                                navigation = .newTask(prefillTitle: prefillTitle, prefillDuration: prefillDuration)
                            },
                            onUndoableAction: { message, undo in
                                toastState.showSuccess(message, icon: "arrow.uturn.backward", onUndo: undo)
                            },
                            onScheduleBacklog: {
                                await runQuickAction(.scheduleBacklog, label: "Scheduled backlog")
                            },
                            onFocusOnDeadlines: {
                                await runQuickAction(.deadlineMode, label: "Focused on deadlines")
                            },
                            onRunRequest: { request, label in
                                await runQuickAction(request, label: label)
                            },
                            onScheduleTask: { task in
                                // Per-task scope: same pipe as the inline
                                // BacklogView's `onScheduleTask`. We don't
                                // pop back to .list here — the user is
                                // working through the fullscreen list and
                                // the optimizer applies in-place.
                                Task {
                                    var req = OptimizationRequest(name: "Find slot")
                                    req.add(.includeBacklogTasks(ids: [task.id]))
                                    req.add(.findSlotsForBacklog)
                                    let trimmed = task.title.count > 24
                                        ? String(task.title.prefix(24)) + "\u{2026}"
                                        : task.title
                                    await runQuickAction(req, label: "Found slot for \u{201C}\(trimmed)\u{201D}")
                                }
                            },
                            onLoadAlternativesForTask: { task in
                                // ⌥-click on the row's Schedule button —
                                // run the same per-task request as
                                // `onScheduleTask` but ask for 5 scenarios
                                // and DON'T apply. The popover lets the
                                // user pick which one to commit.
                                var req = OptimizationRequest(name: "Slot alternatives")
                                req.add(.includeBacklogTasks(ids: [task.id]))
                                req.add(.findSlotsForBacklog)
                                req.add(.scenarios(count: 5))
                                return await optimizerService.previewScenarios(
                                    req,
                                    reminderService: reminderService
                                )
                            },
                            onPickAlternativeScenario: { scenario in
                                // Commit a previewed scenario via the
                                // service's dedicated entry point so
                                // undo / snapshot bookkeeping route
                                // through the same machinery as
                                // `runQuickAction`'s top-pick commit.
                                optimizerService.applyPreviewedScenario(
                                    scenario,
                                    to: reminderService
                                )
                                toastState.showSuccess(
                                    "Scheduled into chosen slot",
                                    icon: "sparkles"
                                ) {
                                    optimizerService.undoLast(reminderService: reminderService)
                                }
                                notifyScheduleChange()
                            },
                            onSplitTask: { task in
                                Task {
                                    var req = OptimizationRequest(name: "Split task")
                                    req.add(.includeBacklogTasks(ids: [task.id]))
                                    req.add(.splitLong(maxMinutes: max(30, task.durationMinutes / 2)))
                                    req.add(.findSlotsForBacklog)
                                    let trimmed = task.title.count > 24
                                        ? String(task.title.prefix(24)) + "\u{2026}"
                                        : task.title
                                    await runQuickAction(req, label: "Split \u{201C}\(trimmed)\u{201D}")
                                }
                            },
                            onOpenPalette: {
                                Haptics.tap()
                                withAnimation(DS.Animation.quick) {
                                    paletteContext = MenuBarPaletteContext()
                                }
                            },
                            onSwitchScenario: { index in
                                optimizerService.switchToAppliedScenario(
                                    at: index,
                                    to: reminderService
                                )
                            },
                            onLockTodaysEvents: {
                                // Same bulk-lock as the inline view; the
                                // user gets the same toast on success and
                                // the rows light up with solid lock icons
                                // when they return to the main popover.
                                let cal = Calendar.current
                                let todaysIds = reminderService.allEvents
                                    .filter { cal.isDateInToday($0.startDate) }
                                    .map(\.id)
                                let preCount = optimizerService.lockedEventIds.count
                                for id in todaysIds {
                                    if !optimizerService.isLocked(eventId: id) {
                                        optimizerService.toggleLock(eventId: id)
                                    }
                                }
                                let added = optimizerService.lockedEventIds.count - preCount
                                if added > 0 {
                                    toastState.showSuccess(
                                        added == 1 ? "Locked 1\u{00A0}event" : "Locked \(added)\u{00A0}events",
                                        icon: "lock.fill"
                                    ) {
                                        for id in todaysIds where optimizerService.isLocked(eventId: id) {
                                            optimizerService.toggleLock(eventId: id)
                                        }
                                    }
                                } else {
                                    toastState.showInfo("Today's events are already locked", icon: "lock.fill")
                                }
                            },
                            onRescheduleTask: { task in
                                navigation = .list
                                paletteContext = MenuBarPaletteContext(seedTask: task)
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
                    // Capture-first now lives in fullscreen backlog.
                    // Returning from edit → drop user back on the main
                    // list; no auto-focus needed (no inline input to
                    // focus). The user can ⇧⌘N or tap «Backlog» on
                    // the SmartActions bar to add another task.
                    EmptyView()
                        .onAppear {
                            navigation = .list
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
                    seedTask: context.seedTask,
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
                    },
                    onOpenEvent: { event in
                        // Cross-cutting #2: jump from the palette to the
                        // event detail. The palette dismiss happens in
                        // the row tap itself; we only flip navigation
                        // here. The detail view's own back button
                        // returns to the list.
                        withAnimation(DS.Animation.quick) {
                            paletteContext = nil
                            navigation = .detail(event)
                        }
                    }
                )
                // The Backlog card now publishes `OptimizerBottomKey`
                // (see its `.background(GeometryReader…)` modifier),
                // so `optimizerBottomY` reflects the card's bottom
                // edge. Fallback minimum (≈ height of WorldClock +
                // filter bar) preserves a sensible position before the
                // first preference reading lands.
                .padding(.top, max(120, optimizerBottomY))
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
                        paletteContext = MenuBarPaletteContext()
                    } else {
                        paletteContext = nil
                    }
                }
            }
            .keyboardShortcut("k", modifiers: .command)
            .opacity(0)
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)

            // Hidden button for ⇧⌘N shortcut — opens the inline
            // quick-capture popover anchored on the SmartActionsBar's
            // Backlog chip. Routes through `navigation = .list` first
            // so the bar is mounted when the popover tries to anchor.
            Button("") {
                Haptics.tap()
                if navigation != .list {
                    navigation = .list
                }
                showingQuickCapture = true
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
        .onReceive(everyMinuteTimer) { tick in
            // Drives the «happening now» highlight on EventRowView. One
            // shared tick across every row keeps the row a pure View
            // (no per-row timers).
            nowTick = tick
        }
        .frame(width: DS.Popover.width, height: navigation.isTimer ? DS.Popover.timerHeight : DS.Popover.height)
        .onAppear {
            // Refresh permission snapshots every time the popover surfaces
            // — covers the case where the user granted access via System
            // Settings while we were closed. Cheap, idempotent, and
            // independent of the one-shot `hasStartedSync` guard below.
            refreshPermissionSnapshots()

            // Drain any ⇧↩ quick-capture prefill that was buffered while
            // this view wasn't in the tree. The bridge clears itself on
            // read, so a hot popover (notification path) and a cold
            // popover (this path) never both navigate.
            if let pending = QuickCaptureBridge.shared.take() {
                navigation = .newTask(prefillTitle: pending, prefillDuration: nil)
            }

            // AutoDefer runs once per calendar day. Calling on every
            // popover open is cheap (the service early-exits when
            // `lastRunDate` is today) and covers the «opened a fresh
            // morning» case automatically. Birman: «let the machine
            // sweat» — overdue rows are an artefact of the previous
            // day, the user shouldn't have to scroll past them today.
            runAutoDeferIfNeeded()
            scheduleDayRolloverTimerIfNeeded()

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
            // Escalate the «Syncing calendars…» panel to a long-running
            // hint after 3\u{00A0}s. If data arrives sooner, the panel
            // disappears via `initialSyncDataArrived` and the user never
            // sees the «taking long» copy.
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(3))
                initialSyncTimeoutFired = true
            }
        }
        .onDisappear {
            // Tear down the day-rollover timer so we don't leak it
            // when the popover is dismissed. `onAppear` will re-arm
            // the timer on the next open if the day hasn't yet
            // rolled.
            dayRolloverTimer?.invalidate()
            dayRolloverTimer = nil
        }
        .onChange(of: reminderService.allEvents.isEmpty) { _, isEmpty in
            // Latch on the first non-empty event list — we treat that as
            // «sync produced something», which is enough to drop the
            // syncing panel. We don't unlatch when events go back to
            // empty later (e.g. user filters everything out); the panel
            // is one-shot per app launch.
            if !isEmpty { initialSyncDataArrived = true }
        }
        .onChange(of: optimizerService.backlogService?.tasks.count ?? 0) { _, _ in
            // Backlog mutated → kick a fresh shadowProposal compute so
            // the per-task ghost-slots / SmartActions delta hints stay
            // current. `previewRequest` is fire-and-cancel: a fresh
            // call cancels the previous in-flight task, so back-to-back
            // edits collapse to one run on the latest state. The
            // request itself is the same `.scheduleBacklog` SmartActions
            // would fire on Run, so the preview reflects what the user
            // would actually see if they tapped Run right now.
            optimizerService.previewRequest(.scheduleBacklog, reminderService: reminderService)
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
        .onReceive(NotificationCenter.default.publisher(for: .didCaptureBacklogTask)) { notification in
            // J5: text captured via the global hotkey lands here. We
            // own the BacklogService at this layer, so the insert plus
            // its undo toast both live in one place. Trimming/empty
            // gating already happened in `QuickCaptureView.commit`.
            guard let text = notification.userInfo?["text"] as? String,
                  let backlog = optimizerService.backlogService else { return }
            let task = BacklogTask(title: text)
            backlog.addTask(task)
            let trimmed = text.count > 32 ? String(text.prefix(32)) + "\u{2026}" : text
            toastState.showSuccess(
                "Added \u{201C}\(trimmed)\u{201D}",
                icon: "plus.circle.fill"
            ) {
                _ = backlog.removeTask(id: task.id)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .didCaptureBacklogTaskWithDetails)) { notification in
            // ⇧↩ from quick-capture: route to the compact creation form
            // pre-filled with the typed text. The prefill was also
            // dropped into `QuickCaptureBridge.shared` so a closed-popover
            // race still lands the user on the form via `.onAppear`.
            guard let text = notification.userInfo?["text"] as? String else { return }
            // Drain the bridge slot too — the notification path beat the
            // .onAppear consumer to it, and we don't want a duplicate
            // navigation when the popover finishes opening.
            _ = QuickCaptureBridge.shared.take()
            navigation = .newTask(prefillTitle: text, prefillDuration: nil)
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
            base = timelineEventsByDay.compactMap { dayGroup in
                let filtered = dayGroup.events.filter { $0.colorTag == filter }
                return filtered.isEmpty ? nil : (date: dayGroup.date, events: filtered)
            }
        } else {
            // Keep empty day groups so users can see their free slots and
            // drop tasks into days that have no events yet.
            base = timelineEventsByDay
        }
        return base
    }

    /// Day buckets the timeline actually renders — same shape as
    /// `reminderService.eventsByDay` but with a runtime-extendable
    /// horizon (`fetchWindowDays + extraDaysShown`). Other call sites
    /// (`headerSubtitle`, `isScrolledFromTop`, etc.) stay on the
    /// service's default 7-day window because they only care about
    /// today and the immediate horizon.
    private var timelineEventsByDay: [(date: Date, events: [CalendarEvent])] {
        let calendar = Calendar.current
        let grouped = Dictionary(grouping: reminderService.allEvents) { event in
            calendar.startOfDay(for: event.startDate)
        }
        let today = calendar.startOfDay(for: Date())
        let horizon = ReminderService.fetchWindowDays + extraDaysShown
        var results: [(date: Date, events: [CalendarEvent])] = []
        for offset in 0..<horizon {
            guard let day = calendar.date(byAdding: .day, value: offset, to: today) else { continue }
            results.append((date: day, events: grouped[day] ?? []))
        }
        return results
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

    /// Index of the currently-focused day inside `filteredEventsByDay`,
    /// defaulting to today when the user hasn't navigated yet (or to
    /// the first day if today isn't in the window). Drives the
    /// enable/disable state of the day-nav arrows.
    private var focusedDayIndex: Int {
        let days = filteredEventsByDay
        guard !days.isEmpty else { return 0 }
        let cal = Calendar.current
        let target = focusedDayDate
            ?? days.first(where: { cal.isDateInToday($0.date) })?.date
        if let target,
           let idx = days.firstIndex(where: { cal.isDate($0.date, inSameDayAs: target) }) {
            return idx
        }
        return 0
    }

    /// True when the day-nav cluster considers «today» the active
    /// focus — either the user hasn't navigated, or they've explicitly
    /// jumped back to today's section. Dims the Today button.
    private var focusedDayIsToday: Bool {
        let cal = Calendar.current
        if let date = focusedDayDate {
            return cal.isDateInToday(date)
        }
        return true
    }

    /// Scroll the timeline to the day at `index`, clamped to the
    /// visible window, and update `focusedDayDate` so the nav cluster
    /// stays in sync. No-op on empty days.
    private func navigateToDay(at index: Int, scroll: ScrollViewProxy) {
        let days = filteredEventsByDay
        guard !days.isEmpty else { return }
        let clamped = max(0, min(days.count - 1, index))
        let targetDate = days[clamped].date
        Haptics.tap()
        focusedDayDate = targetDate
        withAnimation(DS.Animation.smoothSpring) {
            scroll.scrollTo(targetDate, anchor: .top)
        }
    }

    /// Inline «NOW · 10:48» rule, dropped into today's interleaved
    /// timeline so the past/future boundary reads at a glance —
    /// matches the prototype's `.now-line`. Two faint red rules with
    /// the timestamp tracked between them; the timestamp re-renders
    /// on the same minute cadence as every other countdown.
    @ViewBuilder
    private func nowMarkerRow(_ stamp: Date) -> some View {
        HStack(spacing: DS.Spacing.xs) {
            Rectangle()
                .fill(skin.resolvedDestructiveColor.opacity(DS.Opacity.strongFill * 2))
                .frame(height: 1)
            Text("NOW \u{00B7} \(nowMarkerLabel(stamp))")
                .font(.caption2.weight(.semibold).monospacedDigit())
                .foregroundStyle(skin.resolvedDestructiveColor)
                .tracking(0.5)
                .fixedSize()
            Rectangle()
                .fill(skin.resolvedDestructiveColor.opacity(DS.Opacity.strongFill * 2))
                .frame(height: 1)
        }
        .padding(.horizontal, DS.Spacing.xs)
        .padding(.vertical, DS.Spacing.xxs)
        .accessibilityLabel("Now \(nowMarkerLabel(stamp))")
    }

    /// Locale-aware `H:mm` for the NOW marker — same formatter style
    /// as `NowNextLine.timeLabel(_:)` so the two surfaces stay in sync.
    private func nowMarkerLabel(_ date: Date) -> String {
        let fmt = DateFormatter()
        fmt.setLocalizedDateFormatFromTemplate("H:mm")
        return fmt.string(from: date)
    }

    /// Three-button day-nav cluster (`← Today →`) for the popover
    /// header trailing area. Mirrors the prototype's day-jumping
    /// shortcut without changing the underlying multi-day timeline —
    /// taps just scroll the list to the requested day's section. The
    /// Today button dims when the focus is already today; the arrows
    /// disable at the edges of the visible window.
    @ViewBuilder
    private func dayNavCluster(scroll: ScrollViewProxy) -> some View {
        let days = filteredEventsByDay
        let idx = focusedDayIndex
        HStack(spacing: DS.Spacing.xxs) {
            Button {
                navigateToDay(at: idx - 1, scroll: scroll)
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: DS.Size.iconSmall, weight: .semibold))
                    .foregroundStyle(skin.resolvedTextSecondary)
            }
            .buttonStyle(.borderless)
            .disabled(idx <= 0)
            .help("Previous day")
            .accessibilityLabel("Previous day")

            Button {
                if let todayIdx = days.firstIndex(where: { Calendar.current.isDateInToday($0.date) }) {
                    navigateToDay(at: todayIdx, scroll: scroll)
                }
            } label: {
                Text("Today")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(skin.accentColor)
                    .opacity(focusedDayIsToday ? 0.4 : 1.0)
            }
            .buttonStyle(.borderless)
            .disabled(focusedDayIsToday)
            .help("Jump to today")
            .accessibilityLabel("Jump to today")

            Button {
                navigateToDay(at: idx + 1, scroll: scroll)
            } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: DS.Size.iconSmall, weight: .semibold))
                    .foregroundStyle(skin.resolvedTextSecondary)
            }
            .buttonStyle(.borderless)
            .disabled(idx >= days.count - 1)
            .help("Next day")
            .accessibilityLabel("Next day")
        }
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

    /// Cross-cutting #4: build a new draft event from the shape of an
    /// existing one. Copies title, duration, location, description,
    /// color tag, reminders, event type, and Pomodoro config; resets id,
    /// recurrence, calendar binding, and series metadata so the draft
    /// reads as a brand-new event. The new start defaults to «now
    /// rounded up to the next 15-min boundary», which `AddEventView`
    /// will then offer to slot via «Find best time» / drag.
    private func cloneAsDraft(_ source: CalendarEvent) -> CalendarEvent {
        let cal = Calendar.current
        let now = Date()
        // Round forward to the nearest 15-min mark — same granularity
        // the optimizer's free-slot finder works in, so the user can
        // tap «Find best time» and not see a confusing 14-min jump.
        let minute = cal.component(.minute, from: now)
        let bumped = (minute / 15 + 1) * 15
        let nextSlot: Date = {
            var components = cal.dateComponents([.year, .month, .day, .hour], from: now)
            components.minute = bumped % 60
            components.hour = (components.hour ?? 0) + (bumped >= 60 ? 1 : 0)
            return cal.date(from: components) ?? now.addingTimeInterval(15 * 60)
        }()
        let duration = max(15 * 60, source.endDate.timeIntervalSince(source.startDate))

        // Start from a copy so we inherit every field (including
        // defaults that may grow over time) and then override only
        // what the clone semantics demand.
        var draft = source
        draft.id = UUID().uuidString
        draft.title = source.title
        draft.startDate = nextSlot
        draft.endDate = nextSlot.addingTimeInterval(duration)
        draft.customReminderMinutes = source.customReminderMinutes
        draft.recurrenceRule = nil
        draft.seriesId = nil
        draft.taskStatus = .todo
        draft.completedAt = nil
        draft.dependsOn = []
        draft.isMovable = true
        draft.deadline = nil
        draft.pomodoroTaskSequence = []
        // Pomodoro shape: copy the recurrence rule's pomodoro fields
        // (interval / rounds / longBreak) so the cloned timer keeps
        // the same rhythm. Non-pomodoro events leave this nil.
        if source.eventType == .pomodoro, let rule = source.recurrenceRule, rule.pomodoroMode {
            draft.recurrenceRule = RecurrenceRule(
                frequency: .minutely,
                interval: rule.interval,
                end: rule.end,
                pomodoroMode: true,
                pomodoroLongBreak: rule.pomodoroLongBreak
            )
        }
        return draft
    }

    /// J6: ripple-shift every local, movable, non-recurring event that
    /// starts AFTER `anchor` on the same calendar day by `minutes`.
    /// Caps the number of events touched to 5 so a single drag can't
    /// cascade through a packed afternoon. Returns the ids actually
    /// shifted, so the caller can reverse the ripple in undo.
    private func rippleShiftLaterEvents(after anchor: CalendarEvent, minutes: Int) -> [String] {
        guard minutes != 0 else { return [] }
        let cal = Calendar.current
        // Anchor's *post-shift* day still defines the ripple scope —
        // we ripple within the same calendar day, regardless of which
        // direction the user dragged.
        let day = anchor.startDate

        let rippleCap = 5
        let candidates = reminderService.localEvents
            .filter { $0.id != anchor.id }
            .filter { cal.isDate($0.startDate, inSameDayAs: day) }
            .filter { $0.startDate >= anchor.endDate }
            .filter { $0.recurrenceRule == nil && $0.seriesId == nil }
            .filter { $0.eventType != .pomodoro }
            .filter { $0.endDate > Date() }
            .sorted { $0.startDate < $1.startDate }
            .prefix(rippleCap)

        var rippled: [String] = []
        for event in candidates {
            reminderService.snoozeReminder(for: event, minutes: minutes)
            rippled.append(event.id)
        }
        return rippled
    }

    /// J3: top backlog candidate for a slot of `slotMinutes`, used as
    /// the «Start … here» entry in `FreeSlotRow`'s right-click menu.
    /// Returns the highest-priority pending task whose duration fits
    /// inside the slot. nil = no candidate, so the menu omits the
    /// row entirely. Reuses `BacklogTaskDrag` so the same downstream
    /// path (`handleTaskDrop`) handles both drag-drop and right-click
    /// — single code path, single set of undo semantics.
    private func topBacklogCandidate(forSlotMinutes slotMinutes: Int) -> BacklogTaskDrag? {
        guard let backlog = optimizerService.backlogService else { return nil }
        let candidate = backlog.pending
            .filter { $0.durationMinutes > 0 && $0.durationMinutes <= slotMinutes }
            .sorted { lhs, rhs in
                // Deadline-first (sooner wins), then priority (high first),
                // then position in the user's drag-ordered list.
                let lhsDeadline = lhs.deadline ?? .distantFuture
                let rhsDeadline = rhs.deadline ?? .distantFuture
                if lhsDeadline != rhsDeadline { return lhsDeadline < rhsDeadline }
                if lhs.priority != rhs.priority {
                    return lhs.priority.numericValue > rhs.priority.numericValue
                }
                return false
            }
            .first
        guard let task = candidate else { return nil }
        return BacklogTaskDrag(
            taskId: task.id,
            title: task.title,
            durationMinutes: task.durationMinutes,
            context: task.context
        )
    }

    /// J3: start a Pomodoro in the given slot. Picks the standard
    /// shape from `PomodoroDefaults.suggested(for:)` so the rounds /
    /// work / break match the slot length, then registers the same
    /// undo-toast as the other slot-filling paths.
    private func startPomodoroInSlot(start: Date, end: Date) {
        Haptics.tap()
        let slotMinutes = max(0, Int(end.timeIntervalSince(start) / 60))
        let defaults = PomodoroDefaults.suggested(for: slotMinutes)
        let eventId = "pomodoro-\(UUID().uuidString)"
        let workEnd = start.addingTimeInterval(TimeInterval(defaults.work * 60))
        var event = CalendarEvent(
            id: eventId,
            title: "Pomodoro",
            startDate: start,
            endDate: workEnd,
            location: nil,
            description: nil,
            calendarName: nil,
            eventType: .pomodoro,
            colorTag: .red
        )
        event.recurrenceRule = RecurrenceRule(
            frequency: .minutely,
            interval: defaults.cycleMinutes,
            end: .afterCount(defaults.rounds),
            pomodoroMode: true,
            pomodoroLongBreak: defaults.longBreak
        )
        reminderService.addLocalEvent(event)
        toastState.showSuccess(
            "Pomodoro: \(defaults.rounds) \u{00D7} \(defaults.work)\u{00A0}min",
            icon: "timer"
        ) {
            reminderService.removeLocalEvent(id: eventId)
        }
        notifyScheduleChange(created: true)
    }

    // MARK: - Now / Next status line (J-Triage)

    /// Today's events used to compute the «Now / Next» line. Pulled
    /// from the same `eventsByDay` source the timeline reads, narrowed
    /// to the current calendar day.
    private var todaysEventsForNowNext: [CalendarEvent] {
        let cal = Calendar.current
        return reminderService.eventsByDay
            .first(where: { cal.isDate($0.date, inSameDayAs: nowTick) })?
            .events ?? []
    }

    @ViewBuilder
    private var nowNextLine: some View {
        let line = NowNextLine(
            events: todaysEventsForNowNext,
            now: nowTick,
            overdueCount: optimizerService.backlogService?.overdue.count ?? 0,
            onOpenBacklog: { navigation = .backlog }
        )
        if line.hasContent {
            line
                .padding(.top, DS.Spacing.xs)
        }
    }

    // MARK: - Roll forward (J-Recover)

    /// Whether the «Roll forward» banner should surface above the
    /// timeline. Three gates compose: it's after working hours, the
    /// banner hasn't been dismissed for today, and there's at least
    /// one task scheduled for today that isn't done yet.
    private var shouldShowRollForward: Bool {
        let cal = Calendar.current
        let endHour = optimizerService.workingHoursEnd
        guard cal.component(.hour, from: nowTick) >= endHour else { return false }
        if let dismissedDay = rollForwardDismissedDay,
           cal.isDate(dismissedDay, inSameDayAs: nowTick) {
            return false
        }
        return unfinishedTodayCount > 0
    }

    /// Tasks scheduled for today that haven't been completed yet.
    /// Drives both the gate above and the banner's headline copy.
    private var unfinishedTodayCount: Int {
        guard let backlog = optimizerService.backlogService else { return 0 }
        let cal = Calendar.current
        return backlog.tasks.filter { task in
            guard task.status == .scheduled,
                  let scheduled = task.scheduledDate
            else { return false }
            return cal.isDate(scheduled, inSameDayAs: nowTick)
        }.count
    }

    /// Roll today's incomplete tasks back into the backlog. The
    /// optimizer is NOT auto-run here — the user can tap «Plan
    /// tomorrow» (a ranked chip) afterwards if they want auto-
    /// scheduling. Restores the original schedule on undo.
    private func performRollForward() {
        guard let backlog = optimizerService.backlogService else { return }
        let snapshots = backlog.rollTodayForward(now: nowTick)
        guard !snapshots.isEmpty else { return }
        let count = snapshots.count
        toastState.showSuccess(
            count == 1
                ? "Rolled 1\u{00A0}task to backlog"
                : "Rolled \(count)\u{00A0}tasks to backlog",
            icon: "moon.stars.fill"
        ) { [backlog] in
            // Undo: restore each task's pre-roll snapshot. Order
            // doesn't matter — `updateTask` is idempotent on each
            // task's id.
            for snapshot in snapshots {
                backlog.updateTask(snapshot)
            }
        }
        // Hide the banner for the rest of the day so it doesn't
        // re-prompt after the action.
        rollForwardDismissedDay = Calendar.current.startOfDay(for: nowTick)
        notifyScheduleChange()
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
            "Rescheduled \(count)\u{00A0}task\(count == 1 ? "" : "s")",
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

    /// Handle a backlog task being dropped onto a free slot.
    /// Resolves the drag payload, ends the drag session, and delegates
    /// to the shared `scheduleBacklogTask(_:slotStart:slotEnd:)` helper.
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

        scheduleBacklogTask(task, slotStart: slotStart, slotEnd: slotEnd)
    }

    /// Place an existing backlog task into the calendar at the given slot.
    /// Shared path for drag-drop, the slot picker's «pick existing» row,
    /// and the right-click «Start top here» context menu — all three end
    /// up creating a calendar event, marking the task as scheduled, and
    /// surfacing a unified undo toast.
    ///
    /// Undo restores the task's full pre-schedule snapshot via
    /// `updateTask(snapshot)`, which cleanly reverses `markScheduled`
    /// because every mutable field returns to its pre-call value.
    private func scheduleBacklogTask(_ task: BacklogTask, slotStart: Date, slotEnd: Date) {
        guard let backlog = optimizerService.backlogService else { return }

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
        // Clean up any prior chunks so a re-schedule collapses a
        // multi-slot layout into the single new slot rather than
        // leaving orphans.
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
            reminderService.removeLocalEvent(id: eventId)
            backlog.updateTask(taskSnapshot)
            notifyScheduleChange(deleted: eventId)
        }
        notifyScheduleChange()
    }

    /// Slot-picker batch commit — the user opened the picker, queued
    /// some mix of existing backlog tasks and brand-new titles, and
    /// closed the popover. We place each item back-to-back from
    /// `slotStart`, capping the total at `slotEnd`, and surface a
    /// single toast covering the whole session so undo restores the
    /// entire batch in one click. Empty `items` is a no-op (user
    /// dismissed without queueing anything).
    ///
    /// Order matters: the picker preserves user-tap order, and so do
    /// we — placement starts at `slotStart` and the cursor advances
    /// by each item's duration. The last item is truncated if the
    /// queued total exceeded the slot, mirroring the single-task
    /// behaviour of `scheduleBacklogTask`. Items past a fully filled
    /// cursor are skipped rather than stacked elsewhere; the picker's
    /// auto-commit rule should prevent this in practice, but we
    /// double-check defensively because background re-syncs could
    /// have shrunk the slot between queue and commit.
    private func scheduleSlotPickerBatch(
        items: [SlotPickerCommitItem],
        slotStart: Date,
        slotEnd: Date
    ) {
        guard !items.isEmpty,
              let backlog = optimizerService.backlogService else { return }

        // Per-placement undo closures, captured in placement order and
        // run in reverse so the schedule unwinds the way it was wound.
        var undoActions: [() -> Void] = []
        var placedEventIds: [String] = []

        var cursor = slotStart
        var firstStart: Date? = nil
        var lastEnd: Date? = nil

        for item in items {
            let remaining = slotEnd.timeIntervalSince(cursor)
            guard remaining > 0 else { break }

            switch item {
            case .existing(let task):
                let snapshot = task
                let duration = min(TimeInterval(task.durationMinutes * 60), remaining)
                let eventId = "task-\(task.id)"
                let event = CalendarEvent(
                    id: eventId,
                    title: task.title,
                    startDate: cursor,
                    endDate: cursor.addingTimeInterval(duration),
                    location: nil,
                    description: nil,
                    calendarName: nil,
                    eventType: .standard,
                    colorTag: .green
                )
                // Clean up any prior chunks so a re-schedule collapses a
                // multi-slot layout into the single new slot rather than
                // leaving orphans — same rule as `scheduleBacklogTask`.
                for eid in task.scheduledEventIds where eid != eventId {
                    reminderService.removeLocalEvent(id: eid)
                }
                reminderService.addLocalEvent(event)
                backlog.markScheduled(id: task.id, eventId: eventId, date: cursor)

                undoActions.append {
                    reminderService.removeLocalEvent(id: eventId)
                    backlog.updateTask(snapshot)
                }
                placedEventIds.append(eventId)

            case .create(_, let title, let durationMinutes):
                let task = BacklogTask(
                    title: title,
                    durationMinutes: durationMinutes,
                    priority: .medium
                )
                backlog.addTask(task)

                let duration = min(TimeInterval(durationMinutes * 60), remaining)
                let eventId = "task-\(task.id)"
                let event = CalendarEvent(
                    id: eventId,
                    title: title,
                    startDate: cursor,
                    endDate: cursor.addingTimeInterval(duration),
                    location: nil,
                    description: nil,
                    calendarName: nil,
                    eventType: .standard,
                    colorTag: .green
                )
                reminderService.addLocalEvent(event)
                backlog.markScheduled(id: task.id, eventId: eventId, date: cursor)

                let createdTaskId = task.id
                undoActions.append {
                    reminderService.removeLocalEvent(id: eventId)
                    _ = backlog.removeTask(id: createdTaskId)
                }
                placedEventIds.append(eventId)
            }

            if firstStart == nil { firstStart = cursor }
            cursor = cursor.addingTimeInterval(min(
                TimeInterval(item.durationMinutes * 60),
                remaining
            ))
            lastEnd = cursor
        }

        // Nothing actually got placed (slot collapsed under us between
        // queue and commit). Bail without a toast — the user gets a
        // silent no-op rather than a misleading «scheduled 0 tasks».
        guard !placedEventIds.isEmpty else { return }

        let fmt = DateFormatter()
        fmt.setLocalizedDateFormatFromTemplate("H:mm")
        let placedCount = placedEventIds.count
        let startStr = firstStart.map { fmt.string(from: $0) } ?? fmt.string(from: slotStart)

        // Single-item batches should read like the old single-task toast
        // so the common case doesn't regress in voice. Multi-item
        // batches show the count and the placed range.
        let message: String
        let icon: String
        if placedCount == 1 {
            let title = items.first.map(\.displayTitle) ?? ""
            message = "\(title) \u{2192} \(startStr)"
            icon = "calendar.badge.plus"
        } else {
            let endStr = lastEnd.map { fmt.string(from: $0) } ?? ""
            message = "\(placedCount)\u{00A0}tasks \u{2192} \(startStr)\u{2013}\(endStr)"
            icon = "calendar.badge.plus"
        }

        // Capture by value for the toast closure — it outlives this
        // function and runs on the main queue when the user taps undo.
        let undosCopy = undoActions
        let placedIdsCopy = placedEventIds
        toastState.showSuccess(message, icon: icon) {
            for undo in undosCopy.reversed() { undo() }
            for eid in placedIdsCopy {
                notifyScheduleChange(deleted: eid)
            }
        }
        notifyScheduleChange()
    }

    // MARK: - Main Content

    private var mainContent: some View {
        ScrollViewReader { scrollProxy in
        VStack(alignment: .leading, spacing: 0) {
            PopoverHeader(
                title: headerTitle,
                subtitle: headerSubtitle,
                trailing: AnyView(
                    HStack(spacing: DS.Spacing.sm) {
                        StatusIndicators(networkMonitor: networkMonitor, reminderService: reminderService)

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

                        // Day-nav cluster — only worth showing when the
                        // timeline actually spans more than today, else
                        // the arrows would be permanently disabled and
                        // the Today jump would be pointless.
                        if filteredEventsByDay.count > 1 {
                            dayNavCluster(scroll: scrollProxy)
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

            // J10: end-of-day carry-forward prompt. Visible only after
            // the user's working hours have closed for today, with at
            // least one unfinished pending task, and only until they
            // dismiss it for the day. One tap → batch carry + undo
            // toast. Same `xs` vertical padding as the StatusBanners
            // above so the banner sits in the same tier.
            if shouldShowEndOfDayBanner {
                EndOfDayBanner(
                    unfinishedCount: eodUnfinishedCount,
                    onCarry: { carryUnfinishedToTomorrow() },
                    onDismiss: { dismissEndOfDayBannerForToday() }
                )
                .padding(.horizontal, DS.Spacing.contentMargin)
                .padding(.vertical, DS.Spacing.xs)
            }

            // Filter bar — show whenever the timeline has anything to filter.
            // Color dots inside are still gated on `usedColorTags`, but the
            // free-slot toggle (hollow circle) needs to be reachable even when
            // no event is color-tagged, so users can hide / isolate the
            // "Free · Xh" rows on a plain calendar.
            if reminderService.nonDisintegratingEventCount > 0 {
                ColorFilterBar(colorFilter: $colorFilter, freeSlotFilter: $freeSlotFilter)
            }

            // The standalone «Optimize ⌘K» chip card was removed: the
            // optimizer is now woven into the Backlog card itself via the
            // adaptive `SmartActions` row (hard-overflow fix / soft
            // suggestion / `Plan day…` discovery), so a separate entry
            // point above the timeline is redundant. The global ⌘K
            // shortcut still opens the command palette — see the
            // `paletteShortcutBinding` further down. Birman: «don't
            // multiply entities on the main screen» — the optimizer lives next to
            // the data it shapes.
            //
            // `OptimizerBottomKey` is intentionally not republished here.
            // Anchored UI elements that used to attach to the QuickActions
            // bottom edge (the `paletteContext` popover) now anchor to the
            // Backlog card's chrome instead.

            // SmartActions bar — the only optimizer entry point on the
            // main screen. Capture-first task creation moved into the
            // fullscreen backlog (chip on the right edge of the bar);
            // the inline backlog card is gone entirely. Birman: «one
            // screen — one job». The main screen reads the
            // schedule and exposes one verb: «what should the
            // optimizer do next?»
            if let backlog = optimizerService.backlogService {
                SmartActionsBar(
                    backlogService: backlog,
                    optimizerService: optimizerService,
                    reminderService: reminderService,
                    onScheduleBacklog: {
                        await runQuickAction(.scheduleBacklog, label: "Scheduled backlog")
                    },
                    onFocusOnDeadlines: {
                        await runQuickAction(.deadlineMode, label: "Focused on deadlines")
                    },
                    onRunRequest: { request, label in
                        await runQuickAction(request, label: label)
                    },
                    onOpenPalette: {
                        Haptics.tap()
                        withAnimation(DS.Animation.quick) {
                            paletteContext = MenuBarPaletteContext()
                        }
                    },
                    onSwitchScenario: { index in
                        optimizerService.switchToAppliedScenario(
                            at: index,
                            to: reminderService
                        )
                    },
                    onLockTodaysEvents: {
                        let cal = Calendar.current
                        let todaysIds = reminderService.allEvents
                            .filter { cal.isDateInToday($0.startDate) }
                            .map(\.id)
                        let preCount = optimizerService.lockedEventIds.count
                        for id in todaysIds {
                            if !optimizerService.isLocked(eventId: id) {
                                optimizerService.toggleLock(eventId: id)
                            }
                        }
                        let added = optimizerService.lockedEventIds.count - preCount
                        if added > 0 {
                            toastState.showSuccess(
                                added == 1 ? "Locked 1\u{00A0}event" : "Locked \(added)\u{00A0}events",
                                icon: "lock.fill"
                            ) {
                                for id in todaysIds {
                                    if optimizerService.isLocked(eventId: id) {
                                        optimizerService.toggleLock(eventId: id)
                                    }
                                }
                            }
                        } else {
                            toastState.showInfo("Today's events are already locked", icon: "lock.fill")
                        }
                    },
                    onEnterFullscreen: {
                        navigation = .backlog
                    },
                    onUndoableAction: { message, undo in
                        toastState.showSuccess(
                            message,
                            icon: "arrow.uturn.backward",
                            onUndo: undo
                        )
                    },
                    quickCapturePresented: $showingQuickCapture
                )
                // Re-publish `OptimizerBottomKey` from the bar's bottom
                // edge so the command palette popover anchors right
                // below it (same axis the inline backlog card used).
                .background(
                    GeometryReader { geo in
                        Color.clear.preference(
                            key: OptimizerBottomKey.self,
                            value: geo.frame(in: .named(menuBarRootCoordinateSpace)).maxY
                        )
                    }
                )
                .padding(.horizontal, DS.Spacing.contentMargin)
                // Density pass: 12pt → 8pt above the SmartActions bar.
                // The header below the separator already has its own
                // bar material as a visual frame, so the gap can read
                // as «one short breath» rather than «section break».
                .padding(.top, DS.Spacing.sm)
            }

            // J-Triage status line — one-glance answer to «what now /
            // what's next / how many overdue». Auto-hides when there's
            // nothing to surface so the calm screen stays calm.
            nowNextLine

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
            // Thin separator between the controls cluster above
            // (SmartActions + nowNextLine) and the scrolling timeline
            // below. The sticky day-section header has its own
            // skinBarBackground that handles inter-day division inside
            // the scroll view; this rule is just the controls/content
            // boundary, so 8pt of breathing room is plenty — the
            // previous 12pt was set when a Backlog card lived above and
            // needed a heavier gap.
            SkinSeparator()
                .padding(.horizontal, DS.Spacing.contentMargin)
                .padding(.top, DS.Spacing.sm)

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
                    // Cold start: while the first sync is running, surface a
                    // brief «Syncing calendars…» panel instead of jumping
                    // straight to the empty state. Without this the popover
                    // reads identically to «no events scheduled today», and
                    // the user has no signal that anything is loading.
                    // Birman: «constant gentle feedback».
                    if showSyncingState {
                        syncingState
                    } else {
                        EmptyState(
                            pendingTaskCount: pendingTaskCount,
                            subtitle: emptyStateSubtitle,
                            showCalendarSettingsLink: calendarHasAccess && settings.isCalendarSyncEnabled,
                            onAddEvent: { navigation = .addEvent() },
                            onAdjustCalendars: {
                                SettingsViewModel.pendingPane = .calendars
                                openSettings()
                                NSApp.activate()
                            }
                        )
                    }
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

    /// Dynamic header title showing today's progress and time until next event.
    /// Date for the popover header — «Tuesday, 6 May» (locale-aware via
    /// `DS.daySectionFormatter`). Reads `nowTick` so it rolls over at
    /// midnight without a manual refresh.
    private var headerTitle: String {
        DS.daySectionFormatter.string(from: nowTick)
    }

    /// Quiet meta line under the date — count + next-event countdown,
    /// matching the design-system rhythm: «5 events · next in 5 h 18 min».
    /// Falls back to «No events today» when the day is empty and to
    /// «All N done» when nothing upcoming remains.
    private var headerSubtitle: String {
        let cal = Calendar.current
        let now = nowTick
        guard let todayGroup = reminderService.eventsByDay.first(where: { cal.isDateInToday($0.date) }) else {
            return "No events today"
        }
        let todayEvents = todayGroup.events.filter { !reminderService.disintegratingEventIDs.contains($0.id) }
        let total = todayEvents.count
        guard total > 0 else { return "No events today" }

        let done = todayEvents.filter { $0.endDate <= now }.count

        let nextSuffix: String = {
            guard let next = todayEvents.first(where: { $0.startDate > now }) else { return "" }
            let mins = Int(next.startDate.timeIntervalSince(now)) / 60
            if mins < 1 { return " \u{00B7} now" }
            if mins < 60 { return " \u{00B7} next in\u{00A0}\(mins)\u{00A0}min" }
            let h = mins / 60
            let m = mins % 60
            if m == 0 { return " \u{00B7} next in\u{00A0}\(h)\u{00A0}h" }
            return " \u{00B7} next in\u{00A0}\(h)\u{00A0}h\u{00A0}\(m)\u{00A0}min"
        }()

        let countLabel: String
        if done == 0 {
            countLabel = total == 1 ? "1\u{00A0}event" : "\(total)\u{00A0}events"
        } else if done == total {
            countLabel = "All\u{00A0}\(total) done"
        } else {
            countLabel = "\(done)\u{00A0}of\u{00A0}\(total)"
        }
        return "\(countLabel)\(nextSuffix)"
    }

    /// Meta string for a per-day section header — quiet «next in 12 min»
    /// for today, nothing for past or future days. Suffix-only: the count
    /// badge already carries the event total, so the meta doesn't repeat
    /// it.
    private func dayHeaderMeta(for events: [CalendarEvent], on date: Date) -> String? {
        let cal = Calendar.current
        guard cal.isDateInToday(date) else { return nil }

        let now = nowTick
        let visibleEvents = events.filter { !reminderService.disintegratingEventIDs.contains($0.id) }
        guard !visibleEvents.isEmpty else { return nil }

        guard let next = visibleEvents.first(where: { $0.startDate > now }) else {
            return "all done"
        }
        let mins = Int(next.startDate.timeIntervalSince(now)) / 60
        if mins < 1 { return "now" }
        if mins < 60 { return "next in\u{00A0}\(mins)\u{00A0}min" }
        let h = mins / 60
        let m = mins % 60
        if m == 0 { return "next in\u{00A0}\(h)\u{00A0}h" }
        return "next in\u{00A0}\(h)\u{00A0}h\u{00A0}\(m)\u{00A0}min"
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

    /// Whether the «Syncing calendars…» panel should replace the empty
    /// state on cold start. Active while we've kicked off a sync but
    /// haven't yet seen any events arrive AND haven't escalated to the
    /// «taking long» message via the 3\u{00A0}s timeout. Permission
    /// banners (no access) take precedence — the empty popover with a
    /// permission banner already explains itself.
    private var showSyncingState: Bool {
        guard hasStartedSync else { return false }
        guard !initialSyncDataArrived else { return false }
        // Don't shadow the existing permission banner — it already names
        // the cause and offers a fix.
        guard permissionBannerSpecs.isEmpty else { return false }
        return reminderService.allEvents.isEmpty
    }

    /// Cold-start sync panel — quiet `ProgressView` + caption. After
    /// 3\u{00A0}s without data the caption escalates to a long-running
    /// hint with a link to the system Calendars settings.
    @ViewBuilder
    private var syncingState: some View {
        VStack(spacing: DS.Spacing.md) {
            ProgressView()
                .controlSize(.regular)
            if initialSyncTimeoutFired {
                VStack(spacing: DS.Spacing.xs) {
                    Text("Sync is taking longer than usual.")
                        .font(.subheadline)
                        .foregroundStyle(skin.resolvedTextSecondary)
                    Button {
                        Haptics.tap()
                        SettingsViewModel.pendingPane = .calendars
                        openSettings()
                        NSApp.activate()
                    } label: {
                        Text("Check Calendar Settings \u{2192}")
                            .font(.footnote.weight(.medium))
                            .foregroundStyle(skin.accentColor)
                    }
                    .buttonStyle(.plain)
                }
            } else {
                Text("Syncing calendars\u{2026}")
                    .font(.subheadline)
                    .foregroundStyle(skin.resolvedTextSecondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.vertical, DS.Spacing.xxl)
        .transition(.opacity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(initialSyncTimeoutFired
            ? "Sync is taking longer than usual. Tap to check Calendar settings."
            : "Syncing calendars")
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
            // sibling spacing between sections plus the bar background
            // on the sticky day-section header (the previous explicit
            // `SkinSeparator` between groups is gone — the header's
            // tinted material now does the divider's work).
            // Density pass: 16pt → 12pt between day groups. Gestalt
            // (outer > inner) still holds because day rows themselves run
            // at 4pt vertical padding, so 12pt outer reads as a clear day
            // boundary without burning a third of every popover height on
            // gaps. Birman: density is respect for attention.
            LazyVStack(alignment: .leading, spacing: DS.Spacing.md, pinnedViews: [.sectionHeaders]) {
                // Energy check-in banner — wellness prompt with its own
                // 1–5 input affordance. Surfaces only when a check-in
                // is due so the calm timeline isn't constantly
                // capturing attention.
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
                }

                // End-of-workday roll-forward nudge — surfaces once
                // the user opens Bubo after `workingHours.upperBound`
                // and there are tasks scheduled for today that
                // haven't been completed. One tap unschedules them
                // back to the backlog with a unified undo toast.
                if shouldShowRollForward {
                    RollForwardBanner(
                        unfinishedCount: unfinishedTodayCount,
                        onRoll: {
                            performRollForward()
                        },
                        onDismiss: {
                            withAnimation(DS.Animation.quick) {
                                rollForwardDismissedDay = Calendar.current.startOfDay(for: nowTick)
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
                    // `Section` + LazyVStack's `pinnedViews:
                    // [.sectionHeaders]` keeps the day title pinned to
                    // the top of the popover scroll area until the
                    // next day's header pushes it out — mirrors the
                    // prototype's `position: sticky` day-headers and
                    // gives the user a constant «what day am I
                    // reading» landmark when scanning the timeline.
                    // The bar background on `dayGroupHeader` keeps
                    // text readable while events scroll under it; the
                    // visual it produces also subsumes the previous
                    // explicit SkinSeparator between day groups.
                    Section {
                        // Density pass: wrap the day's interior in its own
                        // VStack so intra-day rows sit on a 4pt rhythm
                        // (prototype `.day-section .events { gap: 4px }`)
                        // while inter-day spacing stays at the LazyVStack's
                        // 12pt, preserving Gestalt outer > inner. Without
                        // this wrapper the LazyVStack's spacing applied to
                        // every direct child including event rows, which
                        // pushed each day's interior into the same airy
                        // 12pt as the gaps between days.
                        VStack(alignment: .leading, spacing: DS.Spacing.xs) {
                            dayGroupSection(
                                dayGroup,
                                showDragHintOnFirstSlot: backlogHasPending && dayGroup.date == firstDayDate
                            )
                        }
                    } header: {
                        dayGroupHeader(dayGroup)
                    }
                }

                // «Load more days» footer — extends the timeline horizon
                // by one week per tap up to `extraDaysCap`. New days
                // appear below; existing scroll position is preserved
                // by `scrollPosition(id:)` so the user stays anchored
                // to whatever they were reading.
                if extraDaysShown < Self.extraDaysCap {
                    LoadMoreDaysButton {
                        withAnimation(DS.Animation.smoothSpring) {
                            extraDaysShown = min(Self.extraDaysCap, extraDaysShown + 7)
                        }
                    }
                }
            }
            .padding(.horizontal, DS.Spacing.contentMargin)
            // Density pass: 12pt → 8pt outer vertical padding so the first
            // event row sits closer to the day-section heading and the
            // last row sits closer to the footer. The list interior keeps
            // its own 4pt row gap, the section heading already adds xxs
            // top padding, so 8pt here matches the prototype's tight
            // top/bottom rhythm without crowding the controls.
            .padding(.vertical, DS.Spacing.sm)
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

    /// Sticky section header for one day in the timeline. Carries the
    /// scroll anchor (`.id(date)`) used by the popover header's day-nav
    /// cluster, and a skin-tinted bar material so the header stays
    /// readable while events scroll under it inside the LazyVStack's
    /// `pinnedViews: [.sectionHeaders]` mode. Mirrors the prototype's
    /// `.day-header { position: sticky; top: 0; }` treatment.
    @ViewBuilder
    private func dayGroupHeader(_ dayGroup: (date: Date, events: [CalendarEvent])) -> some View {
        let visibleCount = visibleEventCount(for: dayGroup.events)
        DaySectionHeader(
            date: dayGroup.date,
            count: visibleCount,
            meta: dayHeaderMeta(for: dayGroup.events, on: dayGroup.date),
            workingHours: optimizerService.workingHours
        )
            .id(dayGroup.date)
            .padding(.horizontal, DS.Spacing.sm)
            .padding(.vertical, DS.Spacing.xxs)
            .frame(maxWidth: .infinity, alignment: .leading)
            .skinBarBackground(activeSkin)
    }

    @ViewBuilder
    private func dayGroupSection(
        _ dayGroup: (date: Date, events: [CalendarEvent]),
        showDragHintOnFirstSlot: Bool = false
    ) -> some View {
        // The day-section header is now rendered by `dayGroupHeader` as
        // the sticky section heading in the LazyVStack — it scroll-pins
        // to the top of the popover while this content scrolls under
        // it. Everything below stays as the day's interior content.

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
        // The NOW divider only belongs on today's section, and only when
        // the wall clock falls inside the working-hours bracket. Outside
        // that bracket — before work starts, after work ends — the
        // marker reads as a glitch: a red rule above «Working hours
        // start 09:00» when it's 00:46 invites the question «why is NOW
        // here?». The marker is anchored to the timeline of the working
        // day; if you're outside the day, the menu-bar clock is the
        // canonical answer. Pass `nowTick` so the marker re-renders on
        // the same minute-granular cadence every other countdown reads
        // from.
        let nowMarker: Date? = {
            guard Calendar.current.isDateInToday(dayGroup.date) else { return nil }
            let cal = Calendar.current
            let wh = optimizerService.workingHours
            guard
                let dayStart = cal.date(bySettingHour: wh.lowerBound, minute: 0, second: 0, of: dayGroup.date),
                let dayEnd = cal.date(bySettingHour: wh.upperBound, minute: 0, second: 0, of: dayGroup.date)
            else { return nil }
            return (nowTick >= dayStart && nowTick <= dayEnd) ? nowTick : nil
        }()
        let interleaved = interleave(
            events: dayGroup.events,
            freeSlots: freeSlots,
            ghost: ghost,
            includeEvents: freeSlotFilter != .onlyFree,
            nowMarker: nowMarker
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
        // share the vertical space. One header > N thin slivers — Birman:
        // «collapse into a heading row instead of shrinking everything proportionally».
        // Working-hours start boundary — interactive on today (drag +
        // chevron steps), informational on other days (same visual
        // bracket, no controls). Suppressed on today only while the
        // user is dragging a backlog task: the drag-mode collapse
        // stands in for the day's contents and a draggable handle
        // would compete with the drop targets.
        let dayIsToday = Calendar.current.isDateInToday(dayGroup.date)
        if !(dayIsToday && backlogCoordinator.isDraggingTask) {
            WorkingHoursBoundaryRow(
                kind: .start,
                hour: optimizerService.workingHoursStart,
                isInteractive: dayIsToday,
                onStep: { delta in
                    guard dayIsToday else { return }
                    let proposed = optimizerService.workingHoursStart + delta
                    optimizerService.workingHoursStart = max(0, min(22, proposed))
                }
            )
        }

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
                    onRenameLocal: { event, newTitle in
                        // Inline rename: route to `updateLocalEvent` against
                        // the root event. For an expanded occurrence
                        // (`seriesId != nil`) we look the root up by series
                        // id, since `localEvents` only stores root events
                        // and `updateLocalEvent` matches by id.
                        let rootId = event.seriesId ?? event.id
                        guard var root = reminderService.localEvents.first(where: { $0.id == rootId }) else { return }
                        root.title = newTitle
                        reminderService.updateLocalEvent(root)
                        toastState.showSuccess("Renamed to \u{201C}\(newTitle)\u{201D}", icon: "pencil")
                    },
                    onReschedule: { event, deltaMinutes in
                        // Drag-to-reschedule uses the existing snooze path,
                        // which already shifts both `startDate` and `endDate`
                        // by the same delta. Negative deltas (drag up =
                        // earlier) are handled by `addingTimeInterval`. The
                        // row gates this to local non-recurring upcoming
                        // events, so the local-only branch in `snoozeReminder`
                        // is the one that runs.
                        //
                        // J6: when Option (⌥) is held at gesture commit, we
                        // ALSO ripple-shift every later event on the same
                        // calendar day by the same delta, so a knock-on
                        // schedule change moves with the user instead of
                        // colliding into them. Read the modifier state
                        // synchronously — `NSEvent.modifierFlags` reflects
                        // the live keyboard state at the moment this
                        // handler runs.
                        let optionHeld = NSEvent.modifierFlags.contains(.option)
                        reminderService.snoozeReminder(for: event, minutes: deltaMinutes)

                        var rippledIds: [String] = []
                        if optionHeld {
                            rippledIds = rippleShiftLaterEvents(after: event, minutes: deltaMinutes)
                        }

                        let signed = deltaMinutes > 0 ? "+\(deltaMinutes)\u{00A0}min" : "\(deltaMinutes)\u{00A0}min"
                        let headline = rippledIds.isEmpty
                            ? "Rescheduled (\(signed))"
                            : "Rescheduled (\(signed)) · rippled \(rippledIds.count)"
                        let eventId = event.id
                        toastState.showSuccess(headline, icon: "arrow.up.and.down.circle.fill") {
                            // Undo: re-fetch the current event so we shift
                            // the post-snooze dates back, not the captured
                            // pre-snooze ones (which would compound).
                            if let current = reminderService.localEvents.first(where: { $0.id == eventId }) {
                                reminderService.snoozeReminder(for: current, minutes: -deltaMinutes)
                            }
                            // Reverse the ripple in the same order; same
                            // re-fetch caveat as above.
                            for id in rippledIds {
                                if let current = reminderService.localEvents.first(where: { $0.id == id }) {
                                    reminderService.snoozeReminder(for: current, minutes: -deltaMinutes)
                                }
                            }
                        }
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
                            paletteContext = MenuBarPaletteContext(seedEvent: event)
                        }
                    },
                    onSplitTask: { _ in
                        withAnimation(DS.Animation.quick) {
                            paletteContext = MenuBarPaletteContext(seedRecipeId: "split-task")
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
                            paletteContext = MenuBarPaletteContext(seedEvent: event, seedRecipeId: "prep-meeting")
                        }
                    },
                    onAddPrepQuick: { event, minutes in
                        // One-tap meetingPrep: scope to this event,
                        // fixed minutes, run through the same toast +
                        // undo pipe as other quick-actions. Toast label
                        // says «N min prep before <title>» so the user
                        // sees what was just inserted.
                        Task {
                            var req = OptimizationRequest(name: "Add prep")
                            req.add(.onlyOptimize(eventIds: [event.id]))
                            req.add(.meetingPrep(minutes: minutes))
                            let trimmed = event.title.count > 24
                                ? String(event.title.prefix(24)) + "\u{2026}"
                                : event.title
                            await runQuickAction(req, label: "\(minutes)\u{00A0}min prep before \u{201C}\(trimmed)\u{201D}")
                        }
                    },
                    flexPercent: optimizerService.flex(eventId: event.id),
                    onSetFlex: { event, percent in
                        // Persist the per-event flex preference. Doesn't
                        // run the optimizer immediately — flex applies
                        // when the user explicitly scopes a Run to this
                        // event (Reschedule from the row's other menu
                        // items, or via the palette). Birman: persist
                        // intent here; act on it where the user runs.
                        optimizerService.setFlex(percent: percent, eventId: event.id)
                    },
                    onConvertToPomodoro: { event in
                        convertEventToPomodoro(event)
                    },
                    onRepeatLikeThis: { event in
                        // Pre-fill `AddEventView` with the shape of the
                        // current event so the user lands on a fresh
                        // draft instead of typing duration / location /
                        // reminders again. The clone strips id,
                        // recurrence, calendar binding, and series
                        // metadata — see `cloneAsDraft(_:)`.
                        let draft = cloneAsDraft(event)
                        navigation = .addEvent(
                            editing: nil,
                            initialType: draft.eventType,
                            prefillFrom: draft
                        )
                    },
                    isLocked: optimizerService.isLocked(eventId: event.id),
                    onToggleLock: { event in
                        // Persistent toggle in `OptimizerService`. Next
                        // optimizer run reads `lockedEventIds` and
                        // injects an implicit `.keepFixed(...)` so the
                        // GA leaves this event alone. Local Bubo events
                        // benefit the most — Apple-Calendar events the
                        // user can't move from inside the app anyway.
                        withAnimation(DS.Animation.quick) {
                            optimizerService.toggleLock(eventId: event.id)
                        }
                    },
                    isExcluded: optimizerService.isExcluded(eventId: event.id),
                    onToggleExclude: { event in
                        // Excluded events are absent from the optimizer's
                        // input — useful when the user is planning around
                        // a meeting they might cancel. Same persistent-
                        // set + auto-inject pattern as lock.
                        withAnimation(DS.Animation.quick) {
                            optimizerService.toggleExclude(eventId: event.id)
                        }
                    },
                    energyAtStartHour: optimizerService.energyCheckInService?
                        .predictEnergy(atHour: Calendar.current.component(.hour, from: event.startDate)),
                    isFreshlyCreated: optimizerService.freshlyCreatedEventIds.contains(event.id),
                    isHappeningNow: nowTick >= event.startDate && nowTick < event.endDate
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
                        // Legacy fallback — `FreeSlotRow` skips this
                        // when picker callbacks below are wired (which
                        // they are here). Kept as no-op so the API
                        // stays satisfied without dead branches.
                        onFillTapped: { _ in },
                        onTaskDropped: { drag in
                            handleTaskDrop(drag: drag, slotStart: start, slotEnd: end)
                        },
                        // Slot picker — primary entry point for the «+»
                        // tap. Replaces the legacy command-palette
                        // seeding flow with an inline pick-or-create
                        // surface anchored on the slot itself. Birman:
                        // «direct action at the site of the problem».
                        pickerTasks: optimizerService.backlogService?.pending ?? [],
                        pickerAdjacentEvents: dayGroup.events,
                        onCommitSlotPicks: { items in
                            scheduleSlotPickerBatch(
                                items: items,
                                slotStart: start,
                                slotEnd: end
                            )
                        },
                        onOpenFullscreenBacklog: {
                            withAnimation(DS.Animation.quick) {
                                navigation = .backlog
                            }
                        },
                        canShowDragHint: item.id == hintSlotId,
                        topBacklogCandidate: topBacklogCandidate(forSlotMinutes: Int(end.timeIntervalSince(start) / 60)),
                        onStartTopTask: { drag in
                            handleTaskDrop(drag: drag, slotStart: start, slotEnd: end)
                        },
                        onStartPomodoro: { slotStart, slotEnd in
                            startPomodoroInSlot(start: slotStart, end: slotEnd)
                        },
                        onLockAsFocus: { slotStart, slotEnd in
                            fillSlotWithFocus(start: slotStart, end: slotEnd)
                        }
                    )
                }
            case .ghost(let start, let end, let title):
                GhostEventRow(start: start, end: end, title: title)
                    .transition(.opacity.combined(with: .scale(scale: 0.96)))
            case .nowMarker(let stamp):
                nowMarkerRow(stamp)
            }
        }

        // Working-hours end boundary — paired with the start handle
        // above. Together they bracket the day's events so the user
        // can see, drag, and step the working window directly on
        // the timeline rather than burying it in settings. Birman:
        // «rules are objects on the screen». Same interactive-on-today,
        // informational-on-other-days policy as the start handle.
        if !(dayIsToday && backlogCoordinator.isDraggingTask) {
            WorkingHoursBoundaryRow(
                kind: .end,
                hour: optimizerService.workingHoursEnd,
                isInteractive: dayIsToday,
                onStep: { delta in
                    guard dayIsToday else { return }
                    let proposed = optimizerService.workingHoursEnd + delta
                    optimizerService.workingHoursEnd = max(1, min(23, proposed))
                }
            )
        }

        // After-hours / wind-down marker for today: when the latest
        // event ends past `workingHours.upperBound`, surface a quiet
        // «After hours» caption BELOW the boundary handle (so the
        // handle separates the inside-hours region from the after-
        // hours one). Reifies the optimizer's `noEventsAfter` /
        // `windDown` family at the surface where it actually matters —
        // past the boundary, the user sees that the schedule has
        // spilled into protected time. Today only.
        if Calendar.current.isDateInToday(dayGroup.date),
           let lastEvent = dayGroup.events.last,
           Calendar.current.component(.hour, from: lastEvent.endDate) >= optimizerService.workingHours.upperBound {
            HStack(spacing: DS.Spacing.xs) {
                Image(systemName: "moon.zzz")
                    .font(.footnote)
                    .foregroundStyle(skin.resolvedTextTertiary)
                Text("After hours")
                    .font(DS.Typography.machineHint)
                    .foregroundStyle(skin.resolvedTextTertiary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, DS.Spacing.sm)
            .padding(.top, DS.Spacing.xxs)
            .accessibilityLabel("After working hours")
        }
    }

    /// One-line collapsed summary of a day's events — rendered in place
    /// of the individual `EventRowView`s while the user is dragging a
    /// backlog task. Free slots remain visible as drop targets, so the
    /// timeline area reduces to «where it's busy + where you can put it».
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
            Text("\(events.count)\u{00A0}event\(events.count == 1 ? "" : "s") · \(DS.formatMinutes(bookedMinutes)) booked")
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

    // `DayListItem` extracted to file scope in `Views/MenuBarDayListItem.swift`
    // — see `MenuBarDayListItem`.

    /// Interleaves events, free-slot pairs, and the optional ghost preview
    /// chronologically so the list reads top-to-bottom like a real timeline.
    private func interleave(
        events: [CalendarEvent],
        freeSlots: [(start: Date, end: Date)],
        ghost: (start: Date, end: Date, title: String)? = nil,
        includeEvents: Bool = true,
        nowMarker: Date? = nil
    ) -> [MenuBarDayListItem] {
        var result: [MenuBarDayListItem] = includeEvents ? events.map(MenuBarDayListItem.event) : []
        result += freeSlots.map { MenuBarDayListItem.slot($0.start, $0.end) }
        if let ghost {
            result.append(.ghost(ghost.start, ghost.end, ghost.title))
        }
        // Only insert the marker when there's something else to anchor
        // it against — a solo red rule on an otherwise empty day reads
        // as a glitch, not a status indicator.
        if let nowMarker, !result.isEmpty {
            result.append(.nowMarker(nowMarker))
        }
        result.sort { startOf($0) < startOf($1) }
        return result
    }

    private func startOf(_ item: MenuBarDayListItem) -> Date {
        switch item {
        case .event(let e): return e.startDate
        case .slot(let s, _): return s
        case .ghost(let s, _, _): return s
        case .nowMarker(let d): return d
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

    // The `SmartBanner` deduplication helpers (`suggestionToQuickActionIDs`,
    // `isSuggestionSurfacedInQuickActions`, `activeBannerSuggestion`) were
    // removed along with the banner itself. The single ranked candidate
    // from `optimizerService.suggestionEngine?.suggestion` is now consumed
    // directly by the `SmartActions` row inside the Backlog card — there
    // is no second optimizer surface to dedupe against, so the suppression
    // table is moot.

    /// Execute a request immediately — no palette, no configuration.
    /// One tap → done → undo toast. Birman: "sequential magic."
    ///
    /// Async so callers (e.g. the spill-over marker action-link) can await
    /// and surface a loading spinner during the optimizer call. Fire-and-
    // MARK: - Auto Defer

    /// Schedule a one-shot Timer that fires ~1 minute past midnight to
    /// re-run AutoDefer for users who leave the popover open overnight.
    /// `runAutoDeferIfNeeded` is the only consumer; the timer reschedules
    /// itself to the next midnight after each fire.
    ///
    /// Idempotent — calling twice doesn't stack timers; the second call
    /// drops out because `dayRolloverTimer != nil`. Cleared by
    /// `onDisappear` so a popover dismissal doesn't leak it.
    @MainActor
    private func scheduleDayRolloverTimerIfNeeded() {
        guard dayRolloverTimer == nil else { return }
        scheduleNextDayRollover()
    }

    @MainActor
    private func scheduleNextDayRollover() {
        let cal = Calendar.current
        let now = Date()
        let startOfTomorrow = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: now)) ?? now
        // Sleep ~60s past midnight so we cross the boundary cleanly,
        // not at the exact second of rollover (where small clock drift
        // could land us back on the previous day).
        let fireDate = startOfTomorrow.addingTimeInterval(60)
        let interval = max(60, fireDate.timeIntervalSinceNow)

        dayRolloverTimer?.invalidate()
        dayRolloverTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { _ in
            // Hop to the main actor — Timer callbacks land on the run
            // loop's actor (typically not @MainActor).
            Task { @MainActor in
                runAutoDeferIfNeeded()
                // Reschedule for the next day. Recursive call is safe:
                // each iteration creates one timer; the prior is
                // invalidated by `dayRolloverTimer?.invalidate()` above.
                scheduleNextDayRollover()
            }
        }
    }

    /// Run the once-per-day backlog deferral pass. Wired from `onAppear`
    /// so every popover open during a fresh calendar day catches up the
    /// overdue tasks; the service itself early-exits when today's run
    /// already happened. The toast threading mirrors `runQuickAction`'s
    /// undo channel — same `arrow.uturn.backward` icon language as the
    /// optimizer's reversible operations.
    @MainActor
    private func runAutoDeferIfNeeded() {
        guard let backlog = optimizerService.backlogService else { return }
        // Take the same once-a-day hook to prune stale per-event
        // constraints (locks / exclusions whose events have been
        // deleted upstream). Keeps the persistent sets from
        // accumulating dead ids — see `pruneStaleEventConstraints`.
        optimizerService.pruneStaleEventConstraints(reminderService: reminderService)

        let service = AutoDeferService(backlogService: backlog)
        let report = service.runIfNeeded()
        guard report.count > 0 else { return }
        let headline = report.count == 1
            ? "1 overdue task moved to tomorrow"
            : "\(report.count) overdue tasks moved to tomorrow"
        toastState.showSuccess(headline, icon: "arrow.uturn.backward") {
            // Undo runs the captured restore closure on the main actor.
            // Wrapping the call in `Task` lets us keep the toast's
            // synchronous Undo signature without forcing AutoDefer to
            // expose a sync rollback path.
            Task { await report.undo() }
        }
    }

    // MARK: - End-of-Day Banner (J10)

    /// J10 placement gate. Visible only when:
    ///   1. The day has already crossed `workingHours.upperBound` (so the
    ///      banner doesn't pop up at lunch), AND
    ///   2. The user hasn't dismissed it for today yet, AND
    ///   3. There's actual unfinished work to carry — pending tasks the
    ///      user has likely been ignoring through the day.
    private var shouldShowEndOfDayBanner: Bool {
        let cal = Calendar.current
        let now = Date()
        let currentHour = cal.component(.hour, from: now)
        let currentMinute = cal.component(.minute, from: now)
        // A whole-hour comparison reads "after 18:00" as currentHour >=
        // workingHoursEnd; the minute check keeps the banner from
        // appearing right at the boundary on the dot — wait until 5 min
        // past the close, so a popover open at exactly the bell doesn't
        // greet the user with a wind-down nag.
        let pastEnd = currentHour > optimizerService.workingHoursEnd
            || (currentHour == optimizerService.workingHoursEnd && currentMinute >= 5)
        guard pastEnd else { return false }
        guard eodDismissedDay != Self.dayKey(for: now) else { return false }
        return eodUnfinishedCount > 0
    }

    /// Number of pending backlog tasks at the moment the banner is
    /// rendered. Excludes scheduled / done / frozen — only the rows the
    /// user would actually want pushed forward.
    private var eodUnfinishedCount: Int {
        optimizerService.backlogService?.pending.count ?? 0
    }

    /// Stamp the current calendar day as «banner dismissed» — the
    /// `@AppStorage` write triggers a re-render, the gate above flips
    /// false, and the banner fades. Resets implicitly tomorrow because
    /// the day-key string no longer matches.
    private func dismissEndOfDayBannerForToday() {
        eodDismissedDay = Self.dayKey(for: Date())
    }

    /// J10: bulk carry-forward. Each pending task gets its `createdAt`
    /// refreshed (so «stale» logic doesn't punish it on day N+1) and a
    /// single undo toast restores the prior `createdAt` values atomically.
    /// Doesn't touch deadlines or schedule slots — those are deliberate
    /// commitments, not «didn't get to it today» drift.
    private func carryUnfinishedToTomorrow() {
        guard let backlog = optimizerService.backlogService else { return }
        let now = Date()
        let pending = backlog.pending
        guard !pending.isEmpty else { return }

        // Snapshot pre-carry state so undo restores `createdAt` exactly.
        let snapshots = pending.map { $0 }

        for var task in pending {
            task.createdAt = now
            backlog.updateTask(task)
        }

        let count = snapshots.count
        let headline = count == 1
            ? "Carried 1\u{00A0}task to tomorrow"
            : "Carried \(count)\u{00A0}tasks to tomorrow"
        toastState.showSuccess(headline, icon: "arrow.uturn.backward") {
            for original in snapshots {
                backlog.updateTask(original)
            }
        }
        dismissEndOfDayBannerForToday()
    }

    /// Compact «YYYY-MM-DD» key used to scope the banner's dismissal to
    /// a single calendar day. Locale-independent (we don't want a
    /// locale change between sessions to resurrect the banner). Static
    /// so the same formatter is reused across calls.
    private static let dayKeyFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private static func dayKey(for date: Date) -> String {
        dayKeyFormatter.string(from: date)
    }

    /// forget callers wrap in `Task { ... }`.
    @MainActor
    private func runQuickAction(_ request: OptimizationRequest, label: String) async {
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

    private var footerActions: some View {
        // PRINCIPLES §1 — one primary action, dominant. Add (primary) sits
        // on the leading edge with full accent weight. Tasks and More share
        // the trailing edge with one subdued borderless style. A screen
        // with two equally loud buttons is a bug.
        HStack {
            // Primary CTA — `.flexible` size = minWidth 100, lg internal
            // horizontal padding. AddEventView's primary uses the same
            // treatment so both screens' primary actions carry equal
            // weight.
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
                    navigation = .backlog
                } label: {
                    Label("New Task   \u{21E7}\u{2318}N", systemImage: "plus.circle")
                }
            } label: {
                // «Add event» mirrors the prototype's
                // `ui_kits/menubar/index.html` `.add-btn` copy. The
                // primary action of this Menu button IS the new-event
                // form (⌘N) — `New Task` lives as a secondary menu
                // item below — so naming the loud button after its
                // primary verb tells the eye what tapping does. The
                // generic «Add» reading under-promised the dominant
                // action and over-promised parity with «Tasks» (a
                // navigation, not a verb).
                Label("Add event", systemImage: "plus")
            } primaryAction: {
                Haptics.tap()
                navigation = .addEvent()
            }
            .buttonStyle(.action(role: .primary))
            .help("Add a new event (\u{2318}N)")
            .keyboardShortcut("n", modifiers: .command)

            Spacer()

            // Tasks — secondary, borderless. Routes to the backlog screen
            // where task creation lives in its own composer. PRINCIPLES §1:
            // shares the trailing edge with `More` under a single style.
            Button {
                Haptics.tap()
                navigation = .backlog
            } label: {
                Text("Tasks")
            }
            .buttonStyle(.borderless)
            // PRINCIPLES §8: type sizes come from macOS text styles, not
            // hand-tuned points. `subheadline` reads one step below the
            // primary `Add` and pairs with the same subdued role for
            // `More` next to it (§1: one borderless voice on the
            // trailing edge).
            .font(.system(.subheadline, design: skin.resolvedFontDesign, weight: .medium))
            .foregroundStyle(skin.resolvedTextSecondary)
            .keyboardShortcut("t", modifiers: .command)
            .help("Open backlog (\u{2318}T)")

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
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            // PRINCIPLES §8: replace hand-tuned 14pt with the macOS
            // `subheadline` style so the trailing edge speaks one
            // consistent voice with the `Tasks` button next to it.
            .font(.system(.subheadline, design: skin.resolvedFontDesign, weight: .medium))
            .foregroundStyle(skin.resolvedTextSecondary)
            .symbolRenderingMode(.monochrome)
            .tint(activeSkin.resolvedToolbarTint)
            .help("More")
        }
        .padding(.horizontal, DS.Spacing.contentMargin)
        .frame(height: DS.Size.actionFooterHeight)
        .skinBarBackground(activeSkin)
    }
}

// Sub-components and preference keys extracted to dedicated files:
//   - `Views/Components/OpenSettingsButton.swift`
//   - `Views/Components/PermissionBanners.swift`
//   - `Views/MenuBarPreferenceKeys.swift`
