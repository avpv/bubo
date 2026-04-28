import SwiftUI

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
    /// Convert a standard event into a Pomodoro session (work + break
    /// intervals). Routed through the edit form so the user can tune
    /// work/break/rounds before committing — Birman: explicit control on a
    /// non-trivial transformation, not a silent mutation.
    var onConvertToPomodoro: ((CalendarEvent) -> Void)? = nil

    /// When true, the row plays a brief highlight glow to draw attention
    /// to newly created/changed events after recipe application.
    var isFreshlyCreated: Bool = false

    @State private var isHovered = false
    @State private var isDisintegrating = false
    /// Birman: "if data disappears, the viewer should know why". A calm fade
    /// when an event naturally ends is legible; a particle explosion is not.
    @State private var isFadingOut = false
    @State private var pendingDeleteAction: (() -> Void)?
    @FocusState private var isFocused: Bool

    /// Inline-rename state. `isEditingTitle` flips on a double-click on
    /// the title text and toggles the rendering of `eventDetails` between
    /// a `Text` and a `TextField`. While editing, the parent `Button`
    /// wrapper is bypassed so TextField clicks reach AppKit's text engine
    /// instead of being captured by the row tap-handler.
    @State private var isEditingTitle = false
    @State private var titleDraft = ""
    @FocusState private var titleFieldFocused: Bool

    /// Drag-to-reschedule state. The gesture is a long-press → drag
    /// sequence (Apple Calendar's pattern), so a quick tap or a scroll
    /// drag never accidentally rescheduling — the press has to be held
    /// for ~0.35s before the drag arms. Once armed, vertical drag
    /// translates to a signed minute delta, snapped to a 5-minute grid.
    /// Each new snap bucket fires `Haptics.alignment()` so the user
    /// feels the magnetic catch even with eyes off the screen.
    @State private var dragArmed = false
    @State private var dragOffsetY: CGFloat = 0
    @State private var dragMinuteDelta: Int = 0
    @State private var lastSnappedDelta: Int = 0
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.activeSkin) private var skin

    private var isLocal: Bool {
        event.isLocalEvent
    }

    var body: some View {
        // HIG: Use TimelineView for time-based UI updates
        TimelineView(.periodic(from: .now, by: 1)) { context in
        let now = context.date
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
        .frame(minHeight: DS.Size.eventRowMinHeight)
        .padding(.vertical, DS.Spacing.sm)
        .padding(.horizontal, DS.Spacing.sm)
        // Level 4 (final): the timeline is now wrapped in a single platter
        // card (see MenuBarView.mainContent). Rows therefore shed their
        // individual platter backgrounds, drop shadows, AND their rounded
        // clipShape — the card's own rounded corners are the only curves
        // on the screen. Inside the card, rows are flat rectangles flush
        // to the card edges, exactly like form sections in AddEventView.
        // The progress fill renders directly on the card material; contrast
        // is unchanged because the fill's opacity already assumes a material
        // substrate underneath.
        .background(
            ZStack(alignment: .leading) {
                if eventProgress(now) > 0 {
                    GeometryReader { geo in
                        let fillWidth = max(geo.size.width * eventProgress(now), DS.Size.cornerRadius * 2)
                        let baseColor = skin.isClassic ? DS.Colors.accent : skin.accentColor
                        let fillOpacity = contrast == .increased ? DS.Opacity.strongFill : DS.Opacity.mediumFill

                        Rectangle()
                            .fill(baseColor.opacity(fillOpacity))
                            .frame(width: fillWidth)
                    }
                }
            }
        )
        // Flat rectangle hover signal — no rounded pill to leak card
        // material through gaps at the row corners.
        // `allowsHitTesting(false)` is load-bearing: a filled Rectangle
        // overlay (even Color.clear) intercepts taps and would swallow
        // clicks meant for the inner row Button beneath it.
        .overlay(
            Rectangle()
                .fill(isHovered ? skin.resolvedHoverFill : Color.clear)
                .allowsHitTesting(false)
        )
        // Freshly created highlight — brief flat glow after recipe application
        .overlay(
            Rectangle()
                .fill(skin.accentColor.opacity(isFreshlyCreated ? 0.20 : 0))
                .animation(.easeInOut(duration: 0.6).repeatCount(3, autoreverses: true), value: isFreshlyCreated)
                .allowsHitTesting(false)
        )
        .onHover { hovering in
            withAnimation(skin.resolvedMicroAnimation) {
                isHovered = hovering
            }
        }
        // HIG: Support keyboard navigation — focusable rows, Enter to open
        .focusable()
        .focused($isFocused)
        .focusEffectDisabled()
        // Flat rectangular focus ring — matches the flat row paradigm.
        .overlay(
            Rectangle()
                .strokeBorder(isFocused ? skin.accentColor.opacity(DS.Opacity.overlayDark) : Color.clear, lineWidth: DS.Size.focusRingWidth)
                .shadow(color: isFocused ? skin.accentColor.opacity(0.4) : .clear, radius: 4, x: 0, y: 0)
                .allowsHitTesting(false)
        )
        .animation(skin.resolvedMicroAnimation, value: isFocused)
        .onKeyPress(.return) {
            Haptics.tap()
            onTap?(event)
            return .handled
        }
        // Drag-to-reschedule visual: lift the row off the timeline while
        // a drag is in flight. `zIndex(1)` keeps it on top of neighbours
        // so the offset doesn't read as «buried under the row above».
        .offset(y: dragArmed ? dragOffsetY : 0)
        .scaleEffect(dragArmed ? 1.02 : 1.0, anchor: .leading)
        .shadow(color: dragArmed ? skin.accentColor.opacity(0.3) : .clear,
                radius: dragArmed ? 12 : 0, y: dragArmed ? 4 : 0)
        .zIndex(dragArmed ? 1 : 0)
        .animation(skin.resolvedMicroAnimation, value: dragArmed)
        // Scroll-aware transition: fade/scale as items enter/exit viewport
        .eventScrollTransition()
        // Drag-to-reschedule gesture (long-press 0.35s → vertical drag).
        // `including: .none` masks the gesture out for non-rescheduable
        // shapes (recurring, external, or in-progress events) so the
        // parent ScrollView keeps full scroll priority for them.
        //
        // Use `.simultaneousGesture` (not `.gesture`) so the inner row
        // Button's tap recognition keeps running alongside the long-press
        // detector. Plain `.gesture` claims priority and, on macOS, the
        // LongPressGesture absorbs the click during its 0.35s window —
        // by the time it fails on release the Button has already missed
        // the mouse-up, leaving `onTap` unfired and the row feeling dead.
        .simultaneousGesture(rescheduleGesture, including: canDrag ? .gesture : .none)
        // Surface the proposed new time as an overlay capsule near the
        // leading edge of the row. The badge fades in as soon as the
        // drag arms, even at zero delta — that's how the user knows the
        // gesture is live and the next vertical move will register.
        .overlay(alignment: .topLeading) { rescheduleBadge }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(event.title)\(event.isRecurring ? ", recurring" : ""), \(event.formattedTimeRange)\(event.location.map { ", \($0)" } ?? "")")
        .accessibilityHint(canDrag
            ? "Press Enter to view details. Long-press and drag vertically to reschedule. Right-click to set reminder."
            : "Press Enter to view details. Right-click to set reminder.")
        .accessibilityAddTraits(.isButton)
        // Calm fade-out when the event naturally ends (no particle explosion).
        .opacity(isFadingOut ? 0 : 1)
        .scaleEffect(isFadingOut ? 0.96 : 1.0, anchor: .leading)
        .animation(DS.Animation.smoothSpring, value: isFadingOut)
        .onChange(of: now) {
            // Detect event end and trigger a calm fade-out.
            if !event.isUpcoming
                && !isDisintegrating
                && !isFadingOut
                && !reminderService.disintegratingEventIDs.contains(event.id) {
                reminderService.beginDisintegration(for: event.id)
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(300))
                    isFadingOut = true
                    try? await Task.sleep(for: .milliseconds(500))
                    reminderService.completeDisintegration(for: event.id)
                }
            }
        }
        // Disintegration is kept only for user-triggered deletes — it signals
        // an intentional, irreversible dismissal (softened by undo in the toast).
        .disintegrate(when: isDisintegrating) {
            if let action = pendingDeleteAction {
                action()
                pendingDeleteAction = nil
            } else {
                withAnimation(DS.Animation.smoothSpring) {
                    reminderService.completeDisintegration(for: event.id)
                }
            }
        }
        .contextMenu {
            Section("Set Reminder") {
                reminderMenuItems
            }

            if isLocal {
                Divider()

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

                if event.meetingLink != nil || event.calendarName != nil, let onAddPrep {
                    Button {
                        onAddPrep(event)
                    } label: {
                        Label("Add Prep Time", systemImage: "note.text")
                    }
                }

                Divider()
                Button("Edit") { onEdit?(event) }
                if event.isRecurring {
                    Menu("Delete") {
                        Button("Delete This Event Only", role: .destructive) { triggerDeleteWithDisintegration { onDeleteOccurrence?(event) } }
                        Button("Delete All Events", role: .destructive) { triggerDeleteWithDisintegration { onDeleteSeries?(event) } }
                    }
                } else {
                    Button("Delete", role: .destructive) { triggerDeleteWithDisintegration { onDelete?(event) } }
                }
            }
        }
        } // TimelineView
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
        if let tag = event.colorTag {
            Capsule()
                .fill(tag.color)
                .frame(width: DS.Size.accentBarWidth, height: DS.Size.accentBarHeight)
                .padding(.trailing, DS.Spacing.md)
                .shadow(
                    color: tag.color.opacity(event.isUpcoming ? 0.6 : skin.shadowOpacity * 4),
                    radius: event.isUpcoming ? 4 : skin.shadowRadius * 0.5
                )
        } else {
            // No user-assigned color: show an unfilled outline so the bar
            // remains a visible shape without injecting a color accent.
            Capsule()
                .strokeBorder(skin.resolvedTextTertiary.opacity(0.5), lineWidth: 1)
                .frame(width: DS.Size.accentBarWidth, height: DS.Size.accentBarHeight)
                .padding(.trailing, DS.Spacing.md)
        }
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

    // MARK: - Title (display + inline-edit)

    /// Title cell. Renders a `TextField` while `isEditingTitle` is true,
    /// otherwise a `Text` carrying a `simultaneousGesture` for double-tap
    /// rename — single taps still propagate to the parent row Button.
    /// Inline edit is gated to local (Bubo-owned) events; Apple Calendar
    /// titles are read-only.
    @ViewBuilder
    private var titleField: some View {
        if isEditingTitle {
            TextField("", text: $titleDraft)
                .textFieldStyle(.plain)
                .font(.subheadline.weight(.medium))
                .focused($titleFieldFocused)
                .onSubmit { commitTitleEdit() }
                .onExitCommand { cancelTitleEdit() }
                .onChange(of: titleFieldFocused) { _, isFocused in
                    // Blur (clicking elsewhere or tabbing out) commits,
                    // matching Finder rename behaviour. Pressing Esc
                    // takes the cancel path before this fires because
                    // `cancelTitleEdit()` clears `isEditingTitle` first.
                    if !isFocused && isEditingTitle {
                        commitTitleEdit()
                    }
                }
                .padding(.vertical, 1)
                .padding(.horizontal, DS.Spacing.xs)
                .background(
                    RoundedRectangle(cornerRadius: DS.Size.subtleCornerRadius)
                        .fill(skin.resolvedHoverFill)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: DS.Size.subtleCornerRadius)
                        .strokeBorder(skin.accentColor.opacity(DS.Opacity.softAccent),
                                       lineWidth: DS.Border.standard)
                )
                .accessibilityLabel("Edit event title")
        } else {
            Text(event.title)
                .font(.subheadline)
                .fontWeight(.medium)
                .lineLimit(2)
                .truncationMode(.tail)
                .simultaneousGesture(
                    TapGesture(count: 2)
                        .onEnded {
                            beginTitleEditIfAllowed()
                        }
                )
        }
    }

    private var canRenameInline: Bool {
        event.isLocalEvent && onRenameLocal != nil
    }

    private func beginTitleEditIfAllowed() {
        guard canRenameInline else { return }
        Haptics.tap()
        titleDraft = event.title
        isEditingTitle = true
        // Defer focusing one runloop tick so the TextField is in the
        // hierarchy by the time we ask SwiftUI to focus it.
        DispatchQueue.main.async { titleFieldFocused = true }
    }

    private func commitTitleEdit() {
        let trimmed = titleDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        // Empty title or unchanged title → cancel quietly. An empty
        // rename is treated as «I changed my mind», not «delete me».
        if trimmed.isEmpty || trimmed == event.title {
            cancelTitleEdit()
            return
        }
        onRenameLocal?(event, trimmed)
        Haptics.impact()
        isEditingTitle = false
        titleFieldFocused = false
    }

    private func cancelTitleEdit() {
        isEditingTitle = false
        titleFieldFocused = false
        titleDraft = ""
    }

    // MARK: - Drag-to-Reschedule

    /// Pixel-to-minute conversion: 80pt of vertical drag ≈ 60min of
    /// time shift. Apple Calendar's continuous timeline is roughly
    /// 75pt/h, so 80pt/h sits just inside that physical reference and
    /// reads as a familiar gesture for users who switch between apps.
    private var pointsPerMinute: CGFloat { 80.0 / 60.0 }

    /// Snap step. The user requested «5/15-min» — we snap to 5 by
    /// default; holding `Option` could later promote to 15-min coarse
    /// snaps but the v1 keeps the gesture single-modal.
    private var snapMinutes: Int { 5 }

    /// Hard cap on a single drag's reach so an enthusiastic flick can't
    /// hurl an event into next week without confirmation. ±240 minutes
    /// (4 hours) covers any reasonable «push this back to after lunch».
    private var maxDeltaMinutes: Int { 240 }

    /// Drag-to-reschedule is allowed only on local, single-occurrence,
    /// upcoming events. Recurring events need explicit «this occurrence
    /// vs series» disambiguation, which the inline drag can't provide
    /// without a confirmation dialog (and a dialog defeats directness).
    /// Apple Calendar events are skipped because their occurrence-vs-
    /// series semantics under `shiftEventTime` differ from the local
    /// path's «root shift moves all occurrences» behaviour.
    private var canDrag: Bool {
        onReschedule != nil
            && event.isLocalEvent
            && !event.isRecurring
            && event.isUpcoming
            && !isEditingTitle
    }

    private var rescheduleGesture: some Gesture {
        // Long-press first, then drag — same as Apple Calendar's reorder
        // gesture. The 0.35s hold filters out accidental presses while a
        // subsequent vertical drag stays cheap (no waiting for a second
        // hold). On the long-press completion we fire `Haptics.impact()`
        // so the user feels the row «pick up» before they start moving.
        LongPressGesture(minimumDuration: 0.35)
            .sequenced(before: DragGesture(minimumDistance: 0, coordinateSpace: .local))
            .onChanged { value in
                switch value {
                case .first(true):
                    if !dragArmed {
                        dragArmed = true
                        Haptics.impact()
                    }
                case .second(true, let drag?):
                    dragArmed = true
                    let h = drag.translation.height
                    let raw = Int((h / pointsPerMinute).rounded())
                    let clamped = max(-maxDeltaMinutes, min(maxDeltaMinutes, raw))
                    let snapped = (clamped / snapMinutes) * snapMinutes
                    if snapped != lastSnappedDelta {
                        Haptics.alignment()
                        lastSnappedDelta = snapped
                    }
                    dragOffsetY = h
                    dragMinuteDelta = snapped
                default:
                    break
                }
            }
            .onEnded { value in
                // Bind the second-phase drag value just to confirm the
                // gesture fully reached drag (a press that didn't progress
                // to a drag should not commit).
                if case .second(true, _?) = value, dragMinuteDelta != 0 {
                    onReschedule?(event, dragMinuteDelta)
                    Haptics.impact()
                }
                resetDragState()
            }
    }

    /// Spring the drag visuals back to rest.
    private func resetDragState() {
        withAnimation(skin.resolvedMicroAnimation) {
            dragArmed = false
            dragOffsetY = 0
        }
        dragMinuteDelta = 0
        lastSnappedDelta = 0
    }

    /// Floating capsule showing the proposed new time + signed delta
    /// while the row is being dragged. Mirrors Apple Calendar's
    /// «hover hint» and gives the user a value to react to before
    /// they release.
    @ViewBuilder
    private var rescheduleBadge: some View {
        if dragArmed {
            let delta = dragMinuteDelta
            let proposed = event.startDate.addingTimeInterval(TimeInterval(delta * 60))
            let signed = delta == 0 ? "—" : (delta > 0 ? "+\(delta)m" : "\(delta)m")
            HStack(spacing: DS.Spacing.xs) {
                Text(signed).font(.footnote.weight(.semibold))
                    .foregroundStyle(skin.accentColor)
                Text(DS.timeFormatter.string(from: proposed))
                    .font(.footnote.monospacedDigit())
                    .foregroundStyle(skin.resolvedTextSecondary)
            }
            .padding(.horizontal, DS.Spacing.sm)
            .padding(.vertical, DS.Spacing.xxs)
            .background(skin.resolvedPlatterMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(skin.accentColor.opacity(DS.Opacity.softAccent), lineWidth: DS.Border.thin))
            .elevation(.z2, skin: skin)
            .padding(.leading, DS.Spacing.lg)
            .offset(y: -DS.Spacing.lg)
            .transition(.opacity.combined(with: .scale(scale: 0.92, anchor: .leading)))
            .allowsHitTesting(false)
        }
    }

    // MARK: - Hover Actions

    private var hoverActions: some View {
        HStack(spacing: DS.Spacing.xs) {
            if event.isUpcoming {
                Menu {
                    reminderMenuItems
                } label: {
                    Image(systemName: "bell.badge")
                        .font(.system(size: DS.Size.iconMedium, weight: .medium))
                        .foregroundStyle(skin.resolvedTextSecondary)
                }
                .buttonStyle(.borderless)
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Set reminder")
                .accessibilityLabel("Set reminder")
            }

            if isLocal {
                // Match BacklogTaskRow's xmark hover-affordance for a single
                // delete language across the app — the prior filled-minus
                // glyph also outweighed its peer icons (bell, chevron) and
                // read as the row's primary action.
                if event.isRecurring {
                    Menu {
                        Button("Delete This Event Only", role: .destructive) {
                            Haptics.impact()
                            triggerDeleteWithDisintegration { onDeleteOccurrence?(event) }
                        }
                        Button("Delete All Events", role: .destructive) {
                            Haptics.impact()
                            triggerDeleteWithDisintegration { onDeleteSeries?(event) }
                        }
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: DS.Size.iconMedium, weight: .medium))
                            .foregroundStyle(skin.resolvedDestructiveColor)
                    }
                    .buttonStyle(.borderless)
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .help("Delete recurring event")
                    .accessibilityLabel("Delete recurring event")
                } else {
                    Button {
                        Haptics.impact()
                        triggerDeleteWithDisintegration { onDelete?(event) }
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: DS.Size.iconMedium, weight: .medium))
                            .foregroundStyle(skin.resolvedDestructiveColor)
                    }
                    .buttonStyle(.borderless)
                    .help("Delete event")
                    .accessibilityLabel("Delete event")
                }
            }
        }
        .transition(
            .asymmetric(
                insertion: .move(edge: .trailing).combined(with: .opacity),
                removal: .opacity
            )
        )
    }

    private func timeUntilText(_ now: Date) -> String {
        let secondsUntilStart = Int(event.startDate.timeIntervalSince(now))
        if secondsUntilStart > 0 {
            // Event hasn't started yet
            if secondsUntilStart < 60 { return "in\u{00A0}\(secondsUntilStart)\u{00A0}s" }
            let minutes = secondsUntilStart / 60
            if minutes < 60 { return "in\u{00A0}\(minutes)\u{00A0}min" }
            let hours = minutes / 60
            if hours >= 24 {
                let days = hours / 24
                let remainingHours = hours % 24
                if remainingHours == 0 { return "in\u{00A0}\(days)\u{00A0}d" }
                return "in\u{00A0}\(days)\u{00A0}d\u{00A0}\(remainingHours)\u{00A0}h"
            }
            let mins = minutes % 60
            if mins == 0 { return "in\u{00A0}\(hours)\u{00A0}h" }
            return "in\u{00A0}\(hours)\u{00A0}h\u{00A0}\(mins)\u{00A0}min"
        }
        // Event has started or starting now
        let secondsUntilEnd = Int(event.endDate.timeIntervalSince(now))
        if secondsUntilEnd > 0 {
            if secondsUntilEnd < 60 {
                return "\(secondsUntilEnd)\u{00A0}s left"
            }
            let minutesEnd = secondsUntilEnd / 60
            let hours = minutesEnd / 60
            let mins = minutesEnd % 60
            if hours == 0 { return "\(mins)\u{00A0}min left" }
            if mins == 0 { return "\(hours)\u{00A0}h left" }
            return "\(hours)\u{00A0}h\u{00A0}\(mins)\u{00A0}min left"
        }
        return "now"
    }

    private func pomodoroSegmentColor(_ segment: CalendarEvent.PomodoroSegment) -> Color {
        switch segment {
        case .work: skin.accentColor
        case .shortBreak: skin.resolvedSuccessColor
        case .longBreak: DS.Colors.info
        }
    }

    private func triggerDeleteWithDisintegration(action: @escaping () -> Void) {
        guard !isDisintegrating else { return }
        pendingDeleteAction = action
        reminderService.beginDisintegration(for: event.id)
        isDisintegrating = true
    }

    private func eventProgress(_ now: Date) -> Double {
        guard event.startDate <= now && event.endDate > now else { return 0 }
        let total = event.endDate.timeIntervalSince(event.startDate)
        guard total > 0 else { return 0 }
        let elapsed = now.timeIntervalSince(event.startDate)
        return min(max(elapsed / total, 0), 1)
    }

    @ViewBuilder
    private var reminderMenuItems: some View {
        let activeReminders = reminderService.activeReminderMinutes(for: event)
        let customReminders = activeReminders.filter { active in 
            !DS.snoozeOptions.contains { $0.minutes == active }
        }
        let allOptions = (DS.snoozeOptions.map { $0.minutes } + customReminders).sorted()

        ForEach(allOptions, id: \.self) { minutes in
            Toggle(isOn: Binding(
                get: { activeReminders.contains(minutes) },
                set: { isSet in
                    var current = Set(activeReminders)
                    if isSet {
                        current.insert(minutes)
                    } else {
                        current.remove(minutes)
                    }
                    reminderService.updateLocalReminder(for: event.id, minutes: Array(current).sorted())
                }
            )) {
                if let option = DS.snoozeOptions.first(where: { $0.minutes == minutes }) {
                    Text(option.label)
                } else {
                    Text(DS.formatMinutes(minutes))
                }
            }
        }
        Divider()
        Button("Clear All") {
            reminderService.updateLocalReminder(for: event.id, minutes: [])
        }
        .disabled(activeReminders.isEmpty)
    }
}
