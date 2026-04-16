import SwiftUI

// MARK: - Backlog Task Edit Row (Inline, Autosave)

/// Truly inline editing — every change persists immediately, no Save/Cancel
/// chrome, Esc collapses the card back to the read-only row.
///
/// HIG: direct manipulation — the form IS the task, not a dialog about the
/// task. ⌘↩ and Esc (and clicking Return in the title) all end editing.
/// Birman: *«редактирование без модальности»* — значит не «сохранить и
/// применить», а «менять — уже применено». Отмена — через undo-toast на
/// Complete / Delete / Reorder, не через Cancel-кнопку.
struct BacklogTaskEditRow: View {
    let task: BacklogTask
    var backlogService: BacklogService
    var onDone: () -> Void

    @State private var title: String
    @State private var durationMinutes: Int
    @State private var priority: TaskPriority
    @State private var deadline: Date?
    @State private var hasDeadline: Bool
    @State private var context: String
    @State private var storyPoints: Int?
    @State private var isRecurring: Bool
    @State private var recurrenceTag: String
    @State private var dependsOn: [String]
    /// Preferred time of day for this task — morning/afternoon/evening or
    /// "any" (nil). Fed into the optimizer via `toOptimizableEvent`'s
    /// `preferredHourRange`, which nudges the scheduler without forcing it.
    @State private var preferredPeriod: Period?
    /// Currently-selected task in the "Add dependency" picker — resets to nil
    /// after each successful add so the picker returns to its placeholder.
    @State private var newDependencyId: String? = nil
    /// Substring filter for the dependency picker — lets the user narrow a
    /// long backlog down to the task they want to link without scrolling
    /// through dozens of menu entries.
    @State private var dependencyQuery: String = ""
    @Environment(\.activeSkin) private var skin
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var isTitleFocused: Bool

    init(task: BacklogTask, backlogService: BacklogService, onDone: @escaping () -> Void) {
        self.task = task
        self.backlogService = backlogService
        self.onDone = onDone
        _title = State(initialValue: task.title)
        _durationMinutes = State(initialValue: task.durationMinutes)
        _priority = State(initialValue: task.priority)
        _deadline = State(initialValue: task.deadline)
        _hasDeadline = State(initialValue: task.deadline != nil)
        _context = State(initialValue: task.context ?? "")
        _storyPoints = State(initialValue: task.storyPoints)
        _isRecurring = State(initialValue: task.isRecurring)
        _recurrenceTag = State(initialValue: task.recurrenceTag ?? "")
        _dependsOn = State(initialValue: task.dependsOn)
        _preferredPeriod = State(initialValue: task.preferredPeriod)
    }

    private static let durationOptions = [15, 30, 45, 60, 90, 120, 180, 240]
    private static let spOptions: [Int?] = [nil, 1, 2, 3, 5, 8, 13]
    /// Periods exposed as pills. Night is intentionally omitted — it's in
    /// the optimizer model to cover after-midnight slots, but surfacing
    /// "Night" on a daytime planner reads as a trap. Users who really
    /// want night work can still get there via preferred-hour logic
    /// elsewhere.
    private static let periodOptions: [Period?] = [nil, .morning, .afternoon, .evening]
    /// Width of the "Project" inline text field — roughly 15 caption2-chars
    /// at system font; wider than that wastes horizontal space in a
    /// 360pt-wide popover.
    private static let contextFieldWidth: CGFloat = 120
    /// Threshold above which the dependency picker grows a search field.
    /// Small pools stay uncluttered; longer pools get the filter to keep
    /// the menu manageable.
    private static let dependencySearchThreshold: Int = 8

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.sm) {
            // Title. HIG: Return submits → ends editing; ⌘↩ and Esc do the
            // same. Typography matches the display-state row (.callout, no
            // weight bump) so entering edit mode doesn't feel like a jump.
            TextField("Task name", text: $title)
                .textFieldStyle(.plain)
                .font(.callout)
                .focused($isTitleFocused)
                .onSubmit { commit() }
                .onChange(of: title) { _, _ in autosave() }

            // Duration pills
            VStack(alignment: .leading, spacing: DS.Spacing.xxs) {
                Text("Duration")
                    .font(.caption2)
                    .foregroundStyle(skin.resolvedTextSecondary)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: DS.Spacing.xs) {
                        ForEach(Self.durationOptions, id: \.self) { mins in
                            chipButton(
                                label: DS.formatMinutes(mins),
                                isActive: durationMinutes == mins
                            ) {
                                durationMinutes = mins
                                autosave()
                            }
                        }
                    }
                }
            }

            // Priority pills
            VStack(alignment: .leading, spacing: DS.Spacing.xxs) {
                Text("Priority")
                    .font(.caption2)
                    .foregroundStyle(skin.resolvedTextSecondary)
                HStack(spacing: DS.Spacing.xs) {
                    ForEach(TaskPriority.allCases, id: \.self) { p in
                        chipButton(label: p.label, isActive: priority == p) {
                            priority = p
                            autosave()
                        }
                    }
                }
            }

            // Story points
            VStack(alignment: .leading, spacing: DS.Spacing.xxs) {
                Text("Story points")
                    .font(.caption2)
                    .foregroundStyle(skin.resolvedTextSecondary)
                HStack(spacing: DS.Spacing.xs) {
                    ForEach(Self.spOptions, id: \.self) { sp in
                        chipButton(
                            label: sp.map { "\($0)" } ?? "—",
                            isActive: storyPoints == sp
                        ) {
                            storyPoints = sp
                            autosave()
                        }
                    }
                }
            }

            // Deadline toggle + picker
            HStack {
                Toggle("Deadline", isOn: $hasDeadline)
                    .font(.caption2)
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .onChange(of: hasDeadline) { _, _ in autosave() }
                if hasDeadline {
                    DatePicker("", selection: Binding(
                        get: { deadline ?? Date() },
                        set: { deadline = $0; autosave() }
                    ), displayedComponents: .date)
                    .labelsHidden()
                    .controlSize(.small)
                }
            }

            // Context
            HStack(spacing: DS.Spacing.xs) {
                Text("Project")
                    .font(.caption2)
                    .foregroundStyle(skin.resolvedTextSecondary)
                TextField("optional", text: $context)
                    .textFieldStyle(.plain)
                    .font(.caption2)
                    .frame(maxWidth: Self.contextFieldWidth)
                    .onChange(of: context) { _, _ in autosave() }
                    .onSubmit { commit() }
            }

            // Preferred time of day. Nudges the optimizer toward a part
            // of the day ("do focus work in the morning") without hard-
            // binding the task to specific hours. The pill labelled "Any"
            // clears the preference so the scheduler can place the task
            // wherever fits best.
            VStack(alignment: .leading, spacing: DS.Spacing.xxs) {
                Text("Time of day")
                    .font(.caption2)
                    .foregroundStyle(skin.resolvedTextSecondary)
                HStack(spacing: DS.Spacing.xs) {
                    ForEach(Self.periodOptions, id: \.self) { period in
                        chipButton(
                            label: period?.displayLabel ?? "Any",
                            isActive: preferredPeriod == period
                        ) {
                            preferredPeriod = period
                            autosave()
                        }
                    }
                }
            }

            // Recurring toggle. Flipped on, completion will reset the task
            // to pending instead of marking it done — useful for weekly
            // reviews, daily standups, etc. A free-form tag becomes the
            // human label shown next to the ⟲ glyph on the row
            // («⟲ weekly review») — Бирман: «язык интерфейса — язык
            // человека», глиф без подписи ничего не говорит.
            VStack(alignment: .leading, spacing: DS.Spacing.xxs) {
                HStack {
                    Toggle("Repeats", isOn: $isRecurring)
                        .font(.caption2)
                        .toggleStyle(.switch)
                        .controlSize(.mini)
                        .onChange(of: isRecurring) { _, _ in autosave() }
                }
                if isRecurring {
                    HStack(spacing: DS.Spacing.xs) {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .font(.caption2)
                            .foregroundStyle(skin.resolvedTextTertiary)
                        TextField("e.g. weekly review, daily standup", text: $recurrenceTag)
                            .textFieldStyle(.plain)
                            .font(.caption2)
                            .onChange(of: recurrenceTag) { _, _ in autosave() }
                            .onSubmit { commit() }
                    }
                    .padding(.leading, DS.Spacing.sm)
                    .transition(.opacity)
                }
            }
            .motionAwareAnimation(DS.Animation.quick, value: isRecurring, reduceMotion: reduceMotion)

            // Dependencies. Each entry is another task whose completion
            // should block this one. The picker offers all active tasks
            // except self and already-linked ones; ✕ clears a link.
            dependencySection

            // Footer hint — replaces the old Save/Cancel row. The intent
            // is clear: changes are already saved; user only needs a way
            // to leave edit mode.
            HStack(spacing: DS.Spacing.xs) {
                Spacer()
                Text("\u{23CE} or \u{238B} to finish")
                    .font(.caption2)
                    .foregroundStyle(skin.resolvedTextTertiary)
                    .accessibilityHidden(true)
                Button("Done") { commit() }
                    .font(.caption.weight(.semibold))
                    .buttonStyle(.plain)
                    .foregroundStyle(skin.accentColor)
                    .keyboardShortcut(.return, modifiers: .command)
                    .accessibilityLabel("Finish editing")
            }
        }
        .padding(.vertical, DS.Spacing.sm)
        .padding(.horizontal, DS.Spacing.sm)
        .background(
            RoundedRectangle(cornerRadius: DS.Size.subtleCornerRadius, style: .continuous)
                .fill(skin.accentColor.opacity(DS.Opacity.subtleFill))
        )
        // HIG: Escape exits the edit state cleanly — previously only a
        // Cancel button handled this, which failed with keyboard-only use.
        .onExitCommand { commit() }
        .task {
            // `.task` instead of `.onAppear` — fires only after the view is
            // in the window hierarchy, which is where FocusState can
            // actually take. Fixes a flaky focus bug where
            // `isTitleFocused = true` in `.onAppear` silently missed.
            try? await Task.sleep(for: .milliseconds(50))
            isTitleFocused = true
        }
    }

    /// Persist the current snapshot without leaving edit mode — fired from
    /// every field's onChange so there's no "unsaved state".
    private func autosave() {
        let trimmed = title.trimmingCharacters(in: .whitespaces)
        // Don't clobber the title with an empty string — the user is
        // probably mid-edit. Other fields save unconditionally.
        guard !trimmed.isEmpty else { return }
        var updated = task
        updated.title = trimmed
        updated.durationMinutes = durationMinutes
        updated.priority = priority
        updated.deadline = hasDeadline ? (deadline ?? Date()) : nil
        updated.context = context.isEmpty ? nil : context
        updated.storyPoints = storyPoints
        updated.isRecurring = isRecurring
        // Stored as optional so an empty tag round-trips to nil —
        // the row renders the bare ⟲ glyph without an empty label.
        let trimmedTag = recurrenceTag.trimmingCharacters(in: .whitespaces)
        updated.recurrenceTag = (isRecurring && !trimmedTag.isEmpty) ? trimmedTag : nil
        updated.dependsOn = dependsOn
        updated.preferredPeriod = preferredPeriod
        backlogService.updateTask(updated)
    }

    /// Pick-or-remove UI for task dependencies. Linked tasks render as small
    /// pills with an ✕ button; a trailing picker adds a new link.
    /// Other active tasks from the backlog populate the picker. Frozen/done
    /// tasks are excluded because depending on them means "never unblocks".
    ///
    /// An inline substring filter keeps the picker usable once the backlog
    /// grows past ~20 tasks — scrolling through the whole menu to find one
    /// specific task is the exact thing HIG's "direct manipulation" warns
    /// against.
    @ViewBuilder
    private var dependencySection: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.xxs) {
            Text("Depends on")
                .font(.caption2)
                .foregroundStyle(skin.resolvedTextSecondary)

            // Existing dependency pills.
            if !dependsOn.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: DS.Spacing.xs) {
                        ForEach(dependsOn, id: \.self) { depId in
                            dependencyPill(depId: depId)
                        }
                    }
                }
            }

            // Picker for adding a new dependency. Hidden when there are no
            // candidates so we don't show a dead dropdown.
            let allCandidates = backlogService.tasks.filter { other in
                other.id != task.id
                    && other.status != .done
                    && other.status != .frozen
                    && !dependsOn.contains(other.id)
            }
            let filtered = BacklogTaskEditRow.filterDependencyCandidates(
                allCandidates,
                query: dependencyQuery
            )
            if !allCandidates.isEmpty {
                HStack(spacing: DS.Spacing.xs) {
                    // Search field appears only when the candidate pool is
                    // long enough that scrolling would become friction.
                    // Small backlogs keep the bare picker — simplicity wins.
                    if allCandidates.count >= Self.dependencySearchThreshold {
                        Image(systemName: "magnifyingglass")
                            .font(.caption2)
                            .foregroundStyle(skin.resolvedTextTertiary)
                        TextField("Filter", text: $dependencyQuery)
                            .textFieldStyle(.plain)
                            .font(.caption2)
                            .frame(maxWidth: Self.contextFieldWidth)
                    }
                    Picker("Add dependency", selection: Binding(
                        get: { newDependencyId },
                        set: { selected in
                            if let selected, !dependsOn.contains(selected) {
                                dependsOn.append(selected)
                                autosave()
                            }
                            // Reset selection + query so the picker returns
                            // to the placeholder row for the next add.
                            newDependencyId = nil
                            dependencyQuery = ""
                        }
                    )) {
                        if filtered.isEmpty {
                            Text("No matches").tag(String?.none)
                        } else {
                            Text("Add dependency\u{2026}").tag(String?.none)
                            ForEach(filtered, id: \.id) { candidate in
                                Text(candidate.title).tag(String?.some(candidate.id))
                            }
                        }
                    }
                    .pickerStyle(.menu)
                    .font(.caption2)
                    .controlSize(.small)
                    .labelsHidden()
                    .disabled(filtered.isEmpty)
                }
            }
        }
    }

    /// Pure filter for the dependency picker. Case-insensitive substring
    /// match over `title` and `context`. Empty query returns the full set
    /// so callers can always round-trip the input unchanged.
    static func filterDependencyCandidates(
        _ candidates: [BacklogTask],
        query: String
    ) -> [BacklogTask] {
        let trimmed = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !trimmed.isEmpty else { return candidates }
        return candidates.filter { task in
            if task.title.lowercased().contains(trimmed) { return true }
            if let ctx = task.context?.lowercased(), ctx.contains(trimmed) { return true }
            return false
        }
    }

    private func dependencyPill(depId: String) -> some View {
        let title = backlogService.tasks.first(where: { $0.id == depId })?.title ?? "Unknown"
        return HStack(spacing: DS.Spacing.xxs) {
            Text(title)
                .font(.caption2)
                .lineLimit(1)
                .foregroundStyle(skin.resolvedTextPrimary)
            Button {
                dependsOn.removeAll { $0 == depId }
                autosave()
            } label: {
                Image(systemName: "xmark")
                    .font(.caption2)
                    .foregroundStyle(skin.resolvedTextTertiary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Remove dependency on \u{201C}\(title)\u{201D}")
        }
        .padding(.horizontal, DS.Spacing.sm)
        .padding(.vertical, DS.Spacing.xxs)
        .background(
            Capsule().fill(skin.accentColor.opacity(DS.Opacity.subtleFill))
        )
    }

    /// Final save + collapse the edit card back to the read-only row.
    private func commit() {
        autosave()
        onDone()
    }

    private func chipButton(label: String, isActive: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                // HIG: Contrast depends on the accent colour's luminance —
                // white fails on pastel accents. Compute it per-skin instead
                // of hard-coding .white like we did before.
                .font(.caption2.weight(.medium))
                .foregroundStyle(isActive ? DS.contrastingForeground(for: skin.accentColor) : skin.resolvedTextPrimary)
                .padding(.horizontal, DS.Spacing.sm)
                .padding(.vertical, DS.Spacing.pillVertical)
                .background(
                    Capsule().fill(isActive ? skin.accentColor : skin.accentColor.opacity(DS.Opacity.lightFill))
                )
        }
        .buttonStyle(.plain)
    }
}
