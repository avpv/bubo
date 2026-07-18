import SwiftUI
import BuboDomain
import BuboOptimizer
#if canImport(AppKit)
import AppKit
#endif

// MARK: - BacklogTaskRow drag payload + sub-views
//
// Subview helpers (checkbox, content, controls, backgrounds, chips)
// plus the drag payload builder. Extracted from BacklogTaskRow.swift.

extension BacklogTaskRow {

    // MARK: - Drag payload

    /// Build the typed payload for `.draggable`. Passing the call expression
    /// (not a literal value) into `.draggable`'s `@autoclosure` parameter
    /// means SwiftUI re-evaluates this each time the drag starts — the only
    /// place we can hang the «pickup» haptic and the coordinator
    /// notification so they fire on the actual drag, not on every body
    /// re-render.
    func makeDragPayload() -> BacklogTaskDrag {
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
    var checkbox: some View {
        Button {
            Haptics.tap()
            // In selection mode the leading slot toggles inclusion in the
            // bulk-action set rather than completing — the user is in
            // «curate the queue» flow, not «mark this one done», and a
            // misclick that completes the wrong task is harder to undo
            // than a misclick that selects the wrong row.
            if selectionMode, let toggle = actions.toggleSelection {
                toggle(task)
                return
            }
            // Reduce Motion: no confirmation frame — completion fires
            // immediately and the row removes via the standard animation.
            // Otherwise: light up the strikethrough + filled glyph, hold
            // for `completionAnimationDuration`, then complete. Guarded
            // by `isCompleting` so a double-tap doesn't fire completion
            // twice (the second tap would try to complete an already-removed
            // task, which is harmless but pollutes the undo stream).
            guard !isCompleting else { return }
            if reduceMotion {
                actions.complete(task)
                return
            }
            withAnimation(DS.Animation.motionAware(DS.Animation.standard, reduceMotion: reduceMotion)) {
                isCompleting = true
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.completionAnimationDuration) { [actions, task] in
                actions.complete(task)
            }
        } label: {
            Image(systemName: checkboxGlyph)
                .font(DS.Typography.body(skin: skin))
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

    /// SF Symbol for the leading slot. The prototype keeps the circle
    /// shape across both modes — completion *and* multi-select — and
    /// only flips the fill: empty `circle` for unselected /
    /// uncompleted, filled `checkmark.circle.fill` (accent) for
    /// selected or completed. A square-vs-circle split read as
    /// «different system» rather than «same control, different mode»
    /// and clashed with the prototype's `ui_kits/backlog/index.html`
    /// where the checkbox stays a circle in `data-bl-state="selected"`.
    var checkboxGlyph: String {
        if selectionMode {
            return isSelected ? "checkmark.circle.fill" : "circle"
        }
        return isCompleting ? "checkmark.circle.fill" : "circle"
    }

    /// Tint for the leading glyph. Accent in completion frame (just
    /// clicked) and in selection frame (currently selected); urgent
    /// rows keep the desaturated red voice, otherwise calm secondary.
    var checkboxTint: AnyShapeStyle {
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
    var checkboxHelp: String {
        if selectionMode {
            return isSelected ? "Deselect this task" : "Select this task"
        }
        return sprintHotKey.map { "Mark complete (press \($0))" } ?? "Mark complete"
    }

    /// Two-deck content. Deck one: the title with its urgency companions
    /// (overdue pulse, priority glyph) and the trailing machine hint.
    /// Deck two: one quiet meta line with a fixed budget (`metaBudget`).
    /// The old single-line layout raced the title against up to nine
    /// meta elements for the same width — and lost on every long title.
    var content: some View {
        Button(action: { actions.edit(task) }) {
            VStack(alignment: .leading, spacing: DS.Spacing.xxs) {
                titleLine
                metaLine
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityRowLabel)
        .accessibilityHint("Double-tap to edit")
    }

    private var titleLine: some View {
        HStack(alignment: .firstTextBaseline, spacing: DS.Spacing.xs) {
            Text(task.title)
                // Tasks form a column of titles inside the backlog —
                // each one is the row's headline. PRINCIPLES §8: derive
                // weight one step bolder than the active skin's body so
                // bold-body skins still keep the title→meta hierarchy.
                // Default skin: regular body → medium title (13/500),
                // matching the prototype's `.bb-task .title`.
                .font(.system(.body, design: skin.resolvedFontDesign, weight: skin.resolvedHeadlineFontWeight))
                .foregroundStyle(titleColor)
                .strikethrough(isCompleting, color: skin.resolvedTextSecondary)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .layoutPriority(1)
                .help(task.title)

            if isOverdue {
                // Urgency rides next to the title, not buried mid-meta:
                // the pulse is the loudest signal the row can emit and
                // shares the deck with the red title it amplifies. Pulse
                // is disabled under Reduce Motion, leaving a steady dot.
                OverduePulseDot(reduceMotion: reduceMotion)
                    .accessibilityHidden(true)
            }

            if task.priority == .high {
                // A glyph, not a second red dot: high-priority and
                // overdue need distinct shapes even under Reduce Motion
                // (HIG: don't rely solely on color to differentiate).
                Image(systemName: "exclamationmark.circle.fill")
                    .font(.footnote)
                    .foregroundStyle(skin.resolvedDestructiveColor)
                    .accessibilityLabel("High priority")
            }

            Spacer(minLength: 0)

            if isHovered, !isDragging, let slotPreview {
                // Hover-preview keeps its accent tint (this is the
                // user-initiated «here's where it'd land» lookup, not
                // the always-on machine voice), but shares `machineHint`
                // typography with the ghost hint below so the two read
                // as the same kind of fact in different states.
                Text("→ \(slotPreview)")
                    .font(DS.Typography.machineHint)
                    .foregroundStyle(skin.accentColor.opacity(DS.Opacity.accentMuted))
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                    .transition(.opacity)
                    .accessibilityLabel("Would land at \(slotPreview)")
            } else if !isDragging, let proposed = proposedSlot {
                proposedSlotHint(proposed)
            }
        }
    }

    /// Meta-line budget: at most this many facts render inline; the rest
    /// collapse into a «+N» tail. Keeps the second deck one calm line
    /// (Birman: «don't show everything there is — show enough»).
    private static let metaBudget = 4

    /// One fact on the meta line — a stable identity for ForEach plus
    /// the type-erased view. A struct rather than a tuple because
    /// SwiftUI's ForEach needs a key path and tuples don't provide one.
    private struct MetaItem: Identifiable {
        let id: String
        let view: AnyView
    }

    /// Ordered meta facts for the second deck, most actionable first:
    /// the temporal fact (deadline/duration), the calendar landing spot,
    /// then progress and classification marks.
    private var metaItems: [MetaItem] {
        var items: [MetaItem] = []
        if shouldShowMetaText {
            items.append(MetaItem(id: "meta", view: AnyView(
                metaText
                    .font(DS.Typography.metric(skin: skin))
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            )))
        }
        if task.scheduledDate != nil {
            items.append(MetaItem(id: "when", view: AnyView(scheduledWhenLabel)))
        }
        if !task.subtasks.isEmpty {
            items.append(MetaItem(id: "subtasks", view: AnyView(subtaskProgressMark)))
        }
        if task.isRecurring {
            items.append(MetaItem(id: "recurring", view: AnyView(recurrenceMark)))
        }
        if let period = task.preferredPeriod {
            items.append(MetaItem(id: "period", view: AnyView(periodBadge(period))))
        }
        if !task.tags.isEmpty {
            items.append(MetaItem(id: "tags", view: AnyView(tagsCluster)))
        }
        if !task.dependsOn.isEmpty {
            items.append(MetaItem(id: "depends", view: AnyView(dependencyMark)))
        }
        if (task.notes?.isEmpty == false) || task.url != nil {
            items.append(MetaItem(id: "notes", view: AnyView(notesMark)))
        }
        return items
    }

    @ViewBuilder
    private var metaLine: some View {
        let items = metaItems
        // Gated on `items`, not on hover: a hover-only second deck would
        // grow the row under the cursor and reflow the whole list. Rows
        // without a meta line stay one line; the hover-revealed secondary
        // meta rides the existing deck only.
        if !items.isEmpty {
            HStack(spacing: DS.Spacing.sm) {
                ForEach(items.prefix(Self.metaBudget)) { item in
                    item.view
                }
                if items.count > Self.metaBudget {
                    Text("+\(items.count - Self.metaBudget)")
                        .font(DS.Typography.machineHint)
                        .foregroundStyle(skin.resolvedTextTertiary)
                        .help("More details in the editor")
                }
                if isHovered, let secondary = secondaryMetaText {
                    secondary
                        .font(.footnote)
                        .lineLimit(1)
                        .transition(.opacity)
                }
            }
        }
    }

    // MARK: - Meta-line marks

    /// Recurring marker — ⟲ glyph plus the human recurrence tag when set
    /// («weekly review»); Birman: «the language of the interface is human
    /// language». The bare glyph remains for tag-less recurring tasks.
    private var recurrenceMark: some View {
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

    /// Dependency marker — mirrors the edit form's "depends on" section.
    /// A small arrow hints at the relationship without naming the
    /// blockers inline (titles could be long).
    private var dependencyMark: some View {
        Image(systemName: "arrow.right")
            .font(.footnote)
            .foregroundStyle(skin.resolvedTextTertiary)
            .accessibilityLabel("Depends on \(task.dependsOn.count)\u{00A0}task\(task.dependsOn.count == 1 ? "" : "s")")
    }

    /// Preferred-period badge — reifies the `preferredPeriod` field the
    /// optimizer already reads. «AM» / «PM» / «EVE» / «NIGHT» as a tiny
    /// uppercase tag in the machineHint voice. Birman: «a rule must be
    /// visible where it acts».
    private func periodBadge(_ period: Period) -> some View {
        Text(Self.periodBadgeLabel(period))
            .font(DS.Typography.machineHint)
            .foregroundStyle(skin.resolvedTextTertiary)
            .padding(.horizontal, DS.Spacing.xxs)
            .background(
                Capsule().fill(skin.resolvedTextTertiary.opacity(DS.Opacity.lightFill))
            )
            .accessibilityLabel("Prefers \(period.displayLabel)")
    }

    /// Tags — first up to two as compact "#tag" labels in the tertiary
    /// voice plus a «+N» tail; the rest live in the editor / search.
    private var tagsCluster: some View {
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

    /// Subtask progress — "2/5" plus a checklist glyph; mirrors Apple
    /// Reminders' inline progress so the parent row already hints at how
    /// much is left without expanding.
    private var subtaskProgressMark: some View {
        let progress = task.subtaskProgress
        let allDone = progress.done == progress.total
        return HStack(spacing: DS.Spacing.xxs) {
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

    /// Notes / link indicator — silent presence cue for tasks that carry
    /// context beyond the title. The edit form surfaces the content.
    private var notesMark: some View {
        Image(systemName: task.url != nil ? "link" : "doc.text")
            .font(.footnote)
            .foregroundStyle(skin.resolvedTextTertiary)
            .accessibilityLabel(task.url != nil ? "Has link" : "Has notes")
    }

    /// «→ HH:MM» trailing hint. Pure label — the action lives in the
    /// hover-controls Schedule button so the click target is properly
    /// sized and physically separated from the row-wide Edit gesture.
    /// The label still lifts to accent on hover when `onFindSlot` is
    /// wired, signalling «this is the slot the Schedule button will
    /// commit». Birman: «one signal per state» — the colour change is
    /// the *visual link* between the proposed time and its action.
    @ViewBuilder
    func proposedSlotHint(_ proposed: Date) -> some View {
        let label = DS.timeFormatter.string(from: proposed)
        let isLinked = isHovered && actions.findSlot != nil
        Text("→ \(label)")
            .font(DS.Typography.machineHint)
            .foregroundStyle(isLinked ? skin.accentColor : skin.resolvedTextTertiary)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .accessibilityLabel(isLinked ? "Will schedule into \(label)" : "Proposed slot \(label)")
    }

    /// Title colour — red when the deadline is today or overdue, urgent
    /// for tomorrow, primary text otherwise. Routed through the shared
    /// `deadlineTint` cascade so the title and the meta column can never
    /// disagree about what «urgent» looks like.
    var titleColor: Color {
        guard let deadline = task.deadline else { return skin.resolvedTextPrimary }
        return deadlineTint(deadline, calm: skin.resolvedTextPrimary)
    }

    /// Tooltip for the per-task Schedule button — uses the proposed slot
    /// when one is computed, otherwise the generic «Find a slot» (the
    /// optimizer will pick one). Mirrored into the a11y label so VO
    /// users hear the same intent. Kept as a computed string so the
    /// button site stays one-liner.
    var scheduleButtonTooltip: String {
        if let proposed = proposedSlot {
            return "Schedule into \(DS.timeFormatter.string(from: proposed))"
        }
        return "Find a slot"
    }

    /// Tooltip wording for the Schedule button — extends the bare
    /// `scheduleButtonTooltip` with the ⌥-click affordance whenever
    /// an alternatives loader is wired. macOS's tooltip strings are
    /// the only place we can teach the modifier without taking a
    /// row of pixels for a hint, so the help text doubles as the
    /// discoverability surface.
    var scheduleButtonHelpText: String {
        if actions.loadAlternatives != nil {
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
    func handleScheduleClick(findSlot: () -> Void) {
        #if canImport(AppKit)
        let optionHeld = NSEvent.modifierFlags.contains(.option)
        #else
        let optionHeld = false
        #endif

        if optionHeld, let loader = actions.loadAlternatives, actions.pickAlternative != nil {
            loadingAlternatives = true
            Task { [actions, task] in
                let loaded = await loader(task)
                await MainActor.run {
                    loadingAlternatives = false
                    if loaded.isEmpty {
                        // Fall back to the plain commit so ⌥-click on
                        // a row with no alternatives still does
                        // *something* useful — the user asked to
                        // schedule, we schedule the best (only) pick.
                        actions.findSlot?(task)
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
    var controls: some View {
        HStack(spacing: DS.Spacing.xxs) {
            if let findSlot = actions.findSlot {
                Button(action: { handleScheduleClick(findSlot: { findSlot(task) }) }) {
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
                .accessibilityHint(actions.loadAlternatives == nil
                    ? ""
                    : "Hold Option to choose from alternative slots")
                .popover(isPresented: $showAlternatives, arrowEdge: .top) {
                    SlotAlternativesPopover(
                        task: task,
                        scenarios: alternatives,
                        onPick: { scenario in
                            showAlternatives = false
                            actions.pickAlternative?(scenario)
                        },
                        onCancel: { showAlternatives = false }
                    )
                }
            }

            Button(action: { actions.moveUp(task) }) {
                Image(systemName: "chevron.up")
                    .font(.footnote)
                    .foregroundStyle(canMoveUp ? skin.resolvedTextSecondary : skin.resolvedTextTertiary.opacity(DS.Opacity.half))
            }
            .buttonStyle(.plain)
            .disabled(!canMoveUp)
            .help("Move up")
            .accessibilityLabel("Move \u{201C}\(task.title)\u{201D} up")

            Button(action: { actions.moveDown(task) }) {
                Image(systemName: "chevron.down")
                    .font(.footnote)
                    .foregroundStyle(canMoveDown ? skin.resolvedTextSecondary : skin.resolvedTextTertiary.opacity(DS.Opacity.half))
            }
            .buttonStyle(.plain)
            .disabled(!canMoveDown)
            .help("Move down")
            .accessibilityLabel("Move \u{201C}\(task.title)\u{201D} down")

            Button(action: { actions.delete(task) }) {
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

    func deadlineLabel(_ date: Date) -> String {
        let cal = Calendar.current
        let now = Date()
        if cal.isDateInToday(date) { return "Today" }
        if cal.isDateInTomorrow(date) { return "Tomorrow" }
        if date < now { return "Overdue" }
        // Birman: the language of the interface is human language. "in 5 days" instead of "5d".
        // `.relative(presentation: .numeric)` is localized, without manual assembly.
        return date.formatted(.relative(presentation: .numeric))
    }

    /// Scheduled-when label — quiet calendar glyph + «Today 15:14».
    /// Demoted from an accent-filled capsule: the chip was the loudest
    /// element of the whole list yet did nothing on click (PRINCIPLES
    /// §5 — status must not dress as a button), and it spent the accent
    /// colour on a routine per-row fact (§7 — the leading stripe
    /// already says «planned» in accent). PRINCIPLES §10: the fact
    /// never compresses — without `fixedSize` a long title squeezed the
    /// old chip to ~0pt and its label folded one character per line,
    /// ballooning the row.
    @ViewBuilder
    var scheduledWhenLabel: some View {
        if let scheduledDate = task.scheduledDate {
            HStack(spacing: DS.Spacing.xxs) {
                Image(systemName: "calendar")
                    .font(.caption2)
                Text(DS.dayTimeLabel(scheduledDate))
                    .font(DS.Typography.metric(skin: skin))
                    .monospacedDigit()
                    .lineLimit(1)
            }
            .fixedSize()
            .foregroundStyle(skin.resolvedTextSecondary)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Scheduled \(DS.dayTimeLabel(scheduledDate))")
        }
    }
}
