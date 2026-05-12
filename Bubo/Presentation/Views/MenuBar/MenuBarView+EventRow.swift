import SwiftUI
import AppKit

// MARK: - Event Row
//
// Per-event row inside the day-group switch. Lives in its own
// file so MenuBarView.swift can read as a body skeleton; the row
// itself is the densest single concern (15+ callbacks, optimizer
// lock/exclude bridging, ripple-shift, undo-toast wiring).

extension MenuBarView {

    /// Per-event row inside the day-group switch. Gates on
    /// `backlogCoordinator.isDraggingTask` (the day's contents collapse
    /// behind the `collapsedEventsHeader` so events stop competing with
    /// the free-slot drop targets) and otherwise hands the event to
    /// `EventRowView` wired with every per-row callback the menu-bar
    /// surface needs. Kept on the host so the closures see the full set
    /// of services and @State fields without parameter plumbing.
    @ViewBuilder
    func eventRow(_ event: CalendarEvent) -> some View {
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
}
