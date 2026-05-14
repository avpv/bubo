import SwiftUI
import BuboDomain

struct EventRowView: View {
    let event: CalendarEvent
    let reminderService: ReminderService
    var onEdit: ((CalendarEvent) -> Void)? = nil
    var onDelete: ((CalendarEvent) -> Void)? = nil
    var onDeleteOccurrence: ((CalendarEvent) -> Void)? = nil
    var onDeleteSeries: ((CalendarEvent) -> Void)? = nil
    var onTap: ((CalendarEvent) -> Void)? = nil
    /// Inline rename for local (Bubo-owned) events. Apple Calendar events
    /// are read-only as far as title-rewrites go, so callers should leave
    /// this nil for them. The callback fires on Enter or blur with a
    /// trimmed, non-empty title that differs from the current one.
    var onRenameLocal: ((CalendarEvent, String) -> Void)? = nil
    /// Drag-to-reschedule. Receives a signed minute delta (negative = earlier,
    /// positive = later). Caller decides whether to apply it (see snooze
    /// path in `ReminderService`). Restricted by the row to upcoming
    /// non-recurring local events; pass nil to disable for any reason.
    var onReschedule: ((CalendarEvent, Int) -> Void)? = nil

    // Task actions
    var onCompleteTask: ((CalendarEvent) -> Void)? = nil

    // Optimizer context menu actions
    var onFindBetterTime: ((CalendarEvent) -> Void)? = nil
    var onSplitTask: ((CalendarEvent) -> Void)? = nil
    var onProtectBlock: ((CalendarEvent) -> Void)? = nil
    var onAddPrep: ((CalendarEvent) -> Void)? = nil
    /// Quick-pick prep buffer minutes — 5/10/15/30 from a sub-menu.
    /// Companion to `onAddPrep` (which routes through the palette);
    /// when set, the context menu shows a sub-menu of fixed
    /// durations for one-tap insertion. Reifies `meetingPrep(minutes:)`
    /// at the per-event level without making the user type into
    /// the palette. nil = sub-menu hidden, falls back to `onAddPrep`.
    var onAddPrepQuick: ((CalendarEvent, Int) -> Void)? = nil

    /// Current flex percent for this event (0 = rigid, 25 / 50 are
    /// the canonical sub-menu options). Drives the sub-menu's
    /// disabled state on the active option and the optional
    /// «flex-on» indicator next to the lock icon.
    var flexPercent: Int = 0
    /// Set the per-event flex percent. Wired via
    /// `OptimizerService.setFlex(percent:eventId:)`. nil = sub-menu
    /// hidden.
    var onSetFlex: ((CalendarEvent, Int) -> Void)? = nil

    /// Convert a standard event into a Pomodoro session (work + break
    /// intervals). Routed through the edit form so the user can tune
    /// work/break/rounds before committing — Birman: explicit control on a
    /// non-trivial transformation, not a silent mutation.
    var onConvertToPomodoro: ((CalendarEvent) -> Void)? = nil

    /// Cross-cutting #4: clone this event as a one-off draft into a
    /// future free slot. Copies title, duration, location, color tag,
    /// reminders, and Pomodoro shape (when present) — not the original
    /// time, calendar binding, or recurrence. Hidden when nil; surfaced
    /// only for local events (we don't silently duplicate someone
    /// else's calendar entry).
    var onRepeatLikeThis: ((CalendarEvent) -> Void)? = nil

    /// True when this event is in the user's locked set — the optimizer
    /// will skip it on every run via the implicit `.keepFixed(eventIds:)`
    /// intent the host service injects. Drives the on-row lock affordance:
    /// solid lock when locked, hollow on hover when not. Reifies the
    /// `keepFixed` / `stability` intents as a per-event surface, so
    /// «protect this from the optimizer» is one tap, not a search through
    /// the command palette. Birman: «rules are objects on the screen».
    var isLocked: Bool = false
    /// Toggle this event's locked state. Wired from `MenuBarView` to
    /// `OptimizerService.toggleLock(eventId:)`. nil = the affordance is
    /// hidden (preview surfaces, read-only events).
    var onToggleLock: ((CalendarEvent) -> Void)? = nil

    /// True when this event is in the user's excluded set — the
    /// optimizer skips it on every run via the implicit
    /// `.exclude(eventIds:)` intent the host service injects. Different
    /// from `isLocked`: locked events stay visible to the GA but are
    /// pinned in place, excluded events are pretended-not-to-exist.
    /// Useful for «I might cancel this, plan around its absence».
    var isExcluded: Bool = false
    /// Toggle this event's excluded state. Surfaced as a context-menu
    /// item rather than a row icon — exclude is the rarer choice and
    /// having a second leading icon next to lock would crowd the row.
    /// nil = item hidden.
    var onToggleExclude: ((CalendarEvent) -> Void)? = nil

    /// Optional 0…1 energy prediction for this event's start hour,
    /// sourced from `EnergyCheckInService.predictEnergy(atHour:)`.
    /// When ≥ 0.7 the row surfaces a tiny ⚡ glyph next to the title
    /// to flag «peak hour, good for focus». When ≤ 0.3 the glyph
    /// turns into a leaf (low-energy hint). Otherwise hidden — calm
    /// hours need no decoration. Reifies the `peakEnergy` /
    /// `lowEnergy` / `matchEnergyCurve` intents without requiring
    /// a separate energy column.
    var energyAtStartHour: Double? = nil

    /// When true, the row plays a brief highlight glow to draw attention
    /// to newly created/changed events after recipe application.
    var isFreshlyCreated: Bool = false

    /// True when `Date()` falls inside `[event.startDate, event.endDate)`.
    /// Drives the «now» highlight — a brighter, thicker accent bar on
    /// the left edge — so the user can tell at a glance which event
    /// is currently happening without doing the time-arithmetic
    /// themselves. The host (MenuBarView) ticks once per minute and
    /// passes the resolved bool here so each row stays a pure View.
    var isHappeningNow: Bool = false

    @State var isHovered = false
    @State var isDisintegrating = false
    /// Birman: "if data disappears, the viewer should know why". A calm fade
    /// when an event naturally ends is legible; a particle explosion is not.
    @State var isFadingOut = false
    @State var pendingDeleteAction: (() -> Void)?
    @FocusState var isFocused: Bool

    /// Inline-rename state. `isEditingTitle` flips on a double-click on
    /// the title text and toggles the rendering of `eventDetails` between
    /// a `Text` and a `TextField`. While editing, the parent `Button`
    /// wrapper is bypassed so TextField clicks reach AppKit's text engine
    /// instead of being captured by the row tap-handler.
    @State var isEditingTitle = false
    @State var titleDraft = ""
    @FocusState var titleFieldFocused: Bool

    /// Drag-to-reschedule state. The gesture is a long-press → drag
    /// sequence (Apple Calendar's pattern), so a quick tap or a scroll
    /// drag never accidentally rescheduling — the press has to be held
    /// for ~0.35s before the drag arms. Once armed, vertical drag
    /// translates to a signed minute delta, snapped to a 5-minute grid.
    /// Each new snap bucket fires `Haptics.alignment()` so the user
    /// feels the magnetic catch even with eyes off the screen.
    @State var dragArmed = false
    @State var dragOffsetY: CGFloat = 0
    @State var dragMinuteDelta: Int = 0
    @State var lastSnappedDelta: Int = 0
    @Environment(\.colorSchemeContrast) var contrast
    @Environment(\.activeSkin) var skin

    var isLocal: Bool {
        event.isLocalEvent
    }

    var body: some View {
        // HIG: Use TimelineView for time-based UI updates
        TimelineView(.periodic(from: .now, by: 1)) { context in
            styledRow(now: context.date)
        }
    }

    // Level 4 (final): the timeline is now wrapped in a single platter
    // card (see MenuBarView.mainContent). Rows therefore shed their
    // individual platter backgrounds, drop shadows, AND their rounded
    // clipShape — the card's own rounded corners are the only curves
    // on the screen. Inside the card, rows are flat rectangles flush
    // to the card edges, exactly like form sections in AddEventView.
    // The progress fill renders directly on the card material; contrast
    // is unchanged because the fill's opacity already assumes a material
    // substrate underneath.
    @ViewBuilder
    private func progressBackground(now: Date) -> some View {
        // Quiet progress underline — a 1pt accent rule on the bottom edge
        // that fills as the event runs. Replaces the earlier full-row
        // accent fill, which made every "now" event read as visually
        // loaded against the lighter neighbours. Birman: density is
        // respect for attention; the fill was stealing attention from
        // the title. The underline still conveys "this is in progress"
        // without dimming the row's contents.
        GeometryReader { geo in
            let progress = eventProgress(now)
            if progress > 0 {
                let fillWidth = max(geo.size.width * progress, 8)
                let baseColor: Color = skin.isClassic ? DS.Colors.accent : skin.accentColor
                let fillOpacity: Double = contrast == .increased ? DS.Opacity.softAccent : DS.Opacity.mediumFill

                VStack {
                    Spacer(minLength: 0)
                    Rectangle()
                        .fill(baseColor.opacity(fillOpacity))
                        .frame(width: fillWidth, height: 1)
                }
            }
        }
        .allowsHitTesting(false)
    }

    // Flat rectangle hover signal — no rounded pill to leak card material
    // through gaps at the row corners. `allowsHitTesting(false)` is
    // load-bearing: a filled Rectangle overlay (even Color.clear)
    // intercepts taps and would swallow clicks meant for the inner row
    // Button beneath it.
    private var hoverOverlay: some View {
        Rectangle()
            .fill(isHovered ? skin.resolvedHoverFill : Color.clear)
            .allowsHitTesting(false)
    }

    // Freshly created highlight — brief flat glow after recipe application.
    private var freshlyCreatedOverlay: some View {
        Rectangle()
            .fill(skin.accentColor.opacity(isFreshlyCreated ? 0.20 : 0))
            .animation(DS.Animation.pulseQuick().repeatCount(3, autoreverses: true), value: isFreshlyCreated)
            .allowsHitTesting(false)
    }

    // Flat rectangular focus ring — matches the flat row paradigm.
    private var focusOverlay: some View {
        Rectangle()
            .strokeBorder(isFocused ? skin.accentColor.opacity(DS.Opacity.overlayDark) : Color.clear,
                          lineWidth: DS.Size.focusRingWidth)
            .shadow(color: isFocused ? skin.accentColor.opacity(DS.Opacity.tertiaryText) : .clear, radius: 4, x: 0, y: 0)
            .allowsHitTesting(false)
    }

    private var rowAccessibilityLabel: String {
        var label = event.title
        if event.isRecurring { label += ", recurring" }
        label += ", \(event.formattedTimeRange)"
        if let location = event.location { label += ", \(location)" }
        return label
    }

    private var rowAccessibilityHint: String {
        canDrag
            ? "Press Enter to view details. Long-press and drag vertically to reschedule. Right-click to set reminder."
            : "Press Enter to view details. Right-click to set reminder."
    }

    private func handleTimelineTick(_ now: Date) {
        // Detect event end and trigger a calm fade-out.
        guard !event.isUpcoming,
              !isDisintegrating,
              !isFadingOut,
              !reminderService.disintegratingEventIDs.contains(event.id) else { return }
        reminderService.beginDisintegration(for: event.id)
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(300))
            isFadingOut = true
            try? await Task.sleep(for: .milliseconds(500))
            reminderService.completeDisintegration(for: event.id)
        }
    }

    private func handleDisintegrationComplete() {
        if let action = pendingDeleteAction {
            action()
            pendingDeleteAction = nil
        } else {
            withAnimation(DS.Animation.smoothSpring) {
                reminderService.completeDisintegration(for: event.id)
            }
        }
    }

    @ViewBuilder
    private func decoratedRow(now: Date) -> some View {
        rowStack(now: now)
            .frame(minHeight: DS.Size.eventRowMinHeight)
            // Birman: density is respect for attention. Prototype CSS pads
            // event rows by 6/0/6/12 — vertical breathing room is xs (4pt),
            // not sm (8pt). The earlier 8pt vertical wasted ~25% of every
            // popover for whitespace already supplied by the row's own
            // line-height.
            .padding(.vertical, DS.Spacing.xs)
            .padding(.horizontal, DS.Spacing.sm)
            .background(progressBackground(now: now))
            .overlay(hoverOverlay)
            // Quiet card hairline so the eye reads each event as its
            // own object on the popover material instead of a
            // continuous flat band. `fg-1` at 8 % is loud enough to
            // see, quiet enough to disappear inside the surface tint —
            // matches the rhythm used by `BacklogTaskRow` so the
            // timeline and backlog feel like the same product.
            .overlay(
                RoundedRectangle(cornerRadius: DS.Size.subtleCornerRadius, style: .continuous)
                    .strokeBorder(
                        skin.resolvedTextPrimary.opacity(DS.Mix.surfaceDivider),
                        lineWidth: DS.Border.thin
                    )
                    .allowsHitTesting(false)
            )
            .overlay(freshlyCreatedOverlay)
            .onHover { hovering in
                withAnimation(skin.resolvedMicroAnimation) {
                    isHovered = hovering
                }
            }
            // HIG: Support keyboard navigation — focusable rows, Enter to open
            .focusable()
            .focused($isFocused)
            .focusEffectDisabled()
            .overlay(focusOverlay)
            .animation(skin.resolvedMicroAnimation, value: isFocused)
            .onKeyPress(.return) {
                Haptics.tap()
                onTap?(event)
                return .handled
            }
    }

    @ViewBuilder
    private func interactiveRow(now: Date) -> some View {
        decoratedRow(now: now)
            // Drag-to-reschedule visual: lift the row off the timeline
            // while a drag is in flight. `zIndex(1)` keeps it on top of
            // neighbours so the offset doesn't read as «buried under
            // the row above».
            .offset(y: dragArmed ? dragOffsetY : 0)
            .scaleEffect(dragArmed ? 1.02 : 1.0, anchor: .leading)
            .shadow(color: dragArmed ? skin.accentColor.opacity(DS.Opacity.softAccent) : .clear,
                    radius: dragArmed ? 12 : 0, y: dragArmed ? 4 : 0)
            .zIndex(dragArmed ? 1 : 0)
            .animation(skin.resolvedMicroAnimation, value: dragArmed)
            // Scroll-aware transition: fade/scale as items enter/exit viewport
            .eventScrollTransition()
            // Drag-to-reschedule gesture (long-press 0.35s → vertical drag).
            // The mask is `.all` when the row is rescheduable so the Button's
            // tap recognition keeps running in parallel with the long-press
            // detector — both gestures fire on the same input stream. For
            // non-rescheduable rows we mask in `.subviews`, which disables
            // *this* simultaneous gesture while leaving the inner Button's
            // tap fully active. The earlier `including: .gesture` reading
            // looked right but actually means «enable the added gesture and
            // disable all other gestures on the view» — i.e. it switched the
            // Button off, leaving the row feeling dead on a quick click.
            .simultaneousGesture(rescheduleGesture, including: canDrag ? .all : .subviews)
            // Surface the proposed new time as an overlay capsule near the
            // leading edge of the row. The badge fades in as soon as the
            // drag arms, even at zero delta — that's how the user knows the
            // gesture is live and the next vertical move will register.
            .overlay(alignment: .topLeading) { rescheduleBadge }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(rowAccessibilityLabel)
            .accessibilityHint(rowAccessibilityHint)
            .accessibilityAddTraits(.isButton)
    }

    @ViewBuilder
    private func styledRow(now: Date) -> some View {
        interactiveRow(now: now)
            // Calm fade-out when the event naturally ends (no particle explosion).
            .opacity(isFadingOut ? 0 : 1)
            .scaleEffect(isFadingOut ? 0.96 : 1.0, anchor: .leading)
            .animation(DS.Animation.smoothSpring, value: isFadingOut)
            .onChange(of: now) { handleTimelineTick(now) }
            // Disintegration is kept only for user-triggered deletes — it signals
            // an intentional, irreversible dismissal (softened by undo in the toast).
            .disintegrate(when: isDisintegrating) { handleDisintegrationComplete() }
            .contextMenu { contextMenuItems }
    }

    @ViewBuilder
    private var contextMenuItems: some View {
        Group {
            Section("Set Reminder") {
                reminderMenuItems
            }

            if isLocal {
                Divider()

                // Optimizer-visibility toggle. Lock has a row affordance
                // already (the inline icon next to the title); exclude is
                // the rarer companion («planning around a maybe-cancelled
                // event») so it lives only in the menu. Both flow through
                // `OptimizerService.lockedEventIds` / `excludedEventIds`
                // and inject the corresponding intents on every Run.
                if let onToggleExclude {
                    Button {
                        Haptics.impact()
                        onToggleExclude(event)
                    } label: {
                        Label(
                            isExcluded
                                ? "Include in optimization"
                                : "Exclude from optimization",
                            systemImage: isExcluded ? "eye" : "eye.slash"
                        )
                    }
                    .help(isExcluded
                          ? "Currently hidden from the optimizer — re-include to plan around it"
                          : "Optimizer plans around this event as if it doesn't exist")
                }

                if let setFlex = onSetFlex {
                    // Per-event flex sub-menu. `Rigid` = optimizer keeps
                    // the duration as-is (the default). `Flex ±25%` /
                    // `Flex ±50%` mean «GA may shrink or grow this
                    // event by N% of its current duration» — scoped
                    // via OptimizerService.flexIntent + onlyOptimize.
                    // Reifies the per-event variant of the global
                    // `flexDuration` intent without forcing the user
                    // through the palette.
                    Menu {
                        Button("Rigid") { setFlex(event, 0) }
                            .disabled(flexPercent == 0)
                        Button("Flex \u{00b1}25%") { setFlex(event, 25) }
                            .disabled(flexPercent == 25)
                        Button("Flex \u{00b1}50%") { setFlex(event, 50) }
                            .disabled(flexPercent == 50)
                    } label: {
                        Label(
                            flexPercent > 0 ? "Flex (\u{00b1}\(flexPercent)%)" : "Flex duration",
                            systemImage: "arrow.left.and.right"
                        )
                    }
                    .help("Allow the optimizer to resize this event's duration when applying scope-this-event runs")
                }

                // Task actions
                if event.isTask, event.taskStatus != .done, let onCompleteTask {
                    Button {
                        Haptics.impact()
                        onCompleteTask(event)
                    } label: {
                        Label("Complete Task", systemImage: "checkmark.circle.fill")
                    }
                }

                // Optimizer actions
                if let onFindBetterTime {
                    Button {
                        onFindBetterTime(event)
                    } label: {
                        Label("Find Better Time", systemImage: "wand.and.stars")
                    }
                }

                if event.duration > 2 * 3600, let onSplitTask {
                    Button {
                        onSplitTask(event)
                    } label: {
                        Label("Split into Sessions", systemImage: "scissors")
                    }
                }

                if (event.eventType == .pomodoro || event.title.localizedCaseInsensitiveContains("focus")),
                   let onProtectBlock {
                    Button {
                        onProtectBlock(event)
                    } label: {
                        Label("Protect This Block", systemImage: "shield")
                    }
                }

                // Convert a standard local event into Pomodoro. Hidden when:
                // - the event is already a Pomodoro session,
                // - it's a task (different conversion path),
                // - it's backed by an external calendar (we don't mutate
                //   other calendars' events),
                // - or it's shorter than one full Pomodoro work segment
                //   (`PomodoroDefaults.minimumConvertibleMinutes`).
                if event.eventType == .standard, !event.isTask,
                   event.endDate.timeIntervalSince(event.startDate) >= TimeInterval(PomodoroDefaults.minimumConvertibleMinutes * 60),
                   let onConvertToPomodoro {
                    Button {
                        onConvertToPomodoro(event)
                    } label: {
                        Label("Convert to Pomodoro", systemImage: "timer")
                    }
                }

                // Cross-cutting #4: «Repeat from this event…» — clone the
                // current event's shape into a future free slot. Useful
                // when the user wants a similar block again without
                // re-typing duration, reminders, location, and Pomodoro
                // config. Routed via the optimizer through the host's
                // callback, which can pre-fill `AddEventView` instead.
                if let onRepeatLikeThis {
                    Button {
                        onRepeatLikeThis(event)
                    } label: {
                        Label("Repeat from this event\u{2026}", systemImage: "arrow.counterclockwise.circle")
                    }
                }

                if event.meetingLink != nil || event.calendarName != nil {
                    if let quickHandler = onAddPrepQuick {
                        // Quick-pick sub-menu — reifies meetingPrep at
                        // the per-event level with one-tap durations.
                        // Skips the palette round-trip the slower
                        // `onAddPrep` path takes.
                        Menu {
                            Button("5 min") { quickHandler(event, 5) }
                            Button("10 min") { quickHandler(event, 10) }
                            Button("15 min") { quickHandler(event, 15) }
                            Button("30 min") { quickHandler(event, 30) }
                            if let onAddPrep {
                                Divider()
                                Button("Custom\u{2026}") { onAddPrep(event) }
                            }
                        } label: {
                            Label("Add Prep Time", systemImage: "note.text")
                        }
                    } else if let onAddPrep {
                        Button {
                            onAddPrep(event)
                        } label: {
                            Label("Add Prep Time", systemImage: "note.text")
                        }
                    }
                }

                Divider()
                Button { onEdit?(event) } label: {
                    Label("Edit", systemImage: "pencil")
                }
                if event.isRecurring {
                    Menu {
                        Button(role: .destructive) { triggerDeleteWithDisintegration { onDeleteOccurrence?(event) } } label: {
                            Label("Delete This Event Only", systemImage: "trash")
                        }
                        Button(role: .destructive) { triggerDeleteWithDisintegration { onDeleteSeries?(event) } } label: {
                            Label("Delete All Events", systemImage: "trash.fill")
                        }
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                } else {
                    Button(role: .destructive) { triggerDeleteWithDisintegration { onDelete?(event) } } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
            }
        }
        .labelStyle(.titleAndIcon)
    }

    @ViewBuilder
    private func rowStack(now: Date) -> some View {
        HStack(alignment: .center, spacing: 0) {
            // Tappable body — wrapped in a Button so SwiftUI cleanly
            // routes inner button taps (delete, reminder, join) to their
            // own actions. A parent `.onTapGesture` collides with the
            // hover-revealed minus button (taps fall through to "open
            // details"); using BacklogTaskRow's plain-Button pattern
            // avoids the gesture-priority issue entirely.
            //
            // While the title is being inline-edited, the parent Button
            // is intentionally bypassed: a TextField nested inside a
            // SwiftUI `Button` doesn't receive cursor-placement clicks,
            // so we render the row content directly and let AppKit's
            // text engine own the clicks for the duration of the edit.
            if isEditingTitle {
                rowContent(now: now)
            } else {
                Button {
                    Haptics.tap()
                    onTap?(event)
                } label: {
                    rowContent(now: now)
                }
                .buttonStyle(.plain)
            }

            // Join meeting — always visible when meeting link exists
            if let meetingURL = event.meetingLink {
                joinButton(meetingURL)
            }

            // Other actions on hover — slide in from right
            if isHovered && !isEditingTitle {
                hoverActions
            }
        }
    }

    // MARK: - Join Button (always visible)

    private func joinButton(_ url: URL) -> some View {
        Button {
            Haptics.tap()
            NSWorkspace.shared.open(url)
        } label: {
            Label("Join", systemImage: "video.fill")
                .font(.footnote)
                .fontWeight(.medium)
        }
        .buttonStyle(.action(role: .primary, size: .compact))
        .help("Join \(event.meetingServiceName ?? "meeting")")
        .accessibilityLabel("Join \(event.meetingServiceName ?? "meeting")")
    }

    // MARK: - Urgency Bar

    @ViewBuilder
    private func urgencyBar(_ now: Date) -> some View {
        // «Now» state overrides the colour-tag bar with a brighter,
        // thicker accent — the «happening right now» signal needs to
        // beat the calendar-colour identity so the user spots the
        // current row at a glance. Falls back to the calendar tag
        // for past / upcoming rows.
        let baseColor: Color = isHappeningNow
            ? skin.accentColor
            : (event.colorTag?.color ?? skin.resolvedTextTertiary)
        let opacity: Double = isHappeningNow
            ? 1.0
            : (event.colorTag == nil ? 0.5 : (event.isUpcoming ? 0.8 : 0.55))
        let width: CGFloat = isHappeningNow
            ? DS.Size.accentBarWidth * 1.5
            : DS.Size.accentBarWidth
        Capsule()
            .fill(baseColor.opacity(opacity))
            .frame(width: width, height: DS.Size.accentBarHeight)
            .padding(.trailing, DS.Spacing.md)
            .accessibilityLabel(isHappeningNow ? "Happening now" : "")
    }

    // MARK: - Time Column

    private func timeColumn(_ now: Date) -> some View {
        VStack(spacing: DS.Spacing.xxs) {
            HStack(spacing: 0) {
                Text(event.formattedTime)
                    .font(.system(.footnote, design: skin.resolvedFontDesign, weight: .bold))
                    .foregroundStyle(skin.resolvedTextPrimary)
                Text("–")
                    .font(.system(.footnote, design: skin.resolvedFontDesign, weight: .bold))
                    .foregroundStyle(skin.resolvedTextSecondary)
                Text(event.formattedEndTime)
                    .font(.system(.footnote, design: skin.resolvedFontDesign, weight: .regular))
                    .foregroundStyle(skin.resolvedTextSecondary)
            }

            Text(timeUntilText(now))
                .font(.system(.footnote, design: skin.resolvedFontDesign, weight: .semibold))
                .foregroundStyle(skin.isClassic ? skin.resolvedTextSecondary : skin.accentColor) // Highlight countdown
                .contentTransition(.numericText())
        }
        .frame(width: DS.Size.timeColumnWidth)
        .padding(.trailing, DS.Spacing.xs)
    }

    // MARK: - Row Content (shared between tappable + inline-edit modes)

    @ViewBuilder
    private func rowContent(now: Date) -> some View {
        HStack(alignment: .center, spacing: 0) {
            urgencyBar(now)
            timeColumn(now)
            eventDetails
            Spacer(minLength: DS.Spacing.md)
        }
        .contentShape(Rectangle())
    }

    // MARK: - Event Details

    private var eventDetails: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.xxs) {
            HStack(spacing: DS.Spacing.xs) {
                titleField

                if let segment = event.pomodoroSegment {
                    Image(systemName: segment.iconName)
                        .font(.system(size: DS.Size.iconSmall, weight: .medium))
                        .foregroundStyle(pomodoroSegmentColor(segment))
                        .contentTransition(.symbolEffect(.replace))
                        .accessibilityLabel(segment.label)
                }

                // Energy hint glyph — shown only at the extremes (peak
                // ⚡ / low 🍃) so calm-energy hours stay decoration-free.
                // The threshold uses the same 0.7 / 0.3 split the
                // EnergyCheckInService uses internally for «high» /
                // «low» buckets, so the visual matches the service's
                // own intent.
                if let energy = energyAtStartHour, energy >= 0.7 || energy <= 0.3 {
                    // Energy hint glyphs read from the new
                    // `resolvedPeakEnergyColor` / `resolvedLowEnergyColor`
                    // skin tokens (commit 5c51ef2) so the colours flow
                    // from the same source the upcoming timeline-band
                    // overlay will use. Default mappings preserve the
                    // earlier accent / tertiary split exactly.
                    Image(systemName: energy >= 0.7 ? "bolt.fill" : "leaf")
                        .font(.system(size: DS.Size.iconSmall - 2, weight: .medium))
                        .foregroundStyle(energy >= 0.7
                                         ? skin.resolvedPeakEnergyColor
                                         : skin.resolvedLowEnergyColor)
                        .help(energy >= 0.7
                              ? "Peak energy hour — good for focus work"
                              : "Low energy hour — best for routine tasks")
                        .accessibilityLabel(energy >= 0.7 ? "Peak energy" : "Low energy")
                }

                // Lock affordance — solid lock when this event is in
                // the user's locked set (the optimizer skips it on
                // every run via the implicit `.keepFixed` intent the
                // host injects); hollow lock revealed on hover otherwise
                // so the affordance is discoverable without ever shouting.
                // Tap toggles the persistent set in `OptimizerService`.
                if onToggleLock != nil, isLocked || isHovered {
                    Button {
                        Haptics.tap()
                        onToggleLock?(event)
                    } label: {
                        Image(systemName: isLocked ? "lock.fill" : "lock.open")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(isLocked
                                             ? skin.accentColor
                                             : skin.resolvedTextTertiary)
                            .contentTransition(.symbolEffect(.replace))
                    }
                    .buttonStyle(.plain)
                    .help(isLocked
                          ? "Locked — optimizer will not move this event"
                          : "Lock to prevent the optimizer from moving this event")
                    .accessibilityLabel(isLocked ? "Locked" : "Unlocked")
                    .transition(.opacity)
                }

                // E3 fix — exclude is now visible on hover (or
                // persistently when active), not buried in context
                // menu. `eye.slash.fill` matches the «pretend this
                // doesn't exist» semantic without colliding with
                // lock's «pinned in place». Tap toggles the
                // persistent exclude set in `OptimizerService`.
                if onToggleExclude != nil, isExcluded || isHovered {
                    Button {
                        Haptics.impact()
                        onToggleExclude?(event)
                    } label: {
                        Image(systemName: isExcluded ? "eye.slash.fill" : "eye.slash")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(isExcluded
                                             ? skin.resolvedWarningColor
                                             : skin.resolvedTextTertiary)
                            .contentTransition(.symbolEffect(.replace))
                    }
                    .buttonStyle(.plain)
                    .help(isExcluded
                          ? "Excluded — optimizer plans around this as if it doesn't exist"
                          : "Hide from the optimizer (plan around this event)")
                    .accessibilityLabel(isExcluded ? "Excluded from optimization" : "Include in optimization")
                    .transition(.opacity)
                }

                // E3 fix — flex indicator surfaces the «how much can
                // the optimizer shrink/grow this» rule on the row.
                // Visible persistently when flex > 0 (so the user
                // sees the rule on their event without right-click);
                // visible on hover when flex == 0 so the affordance
                // stays discoverable.  Three-step Menu trigger:
                // Rigid / ±25% / ±50%.
                if let setFlex = onSetFlex, flexPercent > 0 || isHovered {
                    Menu {
                        Button("Rigid (don't flex)") {
                            Haptics.tap()
                            setFlex(event, 0)
                        }
                        .disabled(flexPercent == 0)
                        Button("Flex \u{00B1}25%") {
                            Haptics.tap()
                            setFlex(event, 25)
                        }
                        .disabled(flexPercent == 25)
                        Button("Flex \u{00B1}50%") {
                            Haptics.tap()
                            setFlex(event, 50)
                        }
                        .disabled(flexPercent == 50)
                    } label: {
                        Text(flexPercent > 0 ? "\u{00B1}\(flexPercent)%" : "\u{00B1}%")
                            .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                            .foregroundStyle(flexPercent > 0
                                             ? skin.accentColor
                                             : skin.resolvedTextTertiary)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(
                                RoundedRectangle(cornerRadius: DS.Size.microCornerRadius, style: .continuous)
                                    .strokeBorder(
                                        flexPercent > 0
                                            ? skin.accentColor.opacity(DS.Mix.accentStrong)
                                            : skin.resolvedTextTertiary.opacity(DS.Mix.surfaceDivider),
                                        lineWidth: DS.Border.thin
                                    )
                            )
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help(flexPercent > 0
                          ? "Flex \u{00B1}\(flexPercent)% — optimizer may resize this block"
                          : "Allow the optimizer to flex this duration")
                    .accessibilityLabel(flexPercent > 0
                                        ? "Flex plus or minus \(flexPercent) percent"
                                        : "Set flex")
                    .transition(.opacity)
                }
            }

            HStack(spacing: DS.Spacing.md) {
                // Meeting service name is omitted here — the Join button already
                // conveys it via tooltip/accessibility label, so showing it
                // alongside would duplicate the same information.
                if let location = event.location, !location.isEmpty {
                    Label(location, systemImage: "mappin")
                        .font(.footnote)
                        .foregroundStyle(skin.resolvedTextSecondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }

                if let calName = event.calendarName {
                    Text(calName)
                        .font(.footnote)
                        .foregroundStyle(skin.resolvedTextTertiary)
                }
            }
        }
    }

}
