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
    @State var dayRolloverTimer: Timer? = nil
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
    @State var toastState = ToastState()
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
    @State var extraDaysShown: Int = 0

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
    @State var colorFilter: EventColorTag? = nil
    /// Mutually exclusive with `colorFilter`. Tri-state cycle on the hollow
    /// dot button: `.all` (default) → `.onlyFree` (hide events, show only
    /// free slots so users can eyeball open time) → `.hideFree` (show events,
    /// hide the "Free · Xh" rows for a compact busy-day read).
    @State var freeSlotFilter: FreeSlotFilter = .all

    /// Shared state for backlog drag-to-schedule + ghost-preview. Owned here
    /// because both the drag source (BacklogView) and the drop targets
    /// (FreeSlotRow instances scattered across the day list) need it, and the
    /// ghost block on the timeline is rendered by this view.
    @State var backlogCoordinator = BacklogInteractionCoordinator()

    /// Per-minute time tick used to drive the «happening now» highlight on
    /// `EventRowView`. Updated by the `everyMinuteTimer` subscription so
    /// every row in the day can read a single shared `Date` instead of
    /// each instantiating its own timer.
    @State var nowTick: Date = Date()
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
    @State var rollForwardDismissedDay: Date? = nil

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
    @AppStorage("BuboEODBannerDismissedDay") var eodDismissedDay: String = ""

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


    // Timeline shaping helpers (`filteredEventsByDay`,
    // `timelineEventsByDay`, `visibleEventCount`, `timelineDays`) live
    // in `MenuBarView+Timeline.swift`.

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

    func notifyScheduleChange(deleted eventId: String? = nil, created: Bool = false) {
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

    // Pomodoro conversion + slot helpers (cloneAsDraft, ripple-shift,
    // topBacklogCandidate, startPomodoroInSlot) live in
    // `MenuBarView+Pomodoro.swift`.

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

    // Roll-forward (J-Recover), focus-slot fill and overdue rescheduling
    // live in `MenuBarView+RollForward.swift`.

    // Inline backlog drop / schedule helpers (`handleTaskDrop`,
    // `scheduleBacklogTask`, `scheduleSlotPickerBatch`) live in
    // `MenuBarView+BacklogDrop.swift`.

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
            let nowNext = NowNextLine(
                events: todaysEventsForNowNext,
                now: nowTick,
                overdueCount: optimizerService.backlogService?.overdue.count ?? 0,
                onOpenBacklog: { navigation = .backlog }
            )
            if nowNext.hasContent {
                nowNext.padding(.top, DS.Spacing.xs)
            }

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
            // (SmartActions + NowNextLine) and the scrolling timeline
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
            FooterActions(
                navigation: $navigation,
                reminderService: reminderService,
                toastState: toastState,
                activeSkin: activeSkin
            )
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
        EventList(
            scrollPositionID: $scrollPositionID,
            listScrollY: $listScrollY,
            days: timelineDays(),
            extraDaysShown: extraDaysShown,
            extraDaysCap: Self.extraDaysCap,
            onLoadMoreDays: {
                withAnimation(DS.Animation.smoothSpring) {
                    extraDaysShown = min(Self.extraDaysCap, extraDaysShown + 7)
                }
            },
            disintegratingEventIDs: reminderService.disintegratingEventIDs,
            leadingContent: {
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
            },
            dayHeader: { day in
                dayGroupHeader(date: day.date, events: day.events)
            },
            daySection: { day in
                dayGroupSection(day)
            }
        )
    }

    // MARK: - Day Group Section (extracted for release-mode type checker)

    /// Sticky section header for one day in the timeline. Carries the
    /// scroll anchor (`.id(date)`) used by the popover header's day-nav
    /// cluster, and a skin-tinted bar material so the header stays
    /// readable while events scroll under it inside the LazyVStack's
    /// `pinnedViews: [.sectionHeaders]` mode. Mirrors the prototype's
    /// `.day-header { position: sticky; top: 0; }` treatment.
    @ViewBuilder
    private func dayGroupHeader(date: Date, events: [CalendarEvent]) -> some View {
        let visibleCount = visibleEventCount(for: events)
        DaySectionHeader(
            date: date,
            count: visibleCount,
            meta: dayHeaderMeta(for: events, on: date),
            workingHours: optimizerService.workingHours
        )
            .id(date)
            .padding(.horizontal, DS.Spacing.sm)
            .padding(.vertical, DS.Spacing.xxs)
            .frame(maxWidth: .infinity, alignment: .leading)
            .skinBarBackground(activeSkin)
    }

    @ViewBuilder
    private func dayGroupSection(_ day: MenuBarTimelineDay) -> some View {
        // The day-section header is now rendered by `dayGroupHeader` as
        // the sticky section heading in the LazyVStack — it scroll-pins
        // to the top of the popover while this content scrolls under
        // it. Everything below stays as the day's interior content.
        //
        // Filter interaction is resolved upstream in `timelineDays()`:
        // • colorFilter active → events already pruned to one tag, so
        //   `items` carries no free-slot rows (rendering them would be
        //   misleading since other-tag events fill those gaps in the
        //   real timeline).
        // • freeSlotFilter == .onlyFree → events are skipped from
        //   `items`, only the real free slots remain so users can
        //   eyeball open time at a glance.
        // • freeSlotFilter == .hideFree → events stay, free slots are
        //   suppressed so a busy day reads as a compact list.
        //
        // The drag-hint slot id (`day.hintSlotId`) and the local ghost
        // suppression check both live inside `freeSlotRow` since they
        // only affect the `.slot` arm.

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
        let dayIsToday = Calendar.current.isDateInToday(day.date)
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

        if backlogCoordinator.isDraggingTask && !day.events.isEmpty && freeSlotFilter != .onlyFree {
            collapsedEventsHeader(for: day.events)
        }

        ForEach(day.items, id: \.id) { item in
            switch item {
            case .event(let event):
                eventRow(event)
            case .slot(let start, let end):
                freeSlotRow(start: start, end: end, slotId: item.id, day: day)
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
        if dayIsToday,
           let lastEvent = day.events.last,
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

    /// Per-event row inside the day-group switch. Gates on
    /// `backlogCoordinator.isDraggingTask` (the day's contents collapse
    /// behind the `collapsedEventsHeader` so events stop competing with
    /// the free-slot drop targets) and otherwise hands the event to
    /// `EventRowView` wired with every per-row callback the menu-bar
    /// surface needs. Kept on the host so the closures see the full set
    /// of services and @State fields without parameter plumbing — the
    /// goal here is to name the «event row» concern, not to relocate
    /// it. See BODY-SPLIT-PLAN's "next leg of work".
    @ViewBuilder
    private func eventRow(_ event: CalendarEvent) -> some View {
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
    }

    /// Per-free-slot row inside the day-group switch. Resolves the
    /// ghost-suppression gate (skip the "Free · Xh" row whose start
    /// coincides with the active ghost block so we don't double-render
    /// the same time as two rows) and otherwise builds the `FreeSlotRow`
    /// with its drop / slot-picker / pomodoro / focus callbacks wired
    /// against the host's services. `slotId` is the `MenuBarDayListItem`
    /// id used to compare against the day's `hintSlotId` — only the
    /// earliest day's first `.slot` carries that, so at most one row
    /// surfaces the drag-onboarding hint.
    @ViewBuilder
    private func freeSlotRow(
        start: Date,
        end: Date,
        slotId: String,
        day: MenuBarTimelineDay
    ) -> some View {
        // Ghost suppression: when the shared coordinator already
        // has a ghost block starting at this slot's start (user
        // is hovering a dragged task over it, or typing into the
        // backlog input) — skip the "Free · Xh" row so we don't
        // double-render the same time as two rows.
        if let ghost = ghostForDay(day.date), ghost.start == start {
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
                pickerAdjacentEvents: day.events,
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
                canShowDragHint: slotId == day.hintSlotId,
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

    // List-item interleaving (`interleave`, `startOf`, `ghostForDay`)
    // and `DayListItem` live alongside the timeline helpers in
    // `MenuBarView+Timeline.swift` and `Views/MenuBarDayListItem.swift`.

    // Auto-Defer and End-of-Day Banner methods live in
    // `MenuBarView+AutoDefer.swift` — the once-a-day deferral pass and
    // the J10 wind-down banner are a single lifecycle concern.

    /// Execute a request immediately — no palette, no configuration.
    /// One tap → done → undo toast. Birman: "sequential magic."
    ///
    /// Async so callers (e.g. the spill-over marker action-link) can await
    /// and surface a loading spinner during the optimizer call. Fire-and-
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

}

// Sub-components and preference keys extracted to dedicated files:
//   - `Views/Components/OpenSettingsButton.swift`
//   - `Views/Components/PermissionBanners.swift`
//   - `Views/MenuBarPreferenceKeys.swift`
