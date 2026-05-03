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

    // MARK: - Slot picker (replaces legacy CommandPalette seeding on tap)
    //
    // Tapping the «+» on a free slot opens an inline `SlotPickerPopover`
    // anchored on the row. From there the user can either pick an
    // existing backlog task or type a new one — both paths schedule
    // straight into this slot. The legacy `onFillTapped` closure is
    // kept as a fallback for hosts that don't wire the picker (preview
    // surfaces, future calm-state empty paths).

    /// Backlog candidates surfaced inside the picker. Caller is
    /// responsible for filtering down to the schedulable subset
    /// (typically `BacklogService.pending`). Empty list = picker still
    /// opens, just shows the input + a creation hint.
    var pickerTasks: [BacklogTask] = []
    /// Same-day events used by `TimelineSlotRanker` for context-match
    /// scoring inside the picker. Caller passes the day's full event
    /// list; the ranker filters internally to within ±2h of the slot.
    var pickerAdjacentEvents: [CalendarEvent] = []
    /// Place an existing backlog task into this slot. Same path as drop.
    var onPickTask: ((BacklogTask) -> Void)? = nil
    /// Create a new backlog task with the typed title and place it
    /// straight into this slot.
    var onCreateAndPlaceTask: ((_ title: String, _ durationMinutes: Int) -> Void)? = nil
    /// Open the fullscreen backlog from the picker's «Show all» footer.
    var onOpenFullscreenBacklog: (() -> Void)? = nil
    /// Caller-provided permission to display the one-time «drag tasks here»
    /// hint for this slot. The caller decides which slots are eligible
    /// (usually: the first free slot on the earliest day with backlog tasks)
    /// so the hint doesn't repeat on every gap. The row itself gates on
    /// `hasDragged` via `@AppStorage`, so once the user has dragged anything
    /// at least once the hint vanishes permanently even if the flag stays true.
    var canShowDragHint: Bool = false

    // MARK: - J3: contextual actions
    //
    // Right-click on a free slot offers 2-3 verbs for the slot:
    // start the top backlog task right here, run a Pomodoro, or
    // protect it as a focus block. The host passes pre-resolved
    // candidates so we don't reach back into BacklogService /
    // OptimizerService from a row component — Birman: row knows
    // the slot, host knows the schedule.

    /// Top backlog task that fits this slot (duration ≤ slot length).
    /// nil = no candidate; the «Start top task» entry is hidden.
    var topBacklogCandidate: BacklogTaskDrag? = nil

    /// Place the candidate task into this slot (same path as drop).
    var onStartTopTask: ((BacklogTaskDrag) -> Void)? = nil

    /// Start a Pomodoro inside this slot — host decides the rounds /
    /// duration shape from `PomodoroDefaults.suggested(for:)`.
    var onStartPomodoro: ((Date, Date) -> Void)? = nil

    /// Lock the slot as a Focus block (creates a local event with
    /// Focus title + blue color tag — same path as `fillSlotWithFocus`).
    var onLockAsFocus: ((Date, Date) -> Void)? = nil

    @State private var isHovered: Bool = false
    @State private var isDropTargeted: Bool = false
    /// Drives the inline `SlotPickerPopover` anchored on the «+» button.
    /// Toggled by `onFillTapped` when the host has wired picker callbacks.
    @State private var showingSlotPicker: Bool = false
    /// Mirrors `BuboBacklogHasDragged` used by `BacklogView`. Sharing the key
    /// means "user dragged a task" flips off both the old inline hint and
    /// the new in-slot example at the same moment.
    @AppStorage("BuboBacklogHasDragged") private var hasDragged: Bool = false

    private var isAwaitingDrop: Bool {
        coordinator?.isDraggingTask == true
    }

    /// True when the host has provided at least one picker callback —
    /// the «+» tap opens `SlotPickerPopover` instead of falling through
    /// to the legacy `onFillTapped` closure.
    private var hasPickerWiring: Bool {
        onPickTask != nil || onCreateAndPlaceTask != nil
    }

    /// Final gate for the drag-onboarding hint. Permission from the caller
    /// (`canShowDragHint`), not yet dragged, and neither hovered nor being
    /// targeted by an in-flight drop — so the hint cedes the space to
    /// stronger, more immediate signals the moment the user engages.
    private var showsDragHint: Bool {
        canShowDragHint
            && !hasDragged
            && !isHovered
            && !isAwaitingDrop
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
            // Level 4: an invisible spacer the exact same width as an event's
            // urgency accent bar so event rows and free-slot rows share one
            // anchor column. No stroke: Free slots are *colorless* empty
            // time, and any tint (even a muted tertiary one) reads as "this
            // slot has a color", which confuses the color filter semantics.
            Color.clear
                .frame(width: DS.Size.accentBarWidth, height: DS.Size.accentBarHeight)
            // Same trailing as EventRowView's urgencyBar — keeps the time
            // columns of both row types on the same vertical axis. No
            // leading offset: the row's outer `sm` padding already matches
            // the event row's outer padding, so both accent bars start at
            // exactly contentMargin + sm from the popover left edge.
            .padding(.trailing, DS.Spacing.md)
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 1) {
                // `DS.Typography.metric` — duration is a numeric fact;
                // adopting the same voice the backlog header verdict uses
                // means the «Free · 4 h» reads as «another piece of the
                // schedule's data», not a separate label kind.
                Text("Free · \(durationLabel)")
                    .font(DS.Typography.metric(skin: skin))
                    .foregroundStyle(skin.resolvedTextSecondary)
                Text(formattedRange)
                    .font(DS.Typography.metric(skin: skin))
                    .foregroundStyle(skin.resolvedTextTertiary)
            }

            Spacer(minLength: DS.Spacing.md)

            // Drag onboarding example — replaces the old inline banner in
            // BacklogView. Lives on the *target* of the gesture so the user
            // learns the affordance where it actually matters. Disappears
            // permanently after the first real drag (shared AppStorage key).
            // Hidden while the drag is in flight or while the cursor is
            // hovering, since both states already convey their own signal
            // and a second caption would clutter the row.
            if showsDragHint {
                Text("\u{2190} Drag a task here")
                    .font(.footnote)
                    .foregroundStyle(skin.resolvedTextTertiary)
                    .lineLimit(1)
                    .transition(.opacity)
                    .accessibilityHidden(true)
            }

            // Primary «Focus» CTA — surfaced only on slots ≥ 90 min,
            // since shorter slots aren't long enough to be worth a
            // dedicated focus block. Tap = the same path the right-
            // click «Lock as Focus block» uses, just one click instead
            // of two. Birman: «direct action at the site of the problem» —
            // if the user has a 2-hour window, turning it into a focus
            // block should be a visible gesture, not hidden away in a
            // context menu.
            if durationMinutes >= 90, let focusHandler = onLockAsFocus {
                Button {
                    Haptics.tap()
                    focusHandler(start, end)
                } label: {
                    HStack(spacing: DS.Spacing.xxs) {
                        Image(systemName: "brain.head.profile")
                            .font(.caption)
                        Text("Focus")
                            .font(.caption.weight(.medium))
                    }
                    .foregroundStyle(skin.accentColor)
                    .padding(.horizontal, DS.Spacing.sm)
                    .padding(.vertical, DS.Spacing.xxs)
                    .background(
                        Capsule().fill(skin.accentColor.opacity(isHovered ? DS.Opacity.lightFill : DS.Opacity.subtleFill))
                    )
                    .overlay(
                        Capsule().strokeBorder(
                            skin.accentColor.opacity(DS.Opacity.softAccent),
                            lineWidth: DS.Border.thin
                        )
                    )
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help("Lock this \(durationLabel) slot as a Focus block")
                .accessibilityLabel("Lock as Focus block")
                .padding(.trailing, DS.Spacing.xs)
            }

            Button {
                Haptics.tap()
                // Picker is the new canonical entry point — one verb
                // (Add to slot) instead of three legacy branches. When
                // the host hasn't wired it (preview surfaces, etc.),
                // fall back to the original `onFillTapped` closure so
                // those hosts keep working.
                if hasPickerWiring {
                    showingSlotPicker = true
                } else {
                    onFillTapped(durationMinutes)
                }
            } label: {
                Image(systemName: "plus.circle.fill")
                    .font(.body)
                    .foregroundStyle(skin.accentColor.opacity(isHovered ? 1.0 : DS.Opacity.overlayLight))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Add to this slot")
            .accessibilityLabel("Add a task to this \(durationLabel) free slot")
            .popover(isPresented: $showingSlotPicker, arrowEdge: .trailing) {
                SlotPickerPopover(
                    slotStart: start,
                    slotEnd: end,
                    tasks: pickerTasks,
                    adjacentEvents: pickerAdjacentEvents,
                    onPick: { task in
                        showingSlotPicker = false
                        onPickTask?(task)
                    },
                    onCreate: { title, duration in
                        showingSlotPicker = false
                        onCreateAndPlaceTask?(title, duration)
                    },
                    onOpenFullscreenBacklog: onOpenFullscreenBacklog.map { handler in
                        {
                            showingSlotPicker = false
                            handler()
                        }
                    },
                    onCancel: { showingSlotPicker = false }
                )
            }
        }
        .frame(minHeight: DS.Size.eventRowMinHeight)
        .padding(.vertical, DS.Spacing.xxs)
        .padding(.horizontal, DS.Spacing.sm)
        // Receive feedback for an in-flight drag — the slot lifts via a
        // soft drop-target shadow when a draggable hovers over it. Border
        // + fill already convey colour identity («I'm receiving»);
        // shadow adds the «I'm above the row» depth. Earlier this had a
        // 1.02 scaleEffect too, but `.scaleEffect` doesn't reflow layout
        // — the targeted slot would visually overlap its neighbours,
        // and four channels (border, fill, scale, shadow) for one state
        // pushed the receive feedback into over-stated territory.
        .shadow(
            color: skin.resolvedShadowColor,
            radius: isDropTargeted ? DS.Physics.dropTargetShadowRadius : 0,
            y: isDropTargeted ? DS.Physics.dropTargetShadowY : 0
        )
        .animation(skin.resolvedMicroAnimation, value: isDropTargeted)
        // Level 4 (final): flat row inside the timeline platter card —
        // same visual framework as EventRowView. The idle dashed pill
        // border is gone: the dashed vertical bar on the left + the
        // "Free · Xh" caption + the plus icon already signal the
        // affordance, and the hover fill (rectangle) provides the
        // "interactive" cue the same way native macOS List rows do.
        .background(
            Rectangle().fill(backgroundFill)
        )
        .onHover { hovering in
            withAnimation(skin.resolvedMicroAnimation) {
                isHovered = hovering
            }
        }
        .contentShape(Rectangle())
        .dropDestination(for: BacklogTaskDrag.self) { items, _ in
            guard let drag = items.first, onTaskDropped != nil else { return false }
            // Snap-tick on a successful drop — `.alignment` is the macOS
            // haptic pattern designed exactly for «cosied into a slot»
            // moments (Apple uses it for guides snapping in Keynote /
            // alignment in Final Cut). No-op without a Force Touch
            // trackpad.
            Haptics.alignment()
            onTaskDropped?(drag)
            return true
        } isTargeted: { targeted in
            withAnimation(skin.resolvedMicroAnimation) {
                isDropTargeted = targeted
            }
            // Predictive ghost during drag: when the cursor enters this
            // slot mid-drag, publish the would-be scheduled interval to
            // the shared coordinator so MenuBarView replaces this slot
            // with a translucent «<title> · HH:MM–HH:MM» block. Birman:
            // «show what will happen before it happens».
            //
            // `isTargeted` is the right signal here (not `.onHover`) —
            // macOS fires hover callbacks only while no drag is in
            // flight; drop-target callbacks are the drag-aware equivalent.
            if targeted, let drag = coordinator?.draggedTask {
                let needed = TimeInterval(drag.durationMinutes * 60)
                let available = end.timeIntervalSince(start)
                let fit = min(needed, available)
                coordinator?.setGhost(
                    slot: DateInterval(start: start, duration: fit),
                    title: drag.title
                )
            } else if !targeted, coordinator?.ghostSlot?.start == start {
                // Only clear if the ghost still points at THIS slot. A
                // fast drag across rows can fire exit-on-A *after*
                // enter-on-B; the start-equality check stops us from
                // blanking the next slot's fresh ghost.
                coordinator?.clearGhost()
            }
        }
        // Drop-target state — flat rectangle stroke, matches the card
        // paradigm. Only visible when a drag is happening, not at rest.
        .overlay(
            Rectangle()
                .strokeBorder(
                    activeDropBorderColor,
                    lineWidth: activeDropBorderWidth
                )
                .animation(skin.resolvedMicroAnimation, value: isDropTargeted)
                .animation(.easeInOut(duration: 0.25), value: isAwaitingDrop)
        )
        .accessibilityElement(children: .combine)
        // J3: right-click menu — quick verbs scoped to this slot.
        // Surfaces only the entries the host has actually wired
        // (and only when there's a real candidate for the «top
        // task» entry), so the menu reads as a curated list rather
        // than a wall of greyed-out items. §9 (direct manipulation)
        // is preserved: every action targets this slot specifically.
        .contextMenu {
            if let candidate = topBacklogCandidate, let handler = onStartTopTask {
                Button {
                    Haptics.tap()
                    handler(candidate)
                } label: {
                    let trimmed = candidate.title.count > 24
                        ? String(candidate.title.prefix(24)) + "\u{2026}"
                        : candidate.title
                    Label("Start \u{201C}\(trimmed)\u{201D} here", systemImage: "play.circle.fill")
                }
            }
            if let handler = onStartPomodoro, durationMinutes >= 25 {
                Button {
                    Haptics.tap()
                    handler(start, end)
                } label: {
                    Label("Start Pomodoro here", systemImage: "timer")
                }
            }
            if let handler = onLockAsFocus {
                Button {
                    Haptics.tap()
                    handler(start, end)
                } label: {
                    Label("Lock as Focus block", systemImage: "shield")
                }
            }
        }
    }

    /// Background fill: hover > drop-targeted > drag-awaiting > clear.
    private var backgroundFill: Color {
        if isDropTargeted { return skin.accentColor.opacity(DS.Opacity.mediumFill) }
        if isHovered { return skin.accentColor.opacity(DS.Opacity.lightFill) }
        if isAwaitingDrop { return skin.accentColor.opacity(DS.Opacity.subtleFill) }
        return .clear
    }

    /// Border layer chooses between hard (drop-targeted), soft (awaiting
    /// drop elsewhere on the screen), and invisible (idle).
    private var activeDropBorderColor: Color {
        if isDropTargeted { return skin.accentColor }
        if isAwaitingDrop { return skin.accentColor.opacity(DS.Opacity.softAccent) }
        return .clear
    }

    private var activeDropBorderWidth: CGFloat {
        if isDropTargeted { return DS.Border.selection }
        if isAwaitingDrop { return DS.Border.standard }
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
