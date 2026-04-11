import SwiftUI

// MARK: - Free Slot Row
//
// A first-class row inserted between events to represent empty time.
// Clicking the + icon opens the CommandPalette pre-seeded with the slot duration,
// which filters the recipe list to creative recipes that fit the slot.
//
// This is the "direct manipulation on empty time" layer of the optimizer UI —
// users see that a gap exists and can fill it without typing.

struct FreeSlotRow: View {
    @Environment(\.activeSkin) private var skin
    /// Shared drag-state coordinator — when a backlog task is in flight,
    /// every valid slot lights up a subtle accent border so the user can
    /// see all the places this task could land. Degrades gracefully to the
    /// per-row `isDropTargeted` feedback when the coordinator is missing.
    @Environment(\.backlogCoordinator) private var coordinator

    let start: Date
    let end: Date
    let onFillTapped: (_ minutes: Int) -> Void
    /// Called when a backlog task is dropped onto this slot.
    var onTaskDropped: ((_ drag: BacklogTaskDrag) -> Void)? = nil

    @State private var isHovered: Bool = false
    @State private var isDropTargeted: Bool = false

    private var isAwaitingDrop: Bool {
        coordinator?.isDraggingTask == true
    }

    private var durationMinutes: Int {
        max(0, Int(end.timeIntervalSince(start) / 60))
    }

    private var formattedRange: String {
        let fmt = DateFormatter()
        fmt.setLocalizedDateFormatFromTemplate("H:mm")
        return "\(fmt.string(from: start))–\(fmt.string(from: end))"
    }

    private var durationLabel: String {
        if durationMinutes < 60 {
            return "\(durationMinutes)\u{00A0}min"
        }
        let h = durationMinutes / 60
        let m = durationMinutes % 60
        return m == 0 ? "\(h)\u{00A0}h" : "\(h)\u{00A0}h \(m)\u{00A0}min"
    }

    var body: some View {
        HStack(alignment: .center, spacing: 0) {
            // Level 4: a dashed vertical bar the exact same height as an
            // event's urgency accent bar (4×28) so event rows and free-slot
            // rows share one anchor column. Dashes — not a solid fill — keep
            // the semantic distinction: "empty time, not booked".
            Path { path in
                path.move(to: CGPoint(x: DS.Size.accentBarWidth / 2, y: 0))
                path.addLine(to: CGPoint(x: DS.Size.accentBarWidth / 2, y: DS.Size.accentBarHeight))
            }
            .stroke(
                skin.resolvedTextTertiary.opacity(0.45),
                style: StrokeStyle(
                    lineWidth: DS.Size.accentBarWidth,
                    lineCap: .round,
                    dash: [3, 3]
                )
            )
            .frame(width: DS.Size.accentBarWidth, height: DS.Size.accentBarHeight)
            // Same trailing as EventRowView's urgencyBar — keeps the time
            // columns of both row types on the same vertical axis. No
            // leading offset: the row's outer `sm` padding already matches
            // the event row's outer padding, so both accent bars start at
            // exactly contentMargin + sm from the popover left edge.
            .padding(.trailing, DS.Spacing.md)
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 1) {
                Text("Free · \(durationLabel)")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(skin.resolvedTextSecondary)
                Text(formattedRange)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(skin.resolvedTextTertiary)
            }

            Spacer(minLength: DS.Spacing.md)

            Button {
                Haptics.tap()
                onFillTapped(durationMinutes)
            } label: {
                Image(systemName: "plus.circle.fill")
                    .font(.body)
                    .foregroundStyle(skin.accentColor.opacity(isHovered ? 1.0 : 0.55))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Fill this slot")
            .accessibilityLabel("Fill this \(durationLabel) free slot")
        }
        .frame(minHeight: DS.Size.eventRowMinHeight)
        .padding(.vertical, DS.Spacing.xxs)
        .padding(.horizontal, DS.Spacing.sm)
        .background(
            RoundedRectangle(cornerRadius: DS.Size.cornerRadius, style: .continuous)
                .fill(backgroundFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DS.Size.cornerRadius, style: .continuous)
                .strokeBorder(
                    skin.resolvedTextTertiary.opacity(isHovered ? 0.25 : 0.12),
                    style: StrokeStyle(lineWidth: 0.5, dash: [3, 3])
                )
        )
        .onHover { hovering in
            withAnimation(skin.resolvedMicroAnimation) {
                isHovered = hovering
            }
        }
        .contentShape(Rectangle())
        .dropDestination(for: BacklogTaskDrag.self) { items, _ in
            guard let drag = items.first, onTaskDropped != nil else { return false }
            onTaskDropped?(drag)
            return true
        } isTargeted: { targeted in
            withAnimation(skin.resolvedMicroAnimation) {
                isDropTargeted = targeted
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: DS.Size.cornerRadius, style: .continuous)
                .strokeBorder(
                    activeDropBorderColor,
                    lineWidth: activeDropBorderWidth
                )
                .animation(skin.resolvedMicroAnimation, value: isDropTargeted)
                .animation(.easeInOut(duration: 0.25), value: isAwaitingDrop)
        )
        .accessibilityElement(children: .combine)
    }

    /// Background fill: hover > drop-targeted > drag-awaiting > clear.
    private var backgroundFill: Color {
        if isDropTargeted { return skin.accentColor.opacity(0.14) }
        if isHovered { return skin.accentColor.opacity(0.06) }
        if isAwaitingDrop { return skin.accentColor.opacity(0.04) }
        return .clear
    }

    /// Border layer chooses between hard (drop-targeted), soft (awaiting
    /// drop elsewhere on the screen), and invisible (idle).
    private var activeDropBorderColor: Color {
        if isDropTargeted { return skin.accentColor }
        if isAwaitingDrop { return skin.accentColor.opacity(0.35) }
        return .clear
    }

    private var activeDropBorderWidth: CGFloat {
        if isDropTargeted { return 2 }
        if isAwaitingDrop { return 1 }
        return 0
    }
}

// MARK: - Free Slot Computation
//
// Pure helper used by the event list and the backlog to compute free gaps
// between events. Kept here so it can be unit-tested separately from
// MenuBarView and shared by the ghost-preview lookup in BacklogView.

enum FreeSlotFinder {
    /// Default minimum slot length (in minutes) below which we hide the row
    /// to avoid cluttering the list with tiny gaps. Callers can override.
    static let defaultMinSlotMinutes: Int = 30

    /// Returns the free gaps for today between `events` within working hours.
    /// The caller passes already-sorted events for the day.
    /// `minSlotMinutes` controls the shortest gap shown (defaults to 30).
    static func slots(
        for events: [CalendarEvent],
        on date: Date,
        workingHours: ClosedRange<Int>,
        minSlotMinutes: Int = defaultMinSlotMinutes,
        calendar: Calendar = .current,
        now: Date = Date()
    ) -> [(start: Date, end: Date)] {
        guard let dayStart = calendar.date(bySettingHour: workingHours.lowerBound, minute: 0, second: 0, of: date),
              let dayEnd = calendar.date(bySettingHour: workingHours.upperBound, minute: 0, second: 0, of: date)
        else {
            return []
        }

        let effectiveStart = max(dayStart, calendar.isDate(date, inSameDayAs: now) ? now : dayStart)
        guard effectiveStart < dayEnd else { return [] }

        // Only count in-window events as occupying time.
        let relevant = events
            .filter { $0.endDate > effectiveStart && $0.startDate < dayEnd }
            .sorted { $0.startDate < $1.startDate }

        var gaps: [(start: Date, end: Date)] = []
        var cursor = effectiveStart

        for event in relevant {
            let eStart = max(event.startDate, effectiveStart)
            if eStart > cursor {
                let minutes = Int(eStart.timeIntervalSince(cursor) / 60)
                if minutes >= minSlotMinutes {
                    gaps.append((cursor, eStart))
                }
            }
            cursor = max(cursor, min(event.endDate, dayEnd))
        }

        if cursor < dayEnd {
            let minutes = Int(dayEnd.timeIntervalSince(cursor) / 60)
            if minutes >= minSlotMinutes {
                gaps.append((cursor, dayEnd))
            }
        }

        return gaps
    }

    /// Find the first free slot of at least `durationMinutes`, starting from
    /// `now` and scanning forward up to `maxDaysAhead` days.
    ///
    /// Used by the backlog ghost preview to answer "where would this new
    /// task land?" without invoking the optimizer. The logic mirrors
    /// `slots(for:on:)` exactly, so the row the user sees in the list and
    /// the ghost preview always agree.
    static func nextSlot(
        matching durationMinutes: Int,
        in events: [CalendarEvent],
        workingHours: ClosedRange<Int>,
        maxDaysAhead: Int = 7,
        calendar: Calendar = .current,
        now: Date = Date()
    ) -> DateInterval? {
        guard durationMinutes > 0 else { return nil }
        let needed = TimeInterval(durationMinutes * 60)

        for dayOffset in 0...max(0, maxDaysAhead) {
            guard let dayAnchor = calendar.date(byAdding: .day, value: dayOffset, to: now) else { continue }
            let daySlots = slots(
                for: events,
                on: dayAnchor,
                workingHours: workingHours,
                minSlotMinutes: durationMinutes,
                calendar: calendar,
                now: now
            )
            // slots() already snaps to `now` on the current day, so the
            // first wide-enough gap is our answer. Duration is capped to
            // the slot's own length so a 30-min task lands cleanly inside a
            // 90-min gap (start-aligned).
            if let gap = daySlots.first {
                let fit = min(needed, gap.end.timeIntervalSince(gap.start))
                return DateInterval(start: gap.start, duration: fit)
            }
        }

        return nil
    }
}
