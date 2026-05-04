import SwiftUI
#if canImport(AppKit)
import AppKit
#endif

// MARK: - Backlog Task Row

extension BacklogTaskRow {
    /// Shared single-line row height for backlog rows and tombstones,
    /// surfaced both here and in `BacklogFullscreenView` /
    /// `BacklogTombstones`. Lower than the legacy 44pt because the
    /// row is one line (title + inline middot-separated metadata).
    /// Used to live on `BacklogView`; the inline backlog card is gone
    /// but the constant still defines the rhythm shared across the
    /// fullscreen surface and tombstones, so it lives on the row
    /// type itself.
    static let compactRowHeight: CGFloat = 40
}

struct BacklogTaskRow: View {
    let task: BacklogTask
    let isUrgent: Bool
    /// True while this specific row is being dragged by the user. Used to dim
    /// the source row so it's clear what's in flight.
    var isDragging: Bool = false
    /// Whether keyboard/context-menu reorder is currently possible. Disables
    /// the menu entries cleanly on the first and last rows.
    var canMoveUp: Bool = true
    var canMoveDown: Bool = true
    var onComplete: () -> Void
    var onEdit: () -> Void
    var onDelete: () -> Void
    /// Fired when the user picks "Freeze" from the context menu. Optional so
    /// preview call-sites that don't care about freezing can omit it.
    var onFreeze: () -> Void = {}
    /// Fired when this row enters the drag state so the parent can push the
    /// typed payload onto the shared coordinator.
    var onDragStart: () -> Void = {}
    /// Fired when the drag session ends (regardless of whether a drop landed).
    var onDragEnd: () -> Void = {}
    /// Fired when another backlog task is dropped onto this row. The parent
    /// decides how to integrate the drop (reorder and/or context swap).
    var onReorderDrop: (BacklogTaskDrag) -> Void = { _ in }
    var onMoveUp: () -> Void = {}
    var onMoveDown: () -> Void = {}
    var onMoveToTop: () -> Void = {}
    var onMoveToBottom: () -> Void = {}
    /// True when this row owns keyboard focus — drives the focus ring visual.
    var isFocused: Bool = false
    /// Move focus to the previous / next visible row. Called on plain ↑ / ↓
    /// (without Cmd) so keyboard navigation feels like List without the
    /// constraints of wrapping the backlog in a real List.
    var onFocusPrev: () -> Void = {}
    var onFocusNext: () -> Void = {}
    /// Pre-computed "when this would land" preview, shown inline on hover.
    /// The parent computes it the first time the cursor enters this row and
    /// caches the result. nil = not computed yet / no slot found.
    var slotPreview: String? = nil
    /// «The machine has already worked out where this task would go» — a
    /// proposed start time computed by the parent for tasks that don't fit
    /// in today's remaining workday. Rendered in the trailing meta column
    /// as `→ HH:MM` in the `DS.Typography.machineHint` voice. When
    /// `onFindSlot` is wired the hint becomes a one-click commit: tapping
    /// it schedules just this task into the proposed slot (per-task scope
    /// of the optimizer). Birman: «let the machine sweat» — the user sees
    /// a ready slot, not an abstract «over capacity», and accepts it
    /// without opening a menu. nil = no proposal (the row fits in today,
    /// or no proposal computed).
    var proposedSlot: Date? = nil
    /// Side-channel hover notification — the parent uses it to trigger the
    /// slot-preview lookup. Mirrors the internal `isHovered` state but lets
    /// the owning view debounce the work without polluting row state.
    var onHoverChanged: (Bool) -> Void = { _ in }

    /// Hot-key digit (1–9) used to teach the fullscreen Backlog's keyboard
    /// completion shortcuts via the checkbox tooltip. nil = no shortcut for
    /// this row — the case for inline BacklogView, where digit keys belong
    /// to the add-task field instead.
    var sprintHotKey: Int? = nil

    /// «Find a slot for this task» — runs the optimizer in scope of this
    /// single task and applies the result. Mirrors the SmartActions hard
    /// path at the per-task level: instead of «schedule the whole
    /// overflow», this is «schedule just this one row». Birman: «commands
    /// live next to their object» — no need to open the palette and
    /// formulate a request for a single task. nil = action hidden.
    var onFindSlot: (() -> Void)? = nil

    /// Set the task's `preferredPeriod` — surfaced as a sub-menu of
    /// «Prefer morning / afternoon / evening / night / Clear». Reifies
    /// the `preferPeriod(match:period:)` intent at the per-row level;
    /// the optimizer reads `task.preferredPeriod` directly when
    /// scheduling. nil = sub-menu hidden.
    var onSetPreferredPeriod: ((Period?) -> Void)? = nil

    /// «Split into shorter blocks» — runs the optimizer in scope of
    /// this task with `.splitLong(maxMinutes:)` so the GA chunks it
    /// into two or more sequential blocks. Surfaced only when the
    /// task is long enough for splitting to make sense (≥ 90 min);
    /// shorter tasks suppress the menu item to avoid silly proposals
    /// like «split a 30-min call». Reifies the `splitLong` intent at
    /// the per-row level. nil = action hidden.
    var onSplitTask: (() -> Void)? = nil

    /// «Snooze for…» — push the task's deadline forward by a fixed
    /// number of days (1 / 3 / 7) from a sub-menu. Reifies the manual
    /// «I can't get to this today, push it forward» action that the
    /// AutoDeferService does automatically — but here the user owns
    /// the timing. Mirrors the «Set deadline…» flow but is one-tap
    /// for the common «push it back N days» case. nil = sub-menu hidden.
    var onSnoozeByDays: ((Int) -> Void)? = nil

    /// Reschedule this task via the command palette (per-task scope optimizer
    /// entry point). Opens ⌘K seeded with the task so it lands on the
    /// «Schedule "<title>"» / «Find best time» suggestions. nil = no
    /// reschedule path (palette unavailable).
    var onReschedule: (() -> Void)? = nil
    /// Open a date-picker popover for this task's deadline. Driven by the
    /// row's context menu (Set deadline…). nil = no inline picker —
    /// `Edit details…` still opens the full editor with a deadline field.
    var onSetDeadline: (() -> Void)? = nil
    /// Toggle the urgency stripe by setting (or clearing) a today-end
    /// deadline. Driven from the row's context menu — Birman: «an explicit
    /// action should match an explicit signal», so the «Mark urgent»
    /// label flips to «Clear urgent» when the task already has today's
    /// deadline. nil = no urgency-toggle path (read-only context).
    var onToggleUrgent: (() -> Void)? = nil

    /// «Show me other slots» — runs the optimizer in scope of this
    /// task, asks for N scenarios and returns them WITHOUT applying.
    /// Surfaced via ⌥-click on the per-task Schedule button so the
    /// default click path stays one-step (commit the GA's top pick),
    /// but power users can browse runner-up slots before committing.
    /// Returning an empty list = «no alternatives found», host should
    /// surface a toast. nil = ⌥-click falls back to plain `onFindSlot`.
    var onLoadAlternatives: (() async -> [ScheduleScenario])? = nil

    /// Commit one of the alternatives produced by `onLoadAlternatives`.
    /// Kept separate from `onFindSlot` because the host needs to route
    /// it through `applyPreviewedScenario` (the scenario was never
    /// stored on `OptimizerService.scenarios` by the preview run).
    var onPickAlternative: ((ScheduleScenario) -> Void)? = nil

    /// True for ~0.5\u{00A0}s after the user drops this row via drag. Renders
    /// a brief accent-coloured outline so the eye finds the new resting
    /// position even when the drop crossed the capacity-section boundary.
    /// Caller toggles back to false after the animation window closes.
    /// `accessibilityReduceMotion` collapses the animation to an instant
    /// flash via the row's existing motion-aware modifier path.
    var wasJustDropped: Bool = false

    /// User's default task duration (from `OptimizerService`). Drives the
    /// «hide `1 h`» rule: when the row's only meta would be the default
    /// duration and another trailing-meta is present (recurrence,
    /// dependency, priority dot), the duration is suppressed so the
    /// list reads as a clean column of titles. Birman: don't print the
    /// obvious — every task uses 1 h unless told otherwise; saying so on
    /// every line is noise. When no other meta is present, duration is
    /// kept so the row's right column isn't empty.
    var defaultTaskDurationMinutes: Int = 60

    /// True when the host has put the backlog into multi-select mode.
    /// In this mode the leading checkbox toggles inclusion in the
    /// selection set instead of completing the task — the «Schedule
    /// N · Defer · Freeze · Delete» bulk-action toolbar at the bottom
    /// of the fullscreen view operates on the resulting set. Default
    /// `false` keeps every existing call-site (inline backlog,
    /// previews, tests) on the canonical complete-on-tap behaviour.
    var selectionMode: Bool = false

    /// Whether this row is currently part of the multi-select set.
    /// Drives the checked square glyph in the leading slot and an
    /// accent overlay around the row. Ignored when `selectionMode`
    /// is `false`.
    var isSelected: Bool = false

    /// Called when the user toggles this row's membership in the
    /// multi-select set. Fired on checkbox tap (in selection mode) and
    /// on the «Select» context-menu entry (which also flips
    /// `selectionMode` on for the host). nil = selection unavailable.
    var onToggleSelection: (() -> Void)? = nil

    @State private var isHovered = false
    @State private var isReorderTargeted = false
    /// Loaded alternatives waiting for user pick. Driven by ⌥-click on
    /// the Schedule button: the row calls `onLoadAlternatives`, stores
    /// the result here, and flips `showAlternatives` to anchor the
    /// popover. Cleared on dismissal so a stale list never re-opens.
    @State private var alternatives: [ScheduleScenario] = []
    @State private var showAlternatives = false
    /// True while the GA preview is in flight. Drives the spinner that
    /// briefly replaces the Schedule button glyph so the user sees
    /// «something is happening» during the ~300\u{2013}500\u{00A0}ms
    /// the optimizer takes to produce alternatives.
    @State private var loadingAlternatives = false
    /// True for the brief moment between «user tapped checkbox» and «row
    /// disappears from the active list». During this window the title gets
    /// a strikethrough, the row dims, and the checkbox glyph swaps to a
    /// filled checkmark — the same «I marked it done» frame Things and
    /// Reminders show. Skipped under `reduceMotion`.
    @State private var isCompleting = false
    @Environment(\.activeSkin) private var skin
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Delay between the strikethrough appearing and `onComplete()` firing
    /// (which removes the row from the list). Long enough to register as a
    /// confirmation frame, short enough not to feel like lag.
    private static let completionAnimationDuration: TimeInterval = 0.28

    /// HH:MM-only formatter for the always-on ghost-slot hint («→ 19:30»).
    /// Locale-aware: 12-hour locales render «7:30 PM», 24-hour ones render
    /// «19:30». Cached at the type level so the formatter isn't rebuilt on
    /// every redraw of every overflowing row.
    private static let proposedSlotFormatter: DateFormatter = {
        let f = DateFormatter()
        f.timeStyle = .short
        f.dateStyle = .none
        return f
    }()

    /// Compact uppercase tag for the `preferredPeriod` badge. Mirrors
    /// the Period.displayLabel shape but in a tiny abbreviated form so
    /// the badge can sit alongside other meta without crowding the row.
    private static func periodBadgeLabel(_ period: Period) -> String {
        switch period {
        case .night:     return "NIGHT"
        case .morning:   return "AM"
        case .afternoon: return "PM"
        case .evening:   return "EVE"
        }
    }

    /// True when the task has a deadline that's already passed. Drives the
    /// pulsing red dot in the meta row — overdue is a louder signal than
    /// «today», so it gets motion in addition to the red text colour.
    private var isOverdue: Bool {
        guard let deadline = task.deadline else { return false }
        return deadline < Date()
    }

    /// Single primary metric for the collapsed row.
    ///
    /// Birman: "one piece of information, not a salad." The deadline wins
    /// whenever it's set — it's the most actionable answer to "should I do
    /// this now?" — and reads in plain secondary tint. Urgency is carried
    /// by the leading red stripe (see `urgentStripe` overlay below) so
    /// printing the deadline text in destructive red would duplicate the
    /// signal. Birman: «don't duplicate the state signal». The pulsing
    /// `OverduePulseDot` next to the text remains — overdue is a subtype
    /// of urgent that earns a motion cue on top of the stripe.
    /// Without a deadline, duration fills in; always useful for
    /// "does this fit in my next slot?"
    private var metaText: Text {
        if let deadline = task.deadline {
            // Mirror the `titleColor` urgency split for the deadline-
            // relative text in the meta column: today/overdue inherits
            // the destructive red; tomorrow inherits the urgent
            // (desaturated) red; future deadlines stay calm secondary.
            // Single colour family across title + meta means a glance
            // down the row reads urgency consistently in both columns.
            return Text(deadlineLabel(deadline))
                .foregroundStyle(deadlineMetaColor(deadline))
        }
        return Text(DS.formatMinutes(task.durationMinutes))
            .foregroundStyle(skin.resolvedTextSecondary)
    }

    /// Color for the deadline-relative meta text. Pairs with `titleColor`
    /// so the title and the «in 2 days» label share the same urgency
    /// language — the eye reads them as one signal, not two competing
    /// tints.
    private func deadlineMetaColor(_ deadline: Date) -> Color {
        let cal = Calendar.current
        if deadline < Date() || cal.isDateInToday(deadline) {
            return skin.resolvedDestructiveColor
        }
        if cal.isDateInTomorrow(deadline) {
            return skin.resolvedUrgentColor
        }
        return skin.resolvedTextSecondary
    }

    /// Whether the row carries any non-deadline trailing metadata that the
    /// user can scan for «is this task different from the default?»
    /// Recurrence, dependency, and priority all qualify — overdue is
    /// deadline-only and handled in the deadline branch.
    private var hasNonDurationMeta: Bool {
        task.isRecurring
            || !task.dependsOn.isEmpty
            || task.priority == .high
    }

    /// Whether the «Mark urgent / Clear urgent» context-menu item is
    /// applicable. The toggle has a clean semantic only when the task either
    /// has no deadline (Mark urgent → set today) or already has today's
    /// deadline (Clear urgent → unset). When the task has a future deadline,
    /// «Mark urgent» would silently overwrite the user's planned date and
    /// «Clear urgent» wouldn't apply, so we hide the action — Birman: «don't
    /// offer a choice without meaning».
    private var canToggleUrgent: Bool {
        guard onToggleUrgent != nil else { return false }
        guard let deadline = task.deadline else { return true }
        return Calendar.current.isDateInToday(deadline)
    }

    /// «Mark urgent» when no deadline, «Clear urgent» when the deadline is
    /// today. The label flips to match the action — Birman: «constant
    /// visibility of state».
    private var urgencyToggleLabel: String {
        if let deadline = task.deadline,
           Calendar.current.isDateInToday(deadline) {
            return "Clear urgent"
        }
        return "Mark urgent"
    }

    /// Whether the row should render `metaText`. Hides the default-duration
    /// label («1 h») when another piece of meta is already telling the
    /// reader something — avoids the «wall of identical 1 h» effect on
    /// deadline-less rows. Always shows when:
    /// - the task has a deadline (the deadline IS the meta),
    /// - the duration differs from the user's default,
    /// - or no other meta is present (otherwise the right column would be
    ///   visually empty, which Birman calls «a mysterious blank»).
    private var shouldShowMetaText: Bool {
        if task.deadline != nil { return true }
        if task.durationMinutes != defaultTaskDurationMinutes { return true }
        return !hasNonDurationMeta
    }

    /// Everything that was pushed off the primary line — duration (when
    /// deadline is primary), story points, project context. Revealed only
    /// on hover so the collapsed row stays one clean statement.
    private var secondaryMetaText: Text? {
        let dot = Text("\u{00A0}·\u{00A0}").foregroundStyle(skin.resolvedTextTertiary)
        var parts: [Text] = []

        if task.deadline != nil {
            parts.append(
                Text(DS.formatMinutes(task.durationMinutes))
                    .foregroundStyle(skin.resolvedTextTertiary)
            )
        }

        if let sp = task.storyPoints {
            parts.append(
                Text("\(sp)\u{00A0}sp")
                    .foregroundStyle(skin.resolvedTextTertiary)
            )
        }

        if let context = task.context {
            parts.append(
                Text(context)
                    .foregroundStyle(skin.resolvedTextTertiary)
            )
        }

        guard !parts.isEmpty else { return nil }
        return parts.dropFirst().reduce(parts[0]) { acc, next in
            acc + dot + next
        }
    }

    /// Full VoiceOver label for the content button — assembles title,
    /// duration, priority, deadline and project in one sentence so the
    /// row is announced meaningfully.
    private var accessibilityRowLabel: String {
        var parts: [String] = [task.title, DS.formatMinutes(task.durationMinutes)]
        if task.priority == .high { parts.append("high priority") }
        if let sp = task.storyPoints { parts.append("\(sp) story points") }
        if !task.subtasks.isEmpty {
            let progress = task.subtaskProgress
            parts.append("\(progress.done) of \(progress.total) subtasks done")
        }
        if !task.tags.isEmpty {
            parts.append("tagged " + task.tags.map { "#\($0)" }.joined(separator: " "))
        }
        if let deadline = task.deadline {
            parts.append("due \(deadlineLabel(deadline))")
        }
        if let context = task.context { parts.append("in \(context)") }
        return parts.joined(separator: ", ")
    }

    var body: some View {
        HStack(spacing: DS.Spacing.sm) {
            checkbox
            // Dim everything except the checkbox while completion is in
            // flight: title takes the strikethrough, metadata fades to
            // tertiary, controls become non-interactive. The checkbox
            // itself stays at full opacity so the «filled checkmark»
            // success glyph reads loud and clear — this is the moment the
            // user just clicked. Same idea as Things' completion frame.
            content
                .opacity(isCompleting ? DS.Opacity.tertiaryText : 1)
            Spacer(minLength: DS.Spacing.xs)
            controls
                .opacity(isCompleting ? DS.Opacity.tertiaryText : 1)
                .allowsHitTesting(!isCompleting)
        }
        .padding(.vertical, DS.Spacing.xxs)
        .padding(.horizontal, DS.Spacing.xs)
        .frame(minHeight: Self.compactRowHeight)
        .contentShape(Rectangle())
        // Drag pickup feedback (source side): the source row ONLY dims
        // while in flight — it stays in place as a ghost so the user sees
        // «this is where it came from». Scale + shadow live on the drag
        // preview thumb (`.onDrag preview:` below) where they belong:
        // the thumb is the lifted, in-flight representation. Two visual
        // states for one object would conflict — dim says «I'm here in
        // memory», thumb says «I'm in your hand».
        .opacity(isDragging ? DS.Opacity.tertiaryText : 1)
        .animation(
            DS.Animation.motionAware(DS.Animation.quick, reduceMotion: reduceMotion),
            value: isDragging
        )
        .background(rowBackground)
        .overlay(alignment: .leading) {
            // Single-channel urgency signal — a 2pt red bar on the leading
            // edge of the row. Replaces the previous deadline-text-color
            // duplication. Birman: «one signal per state». The stripe
            // sits inside the row's outer frame so it doesn't shift the
            // baseline; vertical inset keeps it visually inside the
            // rounded corners.
            if isUrgent {
                // `urgentColor` is the desaturated counterpart of
                // `destructiveColor` — same hue family, lower intensity.
                // The stripe says «due soon, prioritise», not «something
                // is broken» (which the saturated red is reserved for —
                // capacity overflow ring, overdue titles). One stripe in
                // the saturated red would compete with the over-capacity
                // ring; this split lets both coexist without crowding.
                RoundedRectangle(cornerRadius: 1, style: .continuous)
                    .fill(skin.resolvedUrgentColor)
                    .frame(width: 2)
                    .padding(.vertical, DS.Spacing.xxs)
                    .accessibilityHidden(true)
            }
        }
        .overlay { focusRing }
        .overlay {
            // Multi-select indicator — quiet accent stroke on selected
            // rows so the eye reads «which rows the bulk-toolbar acts
            // on» without each row growing a separate badge. Lives
            // inside the row's outer frame, identical corner radius to
            // the focus ring so the two never bleed into each other
            // when both fire (focused + selected).
            if selectionMode && isSelected {
                RoundedRectangle(cornerRadius: DS.Size.subtleCornerRadius, style: .continuous)
                    .strokeBorder(skin.accentColor.opacity(DS.Opacity.softAccent), lineWidth: DS.Border.selection)
                    .background(
                        RoundedRectangle(cornerRadius: DS.Size.subtleCornerRadius, style: .continuous)
                            .fill(skin.accentColor.opacity(DS.Opacity.subtleFill))
                    )
                    .accessibilityHidden(true)
            }
        }
        .overlay {
            // Drop-pulse outline: a brief accent-coloured ring that flashes
            // for ~0.5\u{00A0}s after the user drops this row via drag, so
            // the eye finds the landing spot when the row crossed the
            // fits → spill-over boundary. Driven by `wasJustDropped` set
            // by the parent in `handleReorderDrop`.
            if wasJustDropped {
                RoundedRectangle(cornerRadius: DS.Size.subtleCornerRadius, style: .continuous)
                    .strokeBorder(skin.accentColor.opacity(DS.Opacity.softAccent), lineWidth: DS.Border.selection)
                    .transition(.opacity)
            }
        }
        .animation(
            DS.Animation.motionAware(DS.Animation.quick, reduceMotion: reduceMotion),
            value: wasJustDropped
        )
        .onHover { hovering in
            withAnimation(DS.Animation.motionAware(DS.Animation.quick, reduceMotion: reduceMotion)) {
                isHovered = hovering
            }
            onHoverChanged(hovering)
        }
        // Drag source = the entire row. Apple Reminders / Things pattern:
        // press-and-hold lifts the row, then drag. No visible handle —
        // `.draggable` on macOS already gates on press-and-hold, and the
        // cursor turns into a grab on hover. Inner Buttons still take taps
        // because they consume mouseDown without movement.
        //
        // `.draggable` over the older `.onDrag` because the drop targets
        // (`FreeSlotRow`, the reorder destination below) already speak
        // Transferable via `dropDestination(for:)`. Same protocol on both
        // ends means no NSItemProvider/UTType bridging in the middle.
        .draggable(makeDragPayload()) {
            // Drag preview thumb — this is what the user actually «holds»
            // in their hand: the floating representation that follows the
            // cursor. It gets the scale + shadow lift (`DS.Physics.dragPreview*`)
            // because IT is the lifted object. Source row stays at 1.0 and
            // dims (above) — two roles, two visual states, no conflict.
            HStack(spacing: DS.Spacing.xs) {
                Image(systemName: "calendar.badge.plus")
                    .font(.footnote)
                Text(task.title)
                    .font(.footnote.weight(.medium))
                Text(DS.formatMinutes(task.durationMinutes))
                    .font(.footnote)
                    .foregroundStyle(skin.resolvedTextSecondary)
            }
            .padding(.horizontal, DS.Spacing.sm)
            .padding(.vertical, DS.Spacing.xs)
            .background(skin.resolvedButtonMaterial, in: Capsule())
            .scaleEffect(DS.Physics.dragPreviewScale)
            .shadow(
                color: skin.resolvedShadowColor,
                radius: DS.Physics.dragPreviewShadowRadius,
                y: DS.Physics.dragPreviewShadowY
            )
            .onDisappear { onDragEnd() }
        }
        .dropDestination(for: BacklogTaskDrag.self) { items, _ in
            guard let dropped = items.first, dropped.taskId != task.id else { return false }
            // Same snap-tick as `FreeSlotRow` drop — drag-to-reorder and
            // drag-onto-slot are physically the same «object cosied into a
            // place» moment, so they should feel identical on Force Touch.
            // Asymmetric haptics for symmetric gestures was a known
            // imbalance after the first physical-feedback pass.
            Haptics.alignment()
            onReorderDrop(dropped)
            return true
        } isTargeted: { targeted in
            withAnimation(DS.Animation.motionAware(DS.Animation.quick, reduceMotion: reduceMotion)) {
                isReorderTargeted = targeted
            }
        }
        .contextMenu {
            // «Select» is the entry point into multi-select mode. Sits
            // at the top so a right-click on any row immediately
            // surfaces the bulk-action path; the host flips
            // `selectionMode` on and seeds the set with this row.
            // Inside selection mode the entry flips to «Deselect» so
            // the same right-click pulls the row back out without
            // breaking the user's flow.
            if let toggle = onToggleSelection {
                Button(isSelected ? "Deselect" : "Select") { toggle() }
                Divider()
            }
            Button("Complete") { onComplete() }
            Button("Edit details\u{2026}") { onEdit() }

            // Per-task scope optimizer actions — Birman: «commands live
            // next to their object». «Find a slot now» runs the
            // optimizer in scope of this single task (per-task reification
            // of `findSlotsForBacklog`); «Reschedule» seeds ⌘K with this
            // task; «Set deadline» opens an inline date picker; «Mark
            // urgent» toggles a today deadline (the same deadline that
            // drives the leading red stripe).
            if onFindSlot != nil || onReschedule != nil || onSetDeadline != nil || canToggleUrgent || onSetPreferredPeriod != nil {
                Divider()
                if let findSlot = onFindSlot {
                    Button("Find a slot now") { findSlot() }
                }
                if let reschedule = onReschedule {
                    Button("Reschedule\u{2026}") { reschedule() }
                }
                if let setDeadline = onSetDeadline {
                    Button("Set deadline\u{2026}") { setDeadline() }
                }
                if canToggleUrgent, let toggle = onToggleUrgent {
                    Button(urgencyToggleLabel) { toggle() }
                }
                if let split = onSplitTask, task.durationMinutes >= 90 {
                    Button("Split into shorter blocks") { split() }
                        .help("Run the optimizer to chunk this task into 2+ sequential blocks")
                }
                if let snooze = onSnoozeByDays {
                    Menu("Snooze for\u{2026}") {
                        Button("1 day")  { snooze(1) }
                        Button("3 days") { snooze(3) }
                        Button("1 week") { snooze(7) }
                    }
                    .help("Push the deadline forward by a fixed number of days")
                }
                if let setPeriod = onSetPreferredPeriod {
                    // Sub-menu — period preferences are infrequent edits
                    // but cluster naturally as «when does this task fit
                    // best?». Bunching them keeps the parent menu calm.
                    Menu("Prefer time of day") {
                        Button("Morning") { setPeriod(.morning) }
                            .disabled(task.preferredPeriod == .morning)
                        Button("Afternoon") { setPeriod(.afternoon) }
                            .disabled(task.preferredPeriod == .afternoon)
                        Button("Evening") { setPeriod(.evening) }
                            .disabled(task.preferredPeriod == .evening)
                        Button("Night") { setPeriod(.night) }
                            .disabled(task.preferredPeriod == .night)
                        if task.preferredPeriod != nil {
                            Divider()
                            Button("Clear preference") { setPeriod(nil) }
                        }
                    }
                }
            }

            Divider()
            Button("Move Up") { onMoveUp() }
                .disabled(!canMoveUp)
            Button("Move Down") { onMoveDown() }
                .disabled(!canMoveDown)
            Button("Move to Top") { onMoveToTop() }
                .disabled(!canMoveUp)
            Button("Move to Bottom") { onMoveToBottom() }
                .disabled(!canMoveDown)
            Divider()
            // Freeze — non-destructive "set aside". Offered before Delete so
            // the destructive action isn't the default path for tasks the
            // user just doesn't want to plan right now.
            Button("Freeze") { onFreeze() }
            Button("Delete", role: .destructive) { onDelete() }
        }
        .accessibilityAction(named: "Move Up") { onMoveUp() }
        .accessibilityAction(named: "Move Down") { onMoveDown() }
        // Keyboard navigation on the focused row. HIG: full keyboard access.
        // A plain arrow (without Cmd) moves focus between rows, Cmd-arrow
        // reorders the rows themselves. Space / Return / Delete are the
        // primary verbs (complete / edit / delete).
        .onKeyPress(keys: [.space, .return, .upArrow, .downArrow, .delete]) { press in
            switch press.key {
            case .space:
                onComplete()
                return .handled
            case .return:
                onEdit()
                return .handled
            case .delete:
                // ⌘⌫ = freeze (non-destructive set-aside); plain ⌫ = delete.
                // Mirrors the context-menu ordering: Freeze precedes Delete,
                // so the safer verb gets the modifier shortcut.
                if press.modifiers.contains(.command) {
                    onFreeze()
                } else {
                    onDelete()
                }
                return .handled
            case .upArrow:
                if press.modifiers.contains(.command) {
                    if canMoveUp { onMoveUp() }
                } else {
                    onFocusPrev()
                }
                return .handled
            case .downArrow:
                if press.modifiers.contains(.command) {
                    if canMoveDown { onMoveDown() }
                } else {
                    onFocusNext()
                }
                return .handled
            default:
                return .ignored
            }
        }
    }

    // MARK: - Drag payload

    /// Build the typed payload for `.draggable`. Passing the call expression
    /// (not a literal value) into `.draggable`'s `@autoclosure` parameter
    /// means SwiftUI re-evaluates this each time the drag starts — the only
    /// place we can hang the «pickup» haptic and the coordinator
    /// notification so they fire on the actual drag, not on every body
    /// re-render.
    private func makeDragPayload() -> BacklogTaskDrag {
        // Tactile «pickup» click on Force Touch trackpads — fires on the
        // exact moment the row enters drag state, syncing with the visual
        // dim above. No-op on regular pointers.
        Haptics.tap()
        onDragStart()
        return BacklogTaskDrag(
            taskId: task.id,
            title: task.title,
            durationMinutes: task.durationMinutes,
            context: task.context
        )
    }

    // MARK: - Row sub-views

    /// Checkbox — complete on tap.
    /// HIG: controls should be at least 24pt on a side; the ~17pt glyph
    /// gets wrapped in a 24pt hit-area so the tap target is forgiving.
    /// Squishes 8% on press (`IconPressStyle`) plus a tactile click on
    /// Force Touch trackpads, so the «I marked it done» moment registers
    /// before the row's removal animation even starts.
    private var checkbox: some View {
        Button {
            Haptics.tap()
            // In selection mode the leading slot toggles inclusion in the
            // bulk-action set rather than completing — the user is in
            // «curate the queue» flow, not «mark this one done», and a
            // misclick that completes the wrong task is harder to undo
            // than a misclick that selects the wrong row.
            if selectionMode, let toggle = onToggleSelection {
                toggle()
                return
            }
            // Reduce Motion: no confirmation frame — `onComplete()` fires
            // immediately and the row removes via the standard animation.
            // Otherwise: light up the strikethrough + filled glyph, hold
            // for `completionAnimationDuration`, then complete. Guarded
            // by `isCompleting` so a double-tap doesn't fire onComplete()
            // twice (the second tap would try to complete an already-removed
            // task, which is harmless but pollutes the undo stream).
            guard !isCompleting else { return }
            if reduceMotion {
                onComplete()
                return
            }
            withAnimation(DS.Animation.motionAware(DS.Animation.standard, reduceMotion: reduceMotion)) {
                isCompleting = true
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.completionAnimationDuration) {
                onComplete()
            }
        } label: {
            Image(systemName: checkboxGlyph)
                .font(.callout)
                .foregroundStyle(checkboxTint)
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(.iconPress)
        // When the fullscreen Backlog passes a hot-key digit, append it to
        // the tooltip so users discover «press N to complete» on first hover
        // instead of having to read the docs. Plain «Mark complete» otherwise.
        .help(checkboxHelp)
        .accessibilityLabel(
            selectionMode
                ? (isSelected
                    ? "Deselect \u{201C}\(task.title)\u{201D}"
                    : "Select \u{201C}\(task.title)\u{201D}")
                : "Mark \u{201C}\(task.title)\u{201D} complete"
        )
    }

    /// SF Symbol for the leading slot. Selection mode swaps the
    /// «circle» / «checkmark.circle.fill» pair for «square» /
    /// «checkmark.square.fill» so the gesture grammar reads visibly
    /// different from completion (rounded = action, square = list
    /// membership). Mirrors the macOS Mail / Reminders idiom.
    private var checkboxGlyph: String {
        if selectionMode {
            return isSelected ? "checkmark.square.fill" : "square"
        }
        return isCompleting ? "checkmark.circle.fill" : "circle"
    }

    /// Tint for the leading glyph. Accent in completion frame (just
    /// clicked) and in selection frame (currently selected); urgent
    /// rows keep the desaturated red voice, otherwise calm secondary.
    private var checkboxTint: AnyShapeStyle {
        if selectionMode {
            return isSelected
                ? AnyShapeStyle(skin.accentColor)
                : AnyShapeStyle(skin.resolvedTextSecondary)
        }
        if isCompleting {
            return AnyShapeStyle(skin.accentColor)
        }
        // Same urgent-vs-destructive split as the left stripe: the
        // complete-button on an urgent row shares the urgency family,
        // but at the lower intensity (`urgentColor`) so it doesn't
        // shout alongside truly destructive surfaces.
        return AnyShapeStyle(isUrgent ? skin.resolvedUrgentColor : skin.resolvedTextSecondary)
    }

    /// Tooltip for the leading glyph. Selection mode wins over the
    /// hot-key hint because the «complete by digit» path is suspended
    /// while bulk-select is active.
    private var checkboxHelp: String {
        if selectionMode {
            return isSelected ? "Deselect this task" : "Select this task"
        }
        return sprintHotKey.map { "Mark complete (press \($0))" } ?? "Mark complete"
    }

    /// Single-line content: title + priority dot + middot-separated metadata.
    /// Title gets `layoutPriority(1)` so it holds onto space; metadata
    /// truncates first when the row narrows.
    private var content: some View {
        Button(action: onEdit) {
            HStack(spacing: DS.Spacing.xs) {
                Text(task.title)
                    .font(.callout)
                    .foregroundStyle(titleColor)
                    .strikethrough(isCompleting, color: skin.resolvedTextSecondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .layoutPriority(1)
                    .help(task.title)

                // Recurring marker. If the task carries a `recurrenceTag`
                // ("weekly review", "daily standup"), show it as human text
                // instead of only a cryptic glyph — Birman: «the language
                // of the interface is human language». The bare ⟲ remains for tag-less recurring
                // tasks so the affordance is still present.
                if task.isRecurring {
                    HStack(spacing: DS.Spacing.xxs) {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .font(.footnote)
                        if let tag = task.recurrenceTag,
                           !tag.trimmingCharacters(in: .whitespaces).isEmpty {
                            Text(tag)
                                .font(.footnote)
                                .lineLimit(1)
                        }
                    }
                    .foregroundStyle(skin.resolvedTextTertiary)
                    .help((task.recurrenceTag?.isEmpty == false)
                        ? "Recurring task: \(task.recurrenceTag!)"
                        : "Recurring task")
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(
                        (task.recurrenceTag?.isEmpty == false)
                            ? "Recurring: \(task.recurrenceTag!)"
                            : "Recurring"
                    )
                }

                // Dependency marker — mirrors the edit form's "depends on"
                // section. A small arrow hints at the relationship without
                // naming the blockers inline (titles could be long).
                if !task.dependsOn.isEmpty {
                    Image(systemName: "arrow.right")
                        .font(.footnote)
                        .foregroundStyle(skin.resolvedTextTertiary)
                        .accessibilityLabel("Depends on \(task.dependsOn.count) task\(task.dependsOn.count == 1 ? "" : "s")")
                }

                // Preferred-period badge — reifies the `preferredPeriod`
                // field that the optimizer already reads. «AM» / «PM» /
                // «EVE» / «NIGHT» as a tiny uppercase tag in the
                // machineHint voice; the user sees the constraint they
                // set without opening the edit form. Birman: «a rule
                // must be visible where it acts».
                if let period = task.preferredPeriod {
                    Text(Self.periodBadgeLabel(period))
                        .font(DS.Typography.machineHint)
                        .foregroundStyle(skin.resolvedTextTertiary)
                        .padding(.horizontal, DS.Spacing.xxs)
                        .background(
                            Capsule().fill(skin.resolvedTextTertiary.opacity(0.08))
                        )
                        .accessibilityLabel("Prefers \(period.displayLabel)")
                }

                // Tags — first up to two as compact "#tag" labels in the
                // tertiary voice. Many-per-task by design, but the row only
                // surfaces a teaser to keep the right-side meta strip
                // calm; the rest live in the editor / search. Birman:
                // «don't show everything there is — show enough».
                if !task.tags.isEmpty {
                    HStack(spacing: DS.Spacing.xxs) {
                        ForEach(task.tags.prefix(2), id: \.self) { tag in
                            Text("#\(tag)")
                                .font(.footnote)
                                .lineLimit(1)
                                .foregroundStyle(skin.resolvedTextTertiary)
                        }
                        if task.tags.count > 2 {
                            Text("+\(task.tags.count - 2)")
                                .font(DS.Typography.machineHint)
                                .foregroundStyle(skin.resolvedTextTertiary)
                        }
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Tags: " + task.tags.map { "#\($0)" }.joined(separator: ", "))
                }

                // Subtasks progress — "2/5" chip when the task carries a
                // checklist. Done count + total + a checklist glyph; mirrors
                // Apple Reminders' inline progress so the parent row already
                // hints at how much is left without expanding.
                if !task.subtasks.isEmpty {
                    let progress = task.subtaskProgress
                    let allDone = progress.done == progress.total
                    HStack(spacing: DS.Spacing.xxs) {
                        Image(systemName: allDone ? "checklist.checked" : "checklist")
                            .font(.footnote)
                        Text("\(progress.done)/\(progress.total)")
                            .font(DS.Typography.metric(skin: skin))
                            .monospacedDigit()
                    }
                    .foregroundStyle(skin.resolvedTextTertiary)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("\(progress.done) of \(progress.total) subtasks done")
                }

                // Notes / link indicator — silent presence cue for tasks
                // that carry context beyond the title. Single tertiary
                // glyph matches the dependency arrow's visual weight,
                // so the right-side meta strip stays a calm column of
                // small symbols rather than a parade of competing
                // icons. Edit form surfaces the actual content.
                if (task.notes?.isEmpty == false) || task.url != nil {
                    Image(systemName: task.url != nil ? "link" : "doc.text")
                        .font(.footnote)
                        .foregroundStyle(skin.resolvedTextTertiary)
                        .accessibilityLabel(task.url != nil ? "Has link" : "Has notes")
                }

                if task.priority == .high {
                    Circle()
                        .fill(skin.resolvedDestructiveColor)
                        .frame(width: DS.Size.recipeDotSize, height: DS.Size.recipeDotSize)
                        .accessibilityLabel("High priority")
                }

                // Overdue gets a pulsing red dot before the meta text:
                // urgency must _shout_, not whisper in caps. The
                // «Overdue» text is already red, but static text is easy to
                // overlook — the pulse emphasizes «this task needs a
                // decision _now_». The pulse is disabled under
                // `accessibilityReduceMotion`, leaving a steady red dot.
                if isOverdue {
                    OverduePulseDot(reduceMotion: reduceMotion)
                        .accessibilityHidden(true)
                }
                if shouldShowMetaText {
                    // `DS.Typography.metric` — meta text in this slot is
                    // always a numeric/temporal fact («1 h», «in 2 days»,
                    // «Today», «Overdue»). Single voice with the inline
                    // header digits so a glance down the column sees one
                    // rhythm of data, not a mix of font weights.
                    metaText
                        .font(DS.Typography.metric(skin: skin))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }

                if isHovered, let secondary = secondaryMetaText {
                    secondary
                        .font(.footnote)
                        .lineLimit(1)
                        .transition(.opacity)
                }

                if isHovered, !isDragging, let slotPreview {
                    // Hover-preview keeps its accent tint (this is the
                    // user-initiated «here's where it'd land» lookup,
                    // not the always-on machine voice). But adopt the
                    // `machineHint` font to match the always-on
                    // ghost-slot rendering rhythm — the two voices share
                    // typography and only differ in tint, so the eye
                    // reads them as «same kind of fact, different state».
                    Text("→ \(slotPreview)")
                        .font(DS.Typography.machineHint)
                        .foregroundStyle(skin.accentColor.opacity(DS.Opacity.accentMuted))
                        .lineLimit(1)
                        .transition(.opacity)
                        .accessibilityLabel("Would land at \(slotPreview)")
                } else if !isDragging, let proposed = proposedSlot {
                    // Always-on ghost-slot for overflowing tasks. Quiet,
                    // monospaced, tertiary at rest; lifts to the accent
                    // colour on hover when `onFindSlot` is wired so the
                    // user reads it as «click to commit this slot».
                    // Suppressed only when the explicit `slotPreview`
                    // lookup above is showing — they share the trailing
                    // column and would otherwise stack.
                    proposedSlotHint(proposed)
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityRowLabel)
        .accessibilityHint("Double-tap to edit")
    }

    /// «→ HH:MM» trailing hint. Pure label — the action lives in the
    /// hover-controls Schedule button so the click target is properly
    /// sized and physically separated from the row-wide Edit gesture.
    /// The label still lifts to accent on hover when `onFindSlot` is
    /// wired, signalling «this is the slot the Schedule button will
    /// commit». Birman: «one signal per state» — the colour change is
    /// the *visual link* between the proposed time and its action.
    @ViewBuilder
    private func proposedSlotHint(_ proposed: Date) -> some View {
        let label = Self.proposedSlotFormatter.string(from: proposed)
        let isLinked = isHovered && onFindSlot != nil
        Text("→ \(label)")
            .font(DS.Typography.machineHint)
            .foregroundStyle(isLinked ? skin.accentColor : skin.resolvedTextTertiary)
            .lineLimit(1)
            .accessibilityLabel(isLinked ? "Will schedule into \(label)" : "Proposed slot \(label)")
    }

    /// Title colour — red when the deadline is today or overdue, orange for
    /// tomorrow, primary text otherwise. One channel of information, no icon
    /// required. Low-priority tasks with no deadline read as normal text.
    private var titleColor: Color {
        guard let deadline = task.deadline else { return skin.resolvedTextPrimary }
        let cal = Calendar.current
        if deadline < Date() || cal.isDateInToday(deadline) {
            // Today / overdue → saturated destructive red. The strongest
            // urgency signal in the row's title.
            return skin.resolvedDestructiveColor
        }
        if cal.isDateInTomorrow(deadline) {
            // Tomorrow → desaturated red of the same family
            // (`urgentColor`). Same hue as the row's left stripe and
            // the «N urgent» pill, so all three signals read as «this
            // task is time-sensitive» without competing for the same
            // visual weight as truly destructive surfaces.
            return skin.resolvedUrgentColor
        }
        return skin.resolvedTextPrimary
    }

    /// Tooltip for the per-task Schedule button — uses the proposed slot
    /// when one is computed, otherwise the generic «Find a slot» (the
    /// optimizer will pick one). Mirrored into the a11y label so VO
    /// users hear the same intent. Kept as a computed string so the
    /// button site stays one-liner.
    private var scheduleButtonTooltip: String {
        if let proposed = proposedSlot {
            return "Schedule into \(Self.proposedSlotFormatter.string(from: proposed))"
        }
        return "Find a slot"
    }

    /// Tooltip wording for the Schedule button — extends the bare
    /// `scheduleButtonTooltip` with the ⌥-click affordance whenever
    /// an alternatives loader is wired. macOS's tooltip strings are
    /// the only place we can teach the modifier without taking a
    /// row of pixels for a hint, so the help text doubles as the
    /// discoverability surface.
    private var scheduleButtonHelpText: String {
        if onLoadAlternatives != nil {
            return "\(scheduleButtonTooltip)  \u{2022}  \u{2325}-click for alternatives"
        }
        return scheduleButtonTooltip
    }

    /// Schedule-button click router. ⌥ surfaces the alternatives
    /// popover, plain click commits the GA's top pick. The modifier
    /// check uses `NSEvent.modifierFlags` because SwiftUI's `Button`
    /// doesn't expose modifier state in its action closure; querying
    /// the static at click time is the canonical AppKit pattern and
    /// avoids spinning up a custom NSGestureRecognizer just for this.
    /// Falls back to the plain action when the loader isn't wired,
    /// so non-schedulable contexts still get the one-click commit.
    private func handleScheduleClick(findSlot: () -> Void) {
        #if canImport(AppKit)
        let optionHeld = NSEvent.modifierFlags.contains(.option)
        #else
        let optionHeld = false
        #endif

        if optionHeld, let loader = onLoadAlternatives, onPickAlternative != nil {
            loadingAlternatives = true
            Task {
                let loaded = await loader()
                await MainActor.run {
                    loadingAlternatives = false
                    if loaded.isEmpty {
                        // Fall back to the plain commit so ⌥-click on
                        // a row with no alternatives still does
                        // *something* useful — the user asked to
                        // schedule, we schedule the best (only) pick.
                        onFindSlot?()
                    } else {
                        alternatives = loaded
                        showAlternatives = true
                    }
                }
            }
            return
        }

        findSlot()
    }

    /// Schedule + reorder + delete controls, visible only on hover (Apple
    /// Reminders / Things pattern). HIG: reserve the horizontal space so
    /// layout doesn't jump when the cursor enters / leaves. The Schedule
    /// button leads — it's the only positive («I want this in my day»)
    /// action in the set; chevrons reorder, xmark destroys. Birman:
    /// «commands live next to their object» with a proper hit target,
    /// physically separated from the row-wide Edit gesture.
    private var controls: some View {
        HStack(spacing: DS.Spacing.xxs) {
            if let findSlot = onFindSlot {
                Button(action: { handleScheduleClick(findSlot: findSlot) }) {
                    ZStack {
                        // Reserve the icon's slot so the row doesn't
                        // jitter when the spinner swaps in for the
                        // ~half-second the GA preview takes.
                        Image(systemName: "calendar.badge.clock")
                            .font(.footnote)
                            .foregroundStyle(skin.accentColor)
                            .opacity(loadingAlternatives ? 0 : 1)
                        if loadingAlternatives {
                            ProgressView()
                                .controlSize(.mini)
                                .scaleEffect(0.6)
                        }
                    }
                }
                .buttonStyle(.plain)
                .disabled(loadingAlternatives)
                .help(scheduleButtonHelpText)
                .accessibilityLabel("\(scheduleButtonTooltip), \u{201C}\(task.title)\u{201D}")
                .accessibilityHint(onLoadAlternatives == nil
                    ? ""
                    : "Hold Option to choose from alternative slots")
                .popover(isPresented: $showAlternatives, arrowEdge: .top) {
                    SlotAlternativesPopover(
                        task: task,
                        scenarios: alternatives,
                        onPick: { scenario in
                            showAlternatives = false
                            onPickAlternative?(scenario)
                        },
                        onCancel: { showAlternatives = false }
                    )
                }
            }

            Button(action: onMoveUp) {
                Image(systemName: "chevron.up")
                    .font(.footnote)
                    .foregroundStyle(canMoveUp ? skin.resolvedTextSecondary : skin.resolvedTextTertiary.opacity(DS.Opacity.half))
            }
            .buttonStyle(.plain)
            .disabled(!canMoveUp)
            .help("Move up")
            .accessibilityLabel("Move \u{201C}\(task.title)\u{201D} up")

            Button(action: onMoveDown) {
                Image(systemName: "chevron.down")
                    .font(.footnote)
                    .foregroundStyle(canMoveDown ? skin.resolvedTextSecondary : skin.resolvedTextTertiary.opacity(DS.Opacity.half))
            }
            .buttonStyle(.plain)
            .disabled(!canMoveDown)
            .help("Move down")
            .accessibilityLabel("Move \u{201C}\(task.title)\u{201D} down")

            Button(action: onDelete) {
                Image(systemName: "xmark")
                    .font(.footnote)
                    .foregroundStyle(skin.resolvedTextTertiary)
            }
            .buttonStyle(.plain)
            .help("Delete task")
            .accessibilityLabel("Delete \u{201C}\(task.title)\u{201D}")
        }
        .opacity(isHovered ? 1 : 0)
        .accessibilityHidden(!isHovered)
    }

    /// Row background — drop highlight wins over hover tint when both fire.
    private var rowBackground: some View {
        let targetedFill = skin.accentColor.opacity(DS.Opacity.mediumFill)
        let hoverTint = skin.resolvedTextTertiary.opacity(0.06)
        let fill: Color = isReorderTargeted
            ? targetedFill
            : (isHovered ? hoverTint : .clear)
        return RoundedRectangle(cornerRadius: DS.Size.subtleCornerRadius, style: .continuous)
            .fill(fill)
    }

    /// Keyboard focus ring. Mirrors the system focus ring visually without
    /// the heavyweight default (which also draws a halo around each embedded
    /// button).
    @ViewBuilder
    private var focusRing: some View {
        if isFocused {
            RoundedRectangle(cornerRadius: DS.Size.subtleCornerRadius, style: .continuous)
                .strokeBorder(skin.accentColor, lineWidth: 2)
        }
    }

    private func deadlineLabel(_ date: Date) -> String {
        let cal = Calendar.current
        let now = Date()
        if cal.isDateInToday(date) { return "Today" }
        if cal.isDateInTomorrow(date) { return "Tomorrow" }
        if date < now { return "Overdue" }
        // Birman: the language of the interface is human language. "in 5 days" instead of "5d".
        // `.relative(presentation: .numeric)` is localized, without manual assembly.
        return date.formatted(.relative(presentation: .numeric))
    }
}

// MARK: - Overdue Pulse Dot

/// Red dot that softly pulses opacity to draw the eye to overdue tasks.
/// Sits before the meta text in the row footer. Static (no animation) when
/// `reduceMotion` is on — colour alone still flags the state.
private struct OverduePulseDot: View {
    let reduceMotion: Bool
    @Environment(\.activeSkin) private var skin
    @State private var pulsing = false

    var body: some View {
        Circle()
            .fill(skin.resolvedDestructiveColor)
            .frame(width: DS.Size.recipeDotSize, height: DS.Size.recipeDotSize)
            .opacity(reduceMotion ? 1 : (pulsing ? 0.35 : 1))
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
                    pulsing = true
                }
            }
    }
}
