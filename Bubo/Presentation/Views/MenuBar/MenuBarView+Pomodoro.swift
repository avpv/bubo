import SwiftUI

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

extension MenuBarView {

    func convertEventToPomodoro(_ event: CalendarEvent) {
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
    func cloneAsDraft(_ source: CalendarEvent) -> CalendarEvent {
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
    func rippleShiftLaterEvents(after anchor: CalendarEvent, minutes: Int) -> [String] {
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
    func topBacklogCandidate(forSlotMinutes slotMinutes: Int) -> BacklogTaskDrag? {
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
    func startPomodoroInSlot(start: Date, end: Date) {
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
}
