import SwiftUI
import BuboDomain

// MARK: - Day Group
//
// Per-day section pieces of the timeline: the sticky `dayGroupHeader`,
// the row-list `dayGroupSection` (which forks on the day's items —
// events, free slots, ghost), the `freeSlotRow` builder
// with its drop / picker / pomodoro callbacks, and the
// `collapsedEventsHeader` used during a backlog drag. Extracted from
// MenuBarView.swift to keep the body file focused on composition.

extension MenuBarView {

    /// Sticky section header for one day in the timeline. Carries the
    /// scroll anchor (`.id(date)`) used by the popover header's day-nav
    /// cluster, and a skin-tinted bar material so the header stays
    /// readable while events scroll under it inside the LazyVStack's
    /// `pinnedViews: [.sectionHeaders]` mode.
    @ViewBuilder
    func dayGroupHeader(date: Date, events: [CalendarEvent]) -> some View {
        let visibleCount = screen.visibleEventCount(for: events)
        DaySectionHeader(
            date: date,
            count: visibleCount,
            meta: screen.dayHeaderMeta(for: events, on: date)
        )
            .id(date)
            // Negative horizontal padding bleeds the banner through the
            // EventList's `DS.Spacing.contentMargin` outer inset so the
            // strip touches both popover edges, matching the prototype's
            // `.day-header { margin: 0 -12px }`. DaySectionHeader carries
            // its own inner padding so text stays aligned with the body
            // grid.
            .padding(.horizontal, -DS.Spacing.contentMargin)
    }

    @ViewBuilder
    func dayGroupSection(_ day: MenuBarTimelineDay) -> some View {
        // Filter interaction is resolved upstream in `timelineDays()`:
        // • colorFilter active → events already pruned to one tag, so
        //   `items` carries no free-slot rows.
        // • freeSlotFilter == .onlyFree → only real free slots remain.
        // • freeSlotFilter == .hideFree → events stay, free slots are
        //   suppressed so a busy day reads as a compact list.

        // Working-hours start boundary — today only (REDESIGN.md R5 /
        // PRINCIPLES §3): the boundary is one global rule, and repeating
        // its two rows in every future day section multiplied the same
        // fact down the whole timeline. Today keeps the interactive
        // handles (drag / step); other days show nothing — the rule
        // hasn't changed by scrolling to Thursday. Suppressed while a
        // backlog drag is in flight (the collapse stands in for the
        // day's contents) and on days with no rows. (Working hours stay
        // adjustable in Settings → Optimizer.)
        let dayIsToday = Calendar.current.isDateInToday(day.date)
        let dayHasRows = !day.items.isEmpty
        // Now-anchored (REDESIGN.md R5): a boundary row renders only
        // while its boundary is still AHEAD. At 10:52 «Working hours
        // start 09:00» is history occupying the first row under
        // «Today»; the end handle likewise leaves once the working day
        // is over (the «After hours» moon speaks for that state). The
        // rule stays adjustable in Settings → Optimizer at any hour.
        let hourNow = Calendar.current.component(.hour, from: screen.nowTick)
        if dayIsToday, dayHasRows, !backlogCoordinator.isDraggingTask,
           hourNow < optimizerService.workingHoursStart {
            WorkingHoursBoundaryRow(
                kind: .start,
                hour: optimizerService.workingHoursStart,
                onStep: { delta in
                    let proposed = optimizerService.workingHoursStart + delta
                    optimizerService.workingHoursStart = max(0, min(22, proposed))
                }
            )
        }

        if backlogCoordinator.isDraggingTask && !day.events.isEmpty && screen.freeSlotFilter != .onlyFree {
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
            }
        }

        if dayIsToday, dayHasRows, !backlogCoordinator.isDraggingTask,
           hourNow < optimizerService.workingHoursEnd {
            WorkingHoursBoundaryRow(
                kind: .end,
                hour: optimizerService.workingHoursEnd,
                onStep: { delta in
                    let proposed = optimizerService.workingHoursEnd + delta
                    optimizerService.workingHoursEnd = max(1, min(23, proposed))
                }
            )
        }

        // After-hours / wind-down marker for today: when the latest
        // event ends past `workingHours.upperBound`, surface a quiet
        // «After hours» caption below the boundary handle.
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

    /// Per-free-slot row inside the day-group switch. Resolves the
    /// ghost-suppression gate (skip the "Free · Xh" row whose start
    /// coincides with the active ghost block) and otherwise builds
    /// `FreeSlotRow` with its drop / slot-picker / pomodoro / focus
    /// callbacks wired against the host's services.
    @ViewBuilder
    func freeSlotRow(
        start: Date,
        end: Date,
        slotId: String,
        day: MenuBarTimelineDay
    ) -> some View {
        if let ghost = screen.ghostForDay(day.date), ghost.start == start {
            EmptyView()
        } else {
            FreeSlotRow(
                start: start,
                end: end,
                onFillTapped: { _ in },
                onTaskDropped: { drag in
                    handleTaskDrop(drag: drag, slotStart: start, slotEnd: end)
                },
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
                        screen.navigation = .backlog
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
    func collapsedEventsHeader(for events: [CalendarEvent]) -> some View {
        let bookedMinutes = events.reduce(0) { acc, event in
            acc + max(0, Int(event.endDate.timeIntervalSince(event.startDate) / 60))
        }
        HStack(spacing: DS.Spacing.sm) {
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
}
