import SwiftUI
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

    /// Single-line content: title + priority dot + middot-separated metadata.
    /// Title gets `layoutPriority(1)` so it holds onto space; metadata
    /// truncates first when the row narrows.
    var content: some View {
        Button(action: onEdit) {
            HStack(spacing: DS.Spacing.xs) {
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
                        .accessibilityLabel("Depends on \(task.dependsOn.count)\u{00A0}task\(task.dependsOn.count == 1 ? "" : "s")")
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
                            Capsule().fill(skin.resolvedTextTertiary.opacity(DS.Opacity.lightFill))
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

                // Scheduled-when chip — tiny accent capsule with calendar
                // glyph + day/time («Today 14:00», «Tomorrow 09:30»,
                // «Tue 14:00»). Mirrors the prototype's `.when-chip`
                // surfacing on `[data-scheduled="true"]` rows so the
                // user knows exactly when an already-planned task lands
                // without opening the editor.
                scheduledWhenChip

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
    func proposedSlotHint(_ proposed: Date) -> some View {
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
    var titleColor: Color {
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
    var scheduleButtonTooltip: String {
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
    var scheduleButtonHelpText: String {
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
    func handleScheduleClick(findSlot: () -> Void) {
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
    var controls: some View {
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
    /// A quiet hairline on `--fg-1` at 8 % wraps the row so each task
    /// reads as its own object on the popover material. Hover and drop
    /// states retain the inherited fill behaviour; the stroke stays
    /// constant so the eye keeps a stable card boundary between idle
    /// and active states.
    var rowBackground: some View {
        let targetedFill = skin.accentColor.opacity(DS.Opacity.mediumFill)
        let hoverTint = skin.resolvedTextTertiary.opacity(DS.Opacity.subtleFill)
        let fill: Color = isReorderTargeted
            ? targetedFill
            : (isHovered ? hoverTint : .clear)
        let shape = RoundedRectangle(cornerRadius: DS.Size.subtleCornerRadius, style: .continuous)
        return ZStack {
            shape.fill(fill)
            shape.strokeBorder(
                skin.resolvedTextPrimary.opacity(DS.Mix.surfaceDivider),
                lineWidth: DS.Border.thin
            )
        }
    }

    /// Keyboard focus ring. Mirrors the system focus ring visually without
    /// the heavyweight default (which also draws a halo around each embedded
    /// button).
    @ViewBuilder
    var focusRing: some View {
        if isFocused {
            RoundedRectangle(cornerRadius: DS.Size.subtleCornerRadius, style: .continuous)
                .strokeBorder(skin.accentColor, lineWidth: DS.Border.selection)
        }
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

    @ViewBuilder
    var scheduledWhenChip: some View {
        if let scheduledDate = task.scheduledDate {
            HStack(spacing: 3) {
                // PRINCIPLES §8: caption2 is the smallest macOS text
                // step — picks up Dynamic Type. Previous 9/11pt
                // literals locked the chip to a hand-tuned scale.
                Image(systemName: "calendar")
                    .font(.caption2.weight(.semibold))
                Text(scheduledChipLabel(scheduledDate))
                    .font(.caption2.weight(.semibold))
                    .monospacedDigit()
            }
            .foregroundStyle(skin.accentColor)
            .padding(.horizontal, DS.Spacing.xs)
            .padding(.vertical, DS.Spacing.xxs)
            .background(
                RoundedRectangle(cornerRadius: DS.Size.microCornerRadius, style: .continuous)
                    .fill(skin.accentColor.opacity(DS.Opacity.lightFill))
            )
            .accessibilityLabel("Scheduled \(scheduledChipLabel(scheduledDate))")
        }
    }

    /// Compact «day + time» label for the scheduled-when chip. Today and
    /// tomorrow get human names; everything else gets an abbreviated
    /// weekday so the chip stays narrow («Tue 14:00»). Time format is
    /// locale-aware via `H:mm` template (12h vs 24h respects user pref).
    func scheduledChipLabel(_ date: Date) -> String {
        let cal = Calendar.current
        let timeFmt = DateFormatter()
        timeFmt.setLocalizedDateFormatFromTemplate("Hmm")
        let timeStr = timeFmt.string(from: date)
        if cal.isDateInToday(date) { return "Today\u{00A0}\(timeStr)" }
        if cal.isDateInTomorrow(date) { return "Tomorrow\u{00A0}\(timeStr)" }
        let dayFmt = DateFormatter()
        dayFmt.setLocalizedDateFormatFromTemplate("EEE")
        return "\(dayFmt.string(from: date))\u{00A0}\(timeStr)"
    }
}
