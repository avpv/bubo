import SwiftUI
import UniformTypeIdentifiers
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
    /// Sprint mode tints the row for calmer reading: metadata/controls
    /// disappear, the title takes a larger font. Set by `SprintView`; the
    /// inline backlog passes the default `false`.
    var isSprintMode: Bool = false
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

    /// Hot-key digit (1–9) used to teach SprintView's keyboard completion
    /// shortcuts via the checkbox tooltip. nil = no shortcut for this row,
    /// which is the case in BacklogView's inline list. SprintView passes
    /// the row's sprint index for the first N visible tasks.
    var sprintHotKey: Int? = nil

    @State private var isHovered = false
    @State private var isReorderTargeted = false
    @Environment(\.activeSkin) private var skin
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Single primary metric for the collapsed row.
    ///
    /// Birman: "one piece of information, not a salad." The deadline wins
    /// whenever it's set — it's the most actionable answer to "should I do
    /// this now?" — and gets the urgency colour (red today/overdue,
    /// standard secondary otherwise). Without a deadline, duration fills
    /// in; it's always useful for "does this fit in my next slot?"
    private var metaText: Text {
        if let deadline = task.deadline {
            let color: Color = isUrgent
                ? skin.resolvedDestructiveColor
                : skin.resolvedTextSecondary
            return Text(deadlineLabel(deadline))
                .foregroundStyle(color)
        }
        return Text(DS.formatMinutes(task.durationMinutes))
            .foregroundStyle(skin.resolvedTextSecondary)
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
            // Trailing controls vanish in sprint mode so the row reads as a
            // quiet single column — «один режим, одна цель».
            checkbox
            content
            Spacer(minLength: DS.Spacing.xs)
            if !isSprintMode {
                controls
            }
        }
        .padding(.vertical, DS.Spacing.xxs)
        .padding(.horizontal, DS.Spacing.xs)
        .frame(minHeight: isSprintMode ? BacklogView.compactRowHeight + 8 : BacklogView.compactRowHeight)
        .contentShape(Rectangle())
        .opacity(isDragging ? DS.Opacity.tertiaryText : 1)
        .background(rowBackground)
        .overlay { focusRing }
        .onHover { hovering in
            withAnimation(DS.Animation.motionAware(DS.Animation.quick, reduceMotion: reduceMotion)) {
                isHovered = hovering
            }
            onHoverChanged(hovering)
        }
        // Drag source = the entire row. Apple Reminders / Things pattern:
        // press-and-hold lifts the row, then drag. No visible handle —
        // `.onDrag` on macOS already gates on press-and-hold, and the cursor
        // turns into a grab on hover. Inner Buttons still take taps because
        // they consume mouseDown without movement.
        .onDrag {
            onDragStart()
            let payload = BacklogTaskDrag(
                taskId: task.id,
                title: task.title,
                durationMinutes: task.durationMinutes,
                context: task.context
            )
            let provider = NSItemProvider()
            if let data = try? JSONEncoder().encode(payload) {
                provider.registerDataRepresentation(
                    forTypeIdentifier: UTType.json.identifier,
                    visibility: .ownProcess
                ) { completion in
                    completion(data, nil)
                    return nil
                }
            }
            return provider
        } preview: {
            HStack(spacing: DS.Spacing.xs) {
                Image(systemName: "calendar.badge.plus")
                    .font(.caption)
                Text(task.title)
                    .font(.caption.weight(.medium))
                Text(DS.formatMinutes(task.durationMinutes))
                    .font(.caption2)
                    .foregroundStyle(skin.resolvedTextSecondary)
            }
            .padding(.horizontal, DS.Spacing.sm)
            .padding(.vertical, DS.Spacing.xs)
            .background(skin.resolvedButtonMaterial, in: Capsule())
            .onDisappear { onDragEnd() }
        }
        .dropDestination(for: BacklogTaskDrag.self) { items, _ in
            guard let dropped = items.first, dropped.taskId != task.id else { return false }
            onReorderDrop(dropped)
            return true
        } isTargeted: { targeted in
            withAnimation(DS.Animation.motionAware(DS.Animation.quick, reduceMotion: reduceMotion)) {
                isReorderTargeted = targeted
            }
        }
        .contextMenu {
            Button("Complete") { onComplete() }
            Button("Edit") { onEdit() }
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

    // MARK: - Row sub-views

    /// Checkbox — complete on tap.
    /// HIG: controls should be at least 24pt on a side; the ~17pt glyph
    /// gets wrapped in a 24pt hit-area so the tap target is forgiving.
    private var checkbox: some View {
        Button(action: onComplete) {
            Image(systemName: "circle")
                .font(.callout)
                .foregroundStyle(isUrgent ? skin.resolvedDestructiveColor : skin.resolvedTextSecondary)
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // When SprintView passes a hot-key digit, append it to the tooltip
        // so users discover «press N to complete» on first hover instead of
        // having to read the docs. Plain «Mark complete» otherwise.
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
                    .font(isSprintMode ? .headline.weight(.medium) : .callout)
                    .foregroundStyle(titleColor)
                    .lineLimit(isSprintMode ? 1 : 2)
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
                            .font(.caption2)
                        if let tag = task.recurrenceTag,
                           !tag.trimmingCharacters(in: .whitespaces).isEmpty {
                            Text(tag)
                                .font(.caption2)
                                .lineLimit(1)
                        }
                    }
                    .foregroundStyle(skin.resolvedTextTertiary)
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
                        .font(.caption2)
                        .foregroundStyle(skin.resolvedTextTertiary)
                        .accessibilityLabel("Depends on \(task.dependsOn.count) task\(task.dependsOn.count == 1 ? "" : "s")")
                }

                if task.priority == .high {
                    Circle()
                        .fill(skin.resolvedDestructiveColor)
                        .frame(width: DS.Size.recipeDotSize, height: DS.Size.recipeDotSize)
                        .accessibilityLabel("High priority")
                }

                if !isSprintMode {
                    metaText
                        .font(.caption2)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }

                if isHovered, !isSprintMode, let secondary = secondaryMetaText {
                    secondary
                        .font(.caption2)
                        .lineLimit(1)
                        .transition(.opacity)
                }

                if isHovered, !isDragging, let slotPreview, !isSprintMode {
                    Text("→ \(slotPreview)")
                        .font(.caption2)
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
                    .font(.caption2)
                    .foregroundStyle(canMoveUp ? skin.resolvedTextSecondary : skin.resolvedTextTertiary.opacity(DS.Opacity.half))
            }
            .buttonStyle(.plain)
            .disabled(!canMoveUp)
            .help("Move up")
            .accessibilityLabel("Move \u{201C}\(task.title)\u{201D} up")

            Button(action: onMoveDown) {
                Image(systemName: "chevron.down")
                    .font(.caption2)
                    .foregroundStyle(canMoveDown ? skin.resolvedTextSecondary : skin.resolvedTextTertiary.opacity(DS.Opacity.half))
            }
            .buttonStyle(.plain)
            .disabled(!canMoveDown)
            .help("Move down")
            .accessibilityLabel("Move \u{201C}\(task.title)\u{201D} down")

            Button(action: onDelete) {
                Image(systemName: "xmark")
                    .font(.caption2)
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
