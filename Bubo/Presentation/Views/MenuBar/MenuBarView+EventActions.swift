import SwiftUI

// MARK: - Event Actions
//
// Action handlers for the popover's event rows: edit (route through
// the series source-of-truth when the event is a recurring occurrence),
// delete (with toast/undo), and the post-mutation `notifyScheduleChange`
// fan-out into the optimizer's suggestion / trigger engines. Also the
// one-tap `runQuickAction` path used by the spill-over marker.

extension MenuBarView {

    /// Open the editor for `event`, falling back to the underlying
    /// recurring-series record when this row is one of its occurrences.
    /// Keeps the editor focused on the source of truth — editing a
    /// single occurrence in a series would otherwise look like a no-op
    /// because the visible row would re-render from the series.
    func resolveEdit(_ event: CalendarEvent) {
        if let seriesEvent = reminderService.seriesEvent(for: event) {
            navigation = .addEvent(editing: seriesEvent)
        } else {
            navigation = .addEvent(editing: event)
        }
    }

    /// Remove a local event with a toast/undo affordance — restores the
    /// event verbatim if the user taps undo before the toast clears.
    func handleDelete(_ event: CalendarEvent) {
        let deletedEvent = event
        reminderService.removeLocalEvent(id: event.id)
        toastState.showSuccess("\u{201C}\(deletedEvent.title)\u{201D} deleted", icon: "trash.fill") {
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
            toastState.showSuccess(label, icon: "sparkles") {
                optimizerService.undoLast(reminderService: reminderService)
            }
            notifyScheduleChange()
        } else if let error = result.errorMessage {
            toastState.showInfo(error, icon: "exclamationmark.triangle")
        }
    }
}
