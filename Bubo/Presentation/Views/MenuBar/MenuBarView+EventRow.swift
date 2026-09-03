import SwiftUI
import AppKit
import BuboDomain

// MARK: - Event Row
//
// Per-event row inside the day-group switch, plus the single
// `EventRowActions` value that serves every row (verbs travel through
// the environment — PRINCIPLES §9). Kept on the host so the closures
// see the full set of services without parameter plumbing.

extension MenuBarView {

    /// One `EventRowActions` for all rows — every closure takes the
    /// event, so the same value works regardless of which row fires it.
    /// Installed once in `MenuBarView.body` via
    /// `.environment(\.eventRowActions, …)`.
    var eventRowActions: EventRowActions {
        EventRowActions(
            tap: { event in
                screen.navigation = .detail(event)
            },
            edit: { event in resolveEdit(event) },
            delete: { event in handleDelete(event) },
            deleteOccurrence: { event in
                reminderService.excludeOccurrence(occurrenceId: event.id)
                screen.toastState.showSuccess("\u{201C}\(event.title)\u{201D} removed", icon: "trash.fill")
            },
            deleteSeries: { event in
                let seriesId = event.seriesId ?? event.id
                reminderService.removeLocalEvent(id: seriesId)
                screen.toastState.showSuccess("All \u{201C}\(event.title)\u{201D} deleted", icon: "trash.fill")
            },
            renameLocal: { event, newTitle in
                // Inline rename: route to `updateLocalEvent` against the
                // root event. For an expanded occurrence we look the root
                // up by series id, since `localEvents` only stores root
                // events and `updateLocalEvent` matches by id.
                let rootId = event.seriesId ?? event.id
                guard var root = reminderService.localEvents.first(where: { $0.id == rootId }) else { return }
                root.title = newTitle
                reminderService.updateLocalEvent(root)
                screen.toastState.showSuccess("Renamed to \u{201C}\(newTitle)\u{201D}", icon: "pencil")
            },
            reschedule: { event, deltaMinutes in
                reminderService.snoozeReminder(for: event, minutes: deltaMinutes)
                let signed = deltaMinutes > 0 ? "+\(deltaMinutes)\u{00A0}min" : "\(deltaMinutes)\u{00A0}min"
                let eventId = event.id
                screen.toastState.showSuccess("Rescheduled (\(signed))", icon: "arrow.up.and.down.circle.fill") {
                    if let current = reminderService.localEvents.first(where: { $0.id == eventId }) {
                        reminderService.snoozeReminder(for: current, minutes: -deltaMinutes)
                    }
                }
            },
            completeTask: { event in
                var completed = event
                completed.taskStatus = .done
                completed.completedAt = Date()
                reminderService.updateLocalEvent(completed)
                screen.toastState.showSuccess("Task completed", icon: "checkmark.circle.fill")
            },
            findBetterTime: { event in
                withAnimation(DS.Animation.quick) {
                    screen.paletteContext = MenuBarPaletteContext(seedEvent: event)
                }
            },
            splitTask: { _ in
                withAnimation(DS.Animation.quick) {
                    screen.paletteContext = MenuBarPaletteContext(seedRecipeId: "split-task")
                }
            },
            protectBlock: { event in
                let request = OptimizationRequest(
                    .keepFixed(eventIds: [event.id]),
                    .horizon(.today), .speed(.quick), .scenarios(count: 1),
                    name: "Protect Block"
                )
                Task {
                    _ = await optimizerService.executeRequest(request, reminderService: reminderService)
                    screen.toastState.showSuccess("Focus block protected", icon: "shield.fill")
                }
            },
            addPrep: { event in
                withAnimation(DS.Animation.quick) {
                    screen.paletteContext = MenuBarPaletteContext(seedEvent: event, seedRecipeId: "prep-meeting")
                }
            },
            addPrepQuick: { event, minutes in
                // One-tap meetingPrep: scope to this event, fixed minutes,
                // run through the same toast + undo pipe as other
                // quick-actions.
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
            convertToPomodoro: { event in
                convertEventToPomodoro(event)
            },
            repeatLikeThis: { event in
                // Pre-fill `AddEventView` with the shape of the current
                // event; the clone strips id, recurrence, calendar
                // binding, and series metadata — see `cloneAsDraft(_:)`.
                let draft = cloneAsDraft(event)
                screen.navigation = .addEvent(
                    editing: nil,
                    initialType: draft.eventType,
                    prefillFrom: draft
                )
            },
            toggleLock: { event in
                // Persistent toggle in `OptimizerService`. Next optimizer
                // run reads `lockedEventIds` and injects an implicit
                // `.keepFixed(...)` so the GA leaves this event alone.
                withAnimation(DS.Animation.quick) {
                    optimizerService.toggleLock(eventId: event.id)
                }
            },
            toggleExclude: { event in
                // Excluded events are absent from the optimizer's input —
                // useful when planning around a maybe-cancelled meeting.
                withAnimation(DS.Animation.quick) {
                    optimizerService.toggleExclude(eventId: event.id)
                }
            }
        )
    }

    /// Per-event row inside the day-group switch. Gates on
    /// `backlogCoordinator.isDraggingTask` (the day's contents collapse
    /// behind the `collapsedEventsHeader`) and otherwise hands the event
    /// to `EventRowView` with facts only — verbs come from
    /// `\.eventRowActions`.
    @ViewBuilder
    func eventRow(_ event: CalendarEvent) -> some View {
        if backlogCoordinator.isDraggingTask {
            EmptyView()
        } else {
            EventRowView(
                event: event,
                reminderService: reminderService,
                isLocked: optimizerService.isLocked(eventId: event.id),
                isExcluded: optimizerService.isExcluded(eventId: event.id),
                energyAtStartHour: optimizerService.energyCheckInService?
                    .predictEnergy(atHour: Calendar.current.component(.hour, from: event.startDate)),
                isFreshlyCreated: optimizerService.freshlyCreatedEventIds.contains(event.id),
                showsCalendarName: screen.timelineSpansMultipleCalendars,
                isHappeningNow: screen.nowTick >= event.startDate && screen.nowTick < event.endDate
            )
        }
    }
}

// MARK: - Event Actions
//
// Handlers behind the row verbs above: edit (route through the series
// source-of-truth for a recurring occurrence), delete (with toast/undo),
// the post-mutation `notifyScheduleChange` fan-out into the optimizer's
// suggestion / trigger engines, and the one-tap `runQuickAction` path.

extension MenuBarView {

    /// Open the editor for `event`, falling back to the underlying
    /// recurring-series record when this row is one of its occurrences.
    /// Keeps the editor focused on the source of truth — editing a
    /// single occurrence in a series would otherwise look like a no-op
    /// because the visible row would re-render from the series.
    func resolveEdit(_ event: CalendarEvent) {
        if let seriesEvent = reminderService.seriesEvent(for: event) {
            screen.navigation = .addEvent(editing: seriesEvent)
        } else {
            screen.navigation = .addEvent(editing: event)
        }
    }

    /// Remove a local event with a toast/undo affordance — restores the
    /// event verbatim if the user taps undo before the toast clears.
    func handleDelete(_ event: CalendarEvent) {
        let deletedEvent = event
        reminderService.removeLocalEvent(id: event.id)
        screen.toastState.showSuccess("\u{201C}\(deletedEvent.title)\u{201D} deleted", icon: "trash.fill") {
            reminderService.addLocalEvent(deletedEvent)
        }
        notifyScheduleChange()
    }

    /// Fan-out hook called after any schedule mutation that the rest of
    /// the optimizer pipeline cares about (suggestions + reactive
    /// triggers). `deleted` / `created` let the trigger engine specialize
    /// — most callers only need the suggestion refresh, so both default
    /// to nil/false.
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

    /// Execute a request immediately — no palette, no configuration.
    /// One tap → done → undo toast. Birman: "sequential magic."
    ///
    /// Async so callers (e.g. the spill-over marker action-link) can await
    /// and surface a loading spinner during the optimizer call. Fire-and-
    /// forget callers wrap in `Task { ... }`.
    @MainActor
    func runQuickAction(_ request: OptimizationRequest, label: String) async {
        let result = await optimizerService.executeRequest(request, reminderService: reminderService)
        if case .success = result, !optimizerService.scenarios.isEmpty {
            optimizerService.applyScenario(at: 0, to: reminderService)
            screen.toastState.showSuccess(label, icon: "sparkles") {
                optimizerService.undoLast(reminderService: reminderService)
            }
            notifyScheduleChange()
        } else if let error = result.errorMessage {
            screen.toastState.showInfo(error, icon: "exclamationmark.triangle")
        }
    }
}
