import SwiftUI
import BuboDomain

// MARK: - Navigation Routes
//
// One `@ViewBuilder` per `MenuBarNavigation` case. The body's
// `switch navigation` block dispatches to these — closures for each
// destination's back / save / delete callbacks live here so the body
// stays a thin dispatcher. Transitions stay close to each destination
// because they're symmetric to its entry edge (list slides from
// leading; everything else from trailing).

extension MenuBarView {

    /// Convenience: standard asymmetric trailing-edge transition used
    /// by every destination except `.list`.
    var trailingDestinationTransition: AnyTransition {
        reduceMotion ? .opacity : .asymmetric(
            insertion: .move(edge: .trailing).combined(with: .opacity),
            removal: .move(edge: .trailing).combined(with: .opacity).combined(with: .scale(scale: 0.98))
        )
    }

    @ViewBuilder
    func listRoute() -> some View {
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
    }

    @ViewBuilder
    func detailRoute(_ event: CalendarEvent) -> some View {
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
        .transition(trailingDestinationTransition)
    }

    @ViewBuilder
    func timerRoute(_ event: CalendarEvent) -> some View {
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
                // Re-fetch the current event so successive scrubs
                // compose correctly. Clamp the new end-date to
                // «now + 60s» so the user can never scrub the timer
                // past the present moment and have it auto-end mid-drag.
                guard var current = reminderService.localEvents.first(where: { $0.id == event.id }) else { return }
                let proposed = current.endDate.addingTimeInterval(TimeInterval(deltaMinutes * 60))
                let floor = Date().addingTimeInterval(60)
                current.endDate = max(proposed, floor)
                reminderService.updateLocalEvent(current)
                let signed = deltaMinutes > 0 ? "+\(deltaMinutes)\u{00A0}min" : "\(deltaMinutes)\u{00A0}min"
                toastState.showSuccess("End time \(signed)", icon: "timer")
            },
            onShiftSchedule: { event, deltaMinutes in
                // J9: vertical-drag pause. Shift BOTH start and end
                // forward by `deltaMinutes`. Undo toast restores
                // the prior schedule.
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
        .transition(trailingDestinationTransition)
    }

    @ViewBuilder
    func addEventRoute(
        editing: CalendarEvent?,
        initialType: EventType,
        prefillFrom: CalendarEvent?
    ) -> some View {
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
        .transition(trailingDestinationTransition)
    }

    @ViewBuilder
    func newTaskRoute(prefillTitle: String, prefillDuration: Int?) -> some View {
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
            .transition(trailingDestinationTransition)
        } else {
            EmptyView()
                .onAppear { navigation = .list }
        }
    }

    @ViewBuilder
    func editTaskRoute(_ task: BacklogTask) -> some View {
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
            .transition(trailingDestinationTransition)
        } else {
            EmptyView()
                .onAppear { navigation = .list }
        }
    }

    @ViewBuilder
    func backlogRoute() -> some View {
        if let backlog = optimizerService.backlogService {
            BacklogFullscreenView(
                backlogService: backlog,
                optimizerService: optimizerService,
                settings: settings,
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
                    // BacklogView's `onScheduleTask`. The optimizer applies
                    // in-place; no pop back to .list.
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
                    // ⌥-click on the row's Schedule button — run the same
                    // per-task request but ask for 5 scenarios and DON'T
                    // apply. The popover lets the user pick which one to commit.
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
                    // Commit a previewed scenario via the service's
                    // dedicated entry point so undo / snapshot bookkeeping
                    // route through the same machinery as
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
                onRescheduleTask: { task in
                    navigation = .list
                    paletteContext = MenuBarPaletteContext(seedTask: task)
                }
            )
            .transition(trailingDestinationTransition)
        } else {
            EmptyView()
                .onAppear { navigation = .list }
        }
    }

    @ViewBuilder
    func quickAddTasksRoute() -> some View {
        // Capture-first now lives in fullscreen backlog. Returning
        // from edit → drop user back on the main list; no auto-focus
        // needed (no inline input to focus). The user can ⇧⌘N or tap
        // «Backlog» on the SmartActions bar to add another task.
        EmptyView()
            .onAppear { navigation = .list }
    }

    /// Dispatch the current `navigation` value to the destination
    /// view. The body uses this in place of the inline switch.
    @ViewBuilder
    func navigationDestination() -> some View {
        switch navigation {
        case .list:
            listRoute()
        case .detail(let event):
            detailRoute(event)
        case .timer(let event):
            timerRoute(event)
        case .addEvent(let editing, let initialType, let prefillFrom):
            addEventRoute(editing: editing, initialType: initialType, prefillFrom: prefillFrom)
        case .newTask(let prefillTitle, let prefillDuration):
            newTaskRoute(prefillTitle: prefillTitle, prefillDuration: prefillDuration)
        case .editTask(let task):
            editTaskRoute(task)
        case .backlog:
            backlogRoute()
        case .quickAddTasks:
            quickAddTasksRoute()
        }
    }
}
