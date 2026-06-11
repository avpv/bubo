import SwiftUI
import BuboDomain
import BuboOptimizer
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
    // PRINCIPLES §9: facts are parameters, verbs are environment. The
    // row receives data and computed hints below; every action it can
    // fire comes from `\.backlogRowActions` (see BacklogRowActions.swift),
    // so intermediate layers carry zero wiring.

    let task: BacklogTask
    let isUrgent: Bool
    /// True while this specific row is being dragged by the user. Used to dim
    /// the source row so it's clear what's in flight.
    var isDragging: Bool = false
    /// Whether keyboard/context-menu reorder is currently possible. Disables
    /// the menu entries cleanly on the first and last rows.
    var canMoveUp: Bool = true
    var canMoveDown: Bool = true
    /// True when this row owns keyboard focus — drives the focus ring visual.
    var isFocused: Bool = false
    /// Pre-computed "when this would land" preview, shown inline on hover.
    /// The parent computes it the first time the cursor enters this row and
    /// caches the result. nil = not computed yet / no slot found.
    var slotPreview: String? = nil
    /// «The machine has already worked out where this task would go» — a
    /// proposed start time computed by the parent for tasks that don't fit
    /// in today's remaining workday. Rendered in the trailing meta column
    /// as `→ HH:MM` in the `DS.Typography.machineHint` voice. When
    /// `actions.findSlot` is wired the hint becomes a one-click commit:
    /// tapping it schedules just this task into the proposed slot (per-task
    /// scope of the optimizer). nil = no proposal (the row fits in today,
    /// or no proposal computed).
    var proposedSlot: Date? = nil

    /// Hot-key digit (1–9) used to teach the fullscreen Backlog's keyboard
    /// completion shortcuts via the checkbox tooltip. nil = no shortcut for
    /// this row.
    var sprintHotKey: Int? = nil

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
    /// of the fullscreen view operates on the resulting set.
    var selectionMode: Bool = false

    /// Whether this row is currently part of the multi-select set.
    /// Drives the checked glyph in the leading slot and an accent
    /// overlay around the row. Ignored when `selectionMode` is `false`.
    var isSelected: Bool = false

    // Drag side-channels — row mechanics tied to the host's drag
    // coordinator state, not user verbs; they stay parameters.

    /// Fired when this row enters the drag state so the parent can push the
    /// typed payload onto the shared coordinator.
    var onDragStart: () -> Void = {}
    /// Fired when the drag session ends (regardless of whether a drop landed).
    var onDragEnd: () -> Void = {}
    /// Side-channel hover notification — the parent uses it to trigger the
    /// slot-preview lookup. Mirrors the internal `isHovered` state but lets
    /// the owning view debounce the work without polluting row state.
    var onHoverChanged: (Bool) -> Void = { _ in }

    @Environment(\.backlogRowActions) var actions

    @State var isHovered = false
    @State var isReorderTargeted = false
    /// Loaded alternatives waiting for user pick. Driven by ⌥-click on
    /// the Schedule button: the row calls `onLoadAlternatives`, stores
    /// the result here, and flips `showAlternatives` to anchor the
    /// popover. Cleared on dismissal so a stale list never re-opens.
    @State var alternatives: [ScheduleScenario] = []
    @State var showAlternatives = false
    /// True while the GA preview is in flight. Drives the spinner that
    /// briefly replaces the Schedule button glyph so the user sees
    /// «something is happening» during the ~300\u{2013}500\u{00A0}ms
    /// the optimizer takes to produce alternatives.
    @State var loadingAlternatives = false
    /// True for the brief moment between «user tapped checkbox» and «row
    /// disappears from the active list». During this window the title gets
    /// a strikethrough, the row dims, and the checkbox glyph swaps to a
    /// filled checkmark — the same «I marked it done» frame Things and
    /// Reminders show. Skipped under `reduceMotion`.
    @State var isCompleting = false
    @Environment(\.activeSkin) var skin
    @Environment(\.accessibilityReduceMotion) var reduceMotion

    /// Delay between the strikethrough appearing and `onComplete()` firing
    /// (which removes the row from the list). Long enough to register as a
    /// confirmation frame, short enough not to feel like lag.
    static let completionAnimationDuration: TimeInterval = 0.28

    /// HH:MM-only formatter for the always-on ghost-slot hint («→ 19:30»).
    /// Locale-aware: 12-hour locales render «7:30 PM», 24-hour ones render
    /// «19:30». Cached at the type level so the formatter isn't rebuilt on
    /// every redraw of every overflowing row.
    static let proposedSlotFormatter: DateFormatter = {
        let f = DateFormatter()
        f.timeStyle = .short
        f.dateStyle = .none
        return f
    }()

    /// Compact uppercase tag for the `preferredPeriod` badge. Mirrors
    /// the Period.displayLabel shape but in a tiny abbreviated form so
    /// the badge can sit alongside other meta without crowding the row.
    static func periodBadgeLabel(_ period: Period) -> String {
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
    var isOverdue: Bool {
        guard let deadline = task.deadline else { return false }
        return deadline < Date()
    }

    /// True when the task already sits on the calendar at a known time.
    /// Drives the accent stripe on the leading edge and the «when»
    /// chip in the meta row, so the user can sort backlog at a glance
    /// into «still to plan» (no stripe) and «already planned»
    /// (accent stripe + chip with day + time).
    private var isScheduled: Bool {
        task.scheduledDate != nil
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
    var metaText: Text {
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
        guard actions.toggleUrgent != nil else { return false }
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
    var shouldShowMetaText: Bool {
        if task.deadline != nil { return true }
        if task.durationMinutes != defaultTaskDurationMinutes { return true }
        return !hasNonDurationMeta
    }

    /// Everything that was pushed off the primary line — duration (when
    /// deadline is primary), story points, project context. Revealed only
    /// on hover so the collapsed row stays one clean statement.
    var secondaryMetaText: Text? {
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
    var accessibilityRowLabel: String {
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
            // Single-channel state stripe on the leading edge of the row.
            // Two mutually exclusive cases — scheduled wins because it's
            // a more concrete state («this task is on the calendar»)
            // than the soft «due soon» urgency hint, and the deadline
            // tint on the title already carries urgency. Birman: «one
            // signal per state».
            if isScheduled {
                // Accent-coloured stripe says «already on the calendar».
                // Mirrors the prototype's `[data-scheduled="true"]::before`
                // treatment so the eye sorts active backlog into «to be
                // planned» (no stripe) vs «already planned» (accent stripe)
                // at a glance.
                RoundedRectangle(cornerRadius: DS.Size.previewMicroRadius, style: .continuous)
                    .fill(skin.accentColor)
                    .frame(width: 2)
                    .padding(.vertical, DS.Spacing.xxs)
                    .accessibilityHidden(true)
            } else if isUrgent {
                // `urgentColor` is the desaturated counterpart of
                // `destructiveColor` — same hue family, lower intensity.
                // The stripe says «due soon, prioritise», not «something
                // is broken» (which the saturated red is reserved for —
                // capacity overflow ring, overdue titles). One stripe in
                // the saturated red would compete with the over-capacity
                // ring; this split lets both coexist without crowding.
                RoundedRectangle(cornerRadius: DS.Size.previewMicroRadius, style: .continuous)
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
                    .font(.footnote.weight(.regular))
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
            actions.reorderDrop(dropped, task)
            return true
        } isTargeted: { targeted in
            withAnimation(DS.Animation.motionAware(DS.Animation.quick, reduceMotion: reduceMotion)) {
                isReorderTargeted = targeted
            }
        }
        .contextMenu {
            Group {
            // «Select» is the entry point into multi-select mode. Sits
            // at the top so a right-click on any row immediately
            // surfaces the bulk-action path; the host flips
            // `selectionMode` on and seeds the set with this row.
            // Inside selection mode the entry flips to «Deselect» so
            // the same right-click pulls the row back out without
            // breaking the user's flow.
            if let toggle = actions.toggleSelection {
                Button { toggle(task) } label: {
                    Label(
                        isSelected ? "Deselect" : "Select",
                        systemImage: isSelected ? "circle.dashed" : "checkmark.circle"
                    )
                }
                Divider()
            }
            Button { actions.complete(task) } label: {
                Label("Complete", systemImage: "checkmark.circle.fill")
            }
            Button { actions.edit(task) } label: {
                Label("Edit details\u{2026}", systemImage: "pencil")
            }

            // Per-task scope optimizer actions — Birman: «commands live
            // next to their object». «Find a slot now» runs the
            // optimizer in scope of this single task (per-task reification
            // of `findSlotsForBacklog`); «Reschedule» seeds ⌘K with this
            // task; «Set deadline» opens an inline date picker; «Mark
            // urgent» toggles a today deadline (the same deadline that
            // drives the leading red stripe).
            if actions.findSlot != nil || actions.reschedule != nil || actions.setDeadline != nil || canToggleUrgent || actions.setPreferredPeriod != nil {
                Divider()
                if let findSlot = actions.findSlot {
                    Button { findSlot(task) } label: {
                        Label("Find a slot now", systemImage: "wand.and.stars")
                    }
                }
                if let reschedule = actions.reschedule {
                    Button { reschedule(task) } label: {
                        Label("Reschedule\u{2026}", systemImage: "arrow.up.arrow.down")
                    }
                }
                if let setDeadline = actions.setDeadline {
                    Button { setDeadline(task) } label: {
                        Label("Set deadline\u{2026}", systemImage: "calendar")
                    }
                }
                if canToggleUrgent, let toggle = actions.toggleUrgent {
                    Button { toggle(task) } label: {
                        Label(urgencyToggleLabel, systemImage: "exclamationmark.triangle")
                    }
                }
                if let split = actions.splitTask, task.durationMinutes >= 90 {
                    Button { split(task) } label: {
                        Label("Split into shorter blocks", systemImage: "scissors")
                    }
                    .help("Run the optimizer to chunk this task into 2+ sequential blocks")
                }
                if let snooze = actions.snooze {
                    Menu {
                        Button("1 day")  { snooze(task, 1) }
                        Button("3 days") { snooze(task, 3) }
                        Button("1 week") { snooze(task, 7) }
                    } label: {
                        Label("Snooze for\u{2026}", systemImage: "zzz")
                    }
                    .help("Push the deadline forward by a fixed number of days")
                }
                if let setPeriod = actions.setPreferredPeriod {
                    // Sub-menu — period preferences are infrequent edits
                    // but cluster naturally as «when does this task fit
                    // best?». Bunching them keeps the parent menu calm.
                    Menu {
                        Button { setPeriod(task, .morning) } label: {
                            Label("Morning", systemImage: "sunrise")
                        }
                        .disabled(task.preferredPeriod == .morning)
                        Button { setPeriod(task, .afternoon) } label: {
                            Label("Afternoon", systemImage: "sun.max")
                        }
                        .disabled(task.preferredPeriod == .afternoon)
                        Button { setPeriod(task, .evening) } label: {
                            Label("Evening", systemImage: "sunset")
                        }
                        .disabled(task.preferredPeriod == .evening)
                        Button { setPeriod(task, .night) } label: {
                            Label("Night", systemImage: "moon.stars")
                        }
                        .disabled(task.preferredPeriod == .night)
                        if task.preferredPeriod != nil {
                            Divider()
                            Button { setPeriod(task, nil) } label: {
                                Label("Clear preference", systemImage: "xmark.circle")
                            }
                        }
                    } label: {
                        Label("Prefer time of day", systemImage: "clock")
                    }
                }
            }

            Divider()
            Button { actions.moveUp(task) } label: {
                Label("Move Up", systemImage: "arrow.up")
            }
            .disabled(!canMoveUp)
            Button { actions.moveDown(task) } label: {
                Label("Move Down", systemImage: "arrow.down")
            }
            .disabled(!canMoveDown)
            Button { actions.moveToTop(task) } label: {
                Label("Move to Top", systemImage: "arrow.up.to.line")
            }
            .disabled(!canMoveUp)
            Button { actions.moveToBottom(task) } label: {
                Label("Move to Bottom", systemImage: "arrow.down.to.line")
            }
            .disabled(!canMoveDown)
            Divider()
            // Freeze — non-destructive "set aside". Offered before Delete so
            // the destructive action isn't the default path for tasks the
            // user just doesn't want to plan right now.
            Button { actions.freeze(task) } label: {
                Label("Freeze", systemImage: "snowflake")
            }
            Button(role: .destructive) { actions.delete(task) } label: {
                Label("Delete", systemImage: "trash")
            }
            }
            .labelStyle(.titleAndIcon)
        }
        .accessibilityAction(named: "Move Up") { actions.moveUp(task) }
        .accessibilityAction(named: "Move Down") { actions.moveDown(task) }
        // Keyboard navigation on the focused row. HIG: full keyboard access.
        // A plain arrow (without Cmd) moves focus between rows, Cmd-arrow
        // reorders the rows themselves. Space / Return / Delete are the
        // primary verbs (complete / edit / delete).
        .onKeyPress(keys: [.space, .return, .upArrow, .downArrow, .delete]) { press in
            switch press.key {
            case .space:
                actions.complete(task)
                return .handled
            case .return:
                actions.edit(task)
                return .handled
            case .delete:
                // ⌘⌫ = freeze (non-destructive set-aside); plain ⌫ = delete.
                // Mirrors the context-menu ordering: Freeze precedes Delete,
                // so the safer verb gets the modifier shortcut.
                if press.modifiers.contains(.command) {
                    actions.freeze(task)
                } else {
                    actions.delete(task)
                }
                return .handled
            case .upArrow:
                if press.modifiers.contains(.command) {
                    if canMoveUp { actions.moveUp(task) }
                } else {
                    actions.focusPrevious(task)
                }
                return .handled
            case .downArrow:
                if press.modifiers.contains(.command) {
                    if canMoveDown { actions.moveDown(task) }
                } else {
                    actions.focusNext(task)
                }
                return .handled
            default:
                return .ignored
            }
        }
    }

}

