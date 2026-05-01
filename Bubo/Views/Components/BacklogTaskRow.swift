import SwiftUI
#if canImport(AppKit)
import AppKit
#endif

// MARK: - Backlog Task Row

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
    /// Side-channel hover notification — the parent uses it to trigger the
    /// slot-preview lookup. Mirrors the internal `isHovered` state but lets
    /// the owning view debounce the work without polluting row state.
    var onHoverChanged: (Bool) -> Void = { _ in }

    /// Hot-key digit (1–9) used to teach the fullscreen Backlog's keyboard
    /// completion shortcuts via the checkbox tooltip. nil = no shortcut for
    /// this row — the case for inline BacklogView, where digit keys belong
    /// to the add-task field instead.
    var sprintHotKey: Int? = nil

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
    /// deadline. Driven from the row's context menu — Birman: «явное
    /// действие должно совпадать с явным сигналом», so the «Mark urgent»
    /// label flips to «Clear urgent» when the task already has today's
    /// deadline. nil = no urgency-toggle path (read-only context).
    var onToggleUrgent: (() -> Void)? = nil

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

    @State private var isHovered = false
    @State private var isReorderTargeted = false
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
    /// signal. Birman: «не дублируй сигнал состояния». The pulsing
    /// `OverduePulseDot` next to the text remains — overdue is a subtype
    /// of urgent that earns a motion cue on top of the stripe.
    /// Without a deadline, duration fills in; always useful for
    /// "does this fit in my next slot?"
    private var metaText: Text {
        if let deadline = task.deadline {
            return Text(deadlineLabel(deadline))
                .foregroundStyle(skin.resolvedTextSecondary)
        }
        return Text(DS.formatMinutes(task.durationMinutes))
            .foregroundStyle(skin.resolvedTextSecondary)
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
    /// «Clear urgent» wouldn't apply, so we hide the action — Birman: «не
    /// предлагай выбор без смысла».
    private var canToggleUrgent: Bool {
        guard onToggleUrgent != nil else { return false }
        guard let deadline = task.deadline else { return true }
        return Calendar.current.isDateInToday(deadline)
    }

    /// «Mark urgent» when no deadline, «Clear urgent» when the deadline is
    /// today. The label flips to match the action — Birman: «постоянная
    /// видимость состояния».
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
    ///   visually empty, which Birman calls «загадочный пробел»).
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
        .frame(minHeight: BacklogView.compactRowHeight)
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
            // duplication. Birman: «один сигнал на состояние». The stripe
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
            Button("Complete") { onComplete() }
            Button("Edit details\u{2026}") { onEdit() }

            // Per-task scope optimizer actions — Birman: «команды живут
            // рядом со своим объектом». «Reschedule» seeds ⌘K with this
            // task; «Set deadline» opens an inline date picker; «Mark
            // urgent» toggles a today deadline (the same deadline that
            // drives the leading red stripe).
            if onReschedule != nil || onSetDeadline != nil || canToggleUrgent {
                Divider()
                if let reschedule = onReschedule {
                    Button("Reschedule\u{2026}") { reschedule() }
                }
                if let setDeadline = onSetDeadline {
                    Button("Set deadline\u{2026}") { setDeadline() }
                }
                if canToggleUrgent, let toggle = onToggleUrgent {
                    Button(urgencyToggleLabel) { toggle() }
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
        // Плоский arrow (без Cmd) перемещает фокус между строками, Cmd-arrow
        // — переставляет сами строки. Space / Return / Delete — основные
        // глаголы (complete / edit / delete).
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
            Image(systemName: isCompleting ? "checkmark.circle.fill" : "circle")
                .font(.callout)
                .foregroundStyle(
                    isCompleting
                        ? AnyShapeStyle(skin.accentColor)
                        // Same urgent-vs-destructive split as the left
                        // stripe: the complete-button on an urgent row
                        // shares the urgency family, but at the lower
                        // intensity (`urgentColor`) so it doesn't shout
                        // alongside truly destructive surfaces.
                        : AnyShapeStyle(isUrgent ? skin.resolvedUrgentColor : skin.resolvedTextSecondary)
                )
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(.iconPress)
        // When the fullscreen Backlog passes a hot-key digit, append it to
        // the tooltip so users discover «press N to complete» on first hover
        // instead of having to read the docs. Plain «Mark complete» otherwise.
        .help(sprintHotKey.map { "Mark complete (press \($0))" } ?? "Mark complete")
        .accessibilityLabel("Mark \u{201C}\(task.title)\u{201D} complete")
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
                // instead of only a cryptic glyph — Бирман: «язык интерфейса —
                // язык человека». The bare ⟲ remains for tag-less recurring
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

                if task.priority == .high {
                    Circle()
                        .fill(skin.resolvedDestructiveColor)
                        .frame(width: DS.Size.recipeDotSize, height: DS.Size.recipeDotSize)
                        .accessibilityLabel("High priority")
                }

                // Overdue gets a pulsing red dot before the meta text:
                // urgency должна _кричать_, а не шептать капсом. Текст
                // «Overdue» уже красный, но статичный текст легко пропустить
                // взглядом — пульсация выделяет «эта задача требует решения
                // _сейчас_». Пульс отключается при `accessibilityReduceMotion`,
                // остаётся ровный красный dot.
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
                    Text("→ \(slotPreview)")
                        .font(.footnote)
                        .foregroundStyle(skin.accentColor.opacity(DS.Opacity.accentMuted))
                        .lineLimit(1)
                        .transition(.opacity)
                        .accessibilityLabel("Would land at \(slotPreview)")
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityRowLabel)
        .accessibilityHint("Double-tap to edit")
    }

    /// Title colour — red when the deadline is today or overdue, orange for
    /// tomorrow, primary text otherwise. One channel of information, no icon
    /// required. Low-priority tasks with no deadline read as normal text.
    private var titleColor: Color {
        guard let deadline = task.deadline else { return skin.resolvedTextPrimary }
        let cal = Calendar.current
        if deadline < Date() || cal.isDateInToday(deadline) {
            return skin.resolvedDestructiveColor
        }
        if cal.isDateInTomorrow(deadline) {
            return .orange
        }
        return skin.resolvedTextPrimary
    }

    /// Reorder + delete controls, visible only on hover (Apple Reminders /
    /// Things pattern). HIG: reserve the horizontal space so layout doesn't
    /// jump when the cursor enters / leaves.
    private var controls: some View {
        HStack(spacing: DS.Spacing.xxs) {
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
        // Birman: язык интерфейса — язык человека. "in 5 days" вместо "5d".
        // `.relative(presentation: .numeric)` локализовано, без ручной сборки.
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
