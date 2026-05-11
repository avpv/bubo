import SwiftUI

// MARK: - Edit Task View

/// Full-screen task editor that lives inside the popover navigation stack
/// — same pattern as `AddEventView`.
///
/// Design:
/// - One coherent flow, not a popup. Back chevron returns to the timeline,
///   so the user always knows where they are.
/// - Same chrome and rhythm as event editing: `PopoverHeader` on top,
///   sectionBlock platters in the body, Save/Cancel footer at the bottom.
/// - Explicit Save instead of autosave-on-keystroke: matches the event
///   editor's mental model.
/// - One section per concept. Title alone, schedule together, content
///   together, options collapsed by default.
/// - Empty optional fields stay empty — no placeholder pillage, no
///   "Show more" with nothing inside.
struct EditTaskView: View {
    let task: BacklogTask
    var backlogService: BacklogService
    var onDismiss: () -> Void
    var onSave: () -> Void

    @Environment(\.activeSkin) private var skin
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var title: String
    @State private var durationMinutes: Int
    @State private var priority: TaskPriority
    @State private var hasDeadline: Bool
    @State private var deadline: Date
    @State private var context: String
    @State private var colorTag: EventColorTag?
    @State private var storyPoints: Int?
    @State private var preferredPeriod: Period?
    @State private var isRecurring: Bool
    @State private var recurrenceTag: String
    @State private var notes: String
    @State private var urlString: String
    @State private var location: String
    @State private var subtasks: [Subtask]
    @State private var newSubtaskTitle: String = ""
    @State private var tags: [String]
    @State private var newTagInput: String = ""
    @State private var dependsOn: [String]
    @State private var newDependencyId: String? = nil
    @State private var dependencyQuery: String = ""
    @State private var showMoreOptions: Bool = false

    @FocusState private var isTitleFocused: Bool

    private static let durationOptions = [15, 30, 45, 60, 90, 120, 180, 240]
    private static let spOptions: [Int?] = [nil, 1, 2, 3, 5, 8, 13]
    private static let periodOptions: [Period?] = [nil, .morning, .afternoon, .evening]
    private static let dependencySearchThreshold: Int = 8

    /// Lenient URL parser used by the link field's "Open" button and by
    /// the save path. Accepts bare domains ("example.com/foo") by
    /// synthesizing `https://` when a scheme is missing, so users don't
    /// have to type boilerplate.
    static func parseURL(_ raw: String) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        if let url = URL(string: trimmed), url.scheme != nil { return url }
        return URL(string: "https://\(trimmed)")
    }

    /// Pure filter for the dependency picker. Case-insensitive substring
    /// match over `title` and `context`. Empty query returns the full set.
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

    init(
        task: BacklogTask,
        backlogService: BacklogService,
        onDismiss: @escaping () -> Void,
        onSave: @escaping () -> Void
    ) {
        self.task = task
        self.backlogService = backlogService
        self.onDismiss = onDismiss
        self.onSave = onSave
        _title = State(initialValue: task.title)
        _durationMinutes = State(initialValue: task.durationMinutes)
        _priority = State(initialValue: task.priority)
        _hasDeadline = State(initialValue: task.deadline != nil)
        _deadline = State(initialValue: task.deadline ?? Date())
        _context = State(initialValue: task.context ?? "")
        _colorTag = State(initialValue: task.colorTag)
        _storyPoints = State(initialValue: task.storyPoints)
        _preferredPeriod = State(initialValue: task.preferredPeriod)
        _isRecurring = State(initialValue: task.isRecurring)
        _recurrenceTag = State(initialValue: task.recurrenceTag ?? "")
        _notes = State(initialValue: task.notes ?? "")
        _urlString = State(initialValue: task.url?.absoluteString ?? "")
        _location = State(initialValue: task.location ?? "")
        _subtasks = State(initialValue: task.subtasks)
        _tags = State(initialValue: task.tags)
        _dependsOn = State(initialValue: task.dependsOn)
        // Open "More options" if the task already has values stored there,
        // so editing them doesn't require a second click to find them.
        let hasMoreState = !(task.notes ?? "").isEmpty
            || task.url != nil
            || !(task.location ?? "").isEmpty
            || !task.subtasks.isEmpty
            || !task.tags.isEmpty
            || !task.dependsOn.isEmpty
            || task.isRecurring
        _showMoreOptions = State(initialValue: hasMoreState)
    }

    private var skinAccent: Color {
        skin.isClassic ? DS.Colors.accent : skin.accentColor
    }

    private var isTitleValid: Bool {
        !title.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            PopoverHeader(
                title: "Edit Task",
                showBack: true,
                onBack: onDismiss
            )

            ScrollView {
                VStack(alignment: .leading, spacing: DS.Spacing.md) {

                    // Title — alone on its platter, the way the event editor
                    // treats it. The task IS its title; everything else is
                    // metadata about it.
                    sectionBlock {
                        TextField(
                            "Title",
                            text: $title,
                            prompt: Text("What needs to be done?")
                                .foregroundStyle(skin.resolvedTextSecondary)
                        )
                        .textFieldStyle(.plain)
                        .font(DS.Typography.headline(skin: skin))
                        .focused($isTitleFocused)
                        .defaultFocus($isTitleFocused, true)
                        .onSubmit { commitIfValid() }
                        .padding(DS.Spacing.md)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    // Effort — duration and story points live together because
                    // they answer the same question: "how big is this?"
                    sectionBlock {
                        VStack(alignment: .leading, spacing: DS.Spacing.md) {
                            VStack(alignment: .leading, spacing: DS.Spacing.xs) {
                                sectionLabel("Duration")
                                ScrollView(.horizontal, showsIndicators: false) {
                                    HStack(spacing: DS.Spacing.xs) {
                                        ForEach(Self.durationOptions, id: \.self) { mins in
                                            chipButton(
                                                label: DS.formatMinutes(mins),
                                                isActive: durationMinutes == mins
                                            ) {
                                                durationMinutes = mins
                                            }
                                        }
                                    }
                                }
                            }

                            VStack(alignment: .leading, spacing: DS.Spacing.xs) {
                                sectionLabel("Story points")
                                HStack(spacing: DS.Spacing.xs) {
                                    ForEach(Self.spOptions, id: \.self) { sp in
                                        chipButton(
                                            label: sp.map { "\($0)" } ?? "\u{2014}",
                                            isActive: storyPoints == sp
                                        ) {
                                            storyPoints = sp
                                        }
                                    }
                                }
                            }
                        }
                        .padding(DS.Spacing.md)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    // Schedule — priority, deadline, and preferred period
                    // share the "when does this happen / how urgent" frame.
                    sectionBlock {
                        VStack(alignment: .leading, spacing: DS.Spacing.md) {
                            VStack(alignment: .leading, spacing: DS.Spacing.xs) {
                                sectionLabel("Priority")
                                HStack(spacing: DS.Spacing.xs) {
                                    ForEach(TaskPriority.allCases, id: \.self) { p in
                                        chipButton(label: p.label, isActive: priority == p) {
                                            priority = p
                                        }
                                    }
                                }
                            }

                            SkinSeparator()

                            HStack {
                                Toggle("Has deadline", isOn: $hasDeadline)
                                    .toggleStyle(.switch)
                                    .controlSize(.small)
                                Spacer()
                                if hasDeadline {
                                    DatePicker(
                                        "",
                                        selection: $deadline,
                                        displayedComponents: .date
                                    )
                                    .labelsHidden()
                                    .controlSize(.small)
                                }
                            }

                            SkinSeparator()

                            VStack(alignment: .leading, spacing: DS.Spacing.xs) {
                                sectionLabel("Time of day")
                                HStack(spacing: DS.Spacing.xs) {
                                    ForEach(Self.periodOptions, id: \.self) { period in
                                        chipButton(
                                            label: period?.displayLabel ?? "Any",
                                            isActive: preferredPeriod == period
                                        ) {
                                            preferredPeriod = period
                                        }
                                    }
                                }
                            }
                        }
                        .padding(DS.Spacing.md)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    // Color — same vocabulary as the event editor so a
                    // user can color-code tasks (incl. those synced from
                    // Apple Reminders) the way they color-code events.
                    sectionBlock {
                        VStack(alignment: .leading, spacing: DS.Spacing.sm) {
                            sectionLabel("Color")

                            HStack(spacing: DS.Spacing.xs) {
                                ForEach(EventColorTag.allCases, id: \.self) { tag in
                                    ColorDotButton(
                                        tag: tag,
                                        isActive: colorTag == tag,
                                        action: {
                                            Haptics.tap()
                                            colorTag = colorTag == tag ? nil : tag
                                        }
                                    )
                                }
                            }
                        }
                        .padding(DS.Spacing.md)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    // Project / context.
                    sectionBlock {
                        VStack(alignment: .leading, spacing: DS.Spacing.sm) {
                            sectionLabel("Project")
                            TextField(
                                "Project or category",
                                text: $context,
                                prompt: Text("e.g. backend, design, personal")
                                    .foregroundStyle(skin.resolvedTextSecondary)
                            )
                            .textFieldStyle(.plain)
                        }
                        .padding(DS.Spacing.md)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    // More options — collapsed by default for a clean read.
                    sectionBlock {
                        Button {
                            withAnimation(skin.resolvedMicroAnimation) {
                                showMoreOptions.toggle()
                            }
                        } label: {
                            HStack(spacing: DS.Spacing.xs) {
                                Text("More options")
                                    .font(.footnote.weight(.medium))
                                    .foregroundStyle(skinAccent)
                                Image(systemName: showMoreOptions ? "chevron.up" : "chevron.down")
                                    .font(.footnote)
                                    .foregroundStyle(skinAccent)
                                Spacer()
                            }
                        }
                        .buttonStyle(.plain)
                        .padding(DS.Spacing.md)
                    }

                    if showMoreOptions {
                        // Notes + link + location — all "details about the
                        // work itself" live together with separators inside
                        // a single platter, matching the event editor's
                        // Details card.
                        sectionBlock {
                            VStack(alignment: .leading, spacing: DS.Spacing.sm) {
                                sectionLabel("Details")

                                TextField(
                                    "Location",
                                    text: $location,
                                    prompt: Text("Room, address, or \"Remote\"")
                                        .foregroundStyle(skin.resolvedTextSecondary)
                                )
                                .textFieldStyle(.plain)

                                SkinSeparator()

                                HStack(spacing: DS.Spacing.xs) {
                                    Image(systemName: "link")
                                        .font(.footnote)
                                        .foregroundStyle(skin.resolvedTextTertiary)
                                    TextField(
                                        "Link",
                                        text: $urlString,
                                        prompt: Text("https://\u{2026}")
                                            .foregroundStyle(skin.resolvedTextSecondary)
                                    )
                                    .textFieldStyle(.plain)
                                    if let url = Self.parseURL(urlString) {
                                        Button {
                                            NSWorkspace.shared.open(url)
                                        } label: {
                                            Image(systemName: "arrow.up.right.square")
                                                .font(.footnote)
                                                .foregroundStyle(skin.accentColor)
                                        }
                                        .buttonStyle(.plain)
                                        .accessibilityLabel("Open link")
                                    }
                                }

                                SkinSeparator()

                                TextEditor(text: $notes)
                                    .font(DS.Typography.body(skin: skin))
                                    .scrollContentBackground(.hidden)
                                    .frame(minHeight: 60, maxHeight: 160)
                                    .padding(DS.Spacing.xs)
                                    .background(
                                        RoundedRectangle(cornerRadius: DS.Size.subtleCornerRadius, style: .continuous)
                                            .fill(skin.resolvedTextTertiary.opacity(DS.Opacity.subtleFill))
                                    )
                                    .overlay(alignment: .topLeading) {
                                        if notes.isEmpty {
                                            Text("Add notes, agenda, links\u{2026}")
                                                .font(DS.Typography.body(skin: skin))
                                                .foregroundStyle(skin.resolvedTextSecondary)
                                                .padding(.horizontal, DS.Spacing.sm)
                                                .padding(.vertical, DS.Spacing.sm)
                                                .allowsHitTesting(false)
                                        }
                                    }
                            }
                            .padding(DS.Spacing.md)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }

                        // Subtasks — Apple-style nested checklist. Lives inside
                        // the parent task (not a separate `BacklogTask`) so it
                        // doesn't pollute the optimizer queue with a hundred
                        // tiny rows.
                        sectionBlock {
                            subtasksSection
                                .padding(DS.Spacing.md)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }

                        // Tags — many-per-task free-form text labels.
                        // Distinct from `colorTag` (a categorical hue) and
                        // `context` (the single project label). Stored
                        // lowercased without the "#" prefix; the `#` is a
                        // typography choice in display, not data.
                        sectionBlock {
                            tagsSection
                                .padding(DS.Spacing.md)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }

                        // Recurrence — toggle plus a free-form tag that
                        // becomes the human label («weekly review») on the
                        // backlog row.
                        sectionBlock {
                            VStack(alignment: .leading, spacing: DS.Spacing.sm) {
                                Toggle(isOn: $isRecurring) {
                                    HStack(spacing: DS.Spacing.sm) {
                                        Image(systemName: "arrow.triangle.2.circlepath")
                                            .font(DS.Typography.body(skin: skin))
                                            .foregroundStyle(isRecurring ? skinAccent : skin.resolvedTextSecondary)
                                            .frame(width: DS.Size.iconLarge)
                                        VStack(alignment: .leading, spacing: DS.Spacing.xxs) {
                                            Text("Repeats")
                                                .font(DS.Typography.body(skin: skin))
                                                .foregroundStyle(skin.resolvedTextPrimary)
                                            Text("Reset to pending instead of done on completion")
                                                .font(.footnote)
                                                .foregroundStyle(skin.resolvedTextTertiary)
                                        }
                                    }
                                }
                                .toggleStyle(.switch)
                                .controlSize(.small)

                                if isRecurring {
                                    TextField(
                                        "Label",
                                        text: $recurrenceTag,
                                        prompt: Text("e.g. weekly review, daily standup")
                                            .foregroundStyle(skin.resolvedTextSecondary)
                                    )
                                    .textFieldStyle(.plain)
                                    .font(DS.Typography.body(skin: skin))
                                    .padding(.leading, DS.Spacing.lg + DS.Spacing.xs)
                                    .transition(.opacity.combined(with: .move(edge: .top)))
                                }
                            }
                            .padding(DS.Spacing.md)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .motionAwareAnimation(DS.Animation.quick, value: isRecurring, reduceMotion: reduceMotion)
                        }

                        // Dependencies.
                        sectionBlock {
                            dependencySection
                                .padding(DS.Spacing.md)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                .padding(.horizontal, DS.Spacing.lg)
                .padding(.vertical, DS.Spacing.lg)
            }
            .scrollContentBackground(.hidden)
            .frame(maxHeight: .infinity)

            SkinSeparator()

            HStack {
                Spacer()
                Button(action: onDismiss) {
                    Text("Cancel")
                }
                .keyboardShortcut(.cancelAction)
                .buttonStyle(.action(role: .secondary))

                Button(action: { commitIfValid() }) {
                    Label("Save", systemImage: "checkmark.circle")
                }
                .buttonStyle(.action(role: .primary))
                .keyboardShortcut(.defaultAction)
                .disabled(!isTitleValid)
            }
            .padding(.horizontal, DS.Spacing.lg)
            .frame(height: DS.Size.actionFooterHeight)
            .skinBarBackground(skin)
        }
        .frame(width: DS.Popover.width, height: DS.Popover.height)
        .onAppear {
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(100))
                isTitleFocused = true
            }
        }
    }

    // MARK: - Section helpers

    private func sectionLabel(_ text: String) -> some View {
        SectionLabel(text: text)
    }

    @ViewBuilder
    private func sectionBlock<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .skinPlatter(skin)
            .skinPlatterDepth(skin)
    }

    private func chipButton(label: String, isActive: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.footnote.weight(.medium))
                .foregroundStyle(isActive ? DS.contrastingForeground(for: skin.accentColor) : skin.resolvedTextPrimary)
                .padding(.horizontal, DS.Spacing.sm)
                .padding(.vertical, DS.Spacing.pillVertical)
                .background(
                    Capsule().fill(isActive ? skin.accentColor : skin.accentColor.opacity(DS.Opacity.lightFill))
                )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Subtasks

    @ViewBuilder
    private var subtasksSection: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.sm) {
            HStack(spacing: DS.Spacing.xs) {
                sectionLabel("Subtasks")
                if !subtasks.isEmpty {
                    let progress = (done: subtasks.lazy.filter(\.isDone).count, total: subtasks.count)
                    Text("\(progress.done)/\(progress.total)")
                        .font(.footnote.weight(.medium).monospacedDigit())
                        .foregroundStyle(skin.resolvedTextTertiary)
                }
                Spacer()
            }

            if !subtasks.isEmpty {
                VStack(spacing: DS.Spacing.xs) {
                    ForEach(subtasks) { sub in
                        subtaskRow(sub)
                    }
                }
            }

            HStack(spacing: DS.Spacing.sm) {
                Image(systemName: "plus.circle")
                    .font(.footnote)
                    .foregroundStyle(skin.resolvedTextTertiary)
                TextField(
                    "Add subtask",
                    text: $newSubtaskTitle,
                    prompt: Text("Add subtask\u{2026}")
                        .foregroundStyle(skin.resolvedTextSecondary)
                )
                .textFieldStyle(.plain)
                .font(DS.Typography.body(skin: skin))
                .onSubmit { commitNewSubtask() }
            }
        }
    }

    private func subtaskRow(_ sub: Subtask) -> some View {
        HStack(spacing: DS.Spacing.sm) {
            Button {
                Haptics.tap()
                if let idx = subtasks.firstIndex(where: { $0.id == sub.id }) {
                    subtasks[idx].isDone.toggle()
                }
            } label: {
                Image(systemName: sub.isDone ? "checkmark.circle.fill" : "circle")
                    .font(DS.Typography.body(skin: skin))
                    .foregroundStyle(sub.isDone ? skinAccent : skin.resolvedTextTertiary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(sub.isDone ? "Mark \"\(sub.title)\" not done" : "Mark \"\(sub.title)\" done")

            TextField(
                "Subtask",
                text: Binding(
                    get: { sub.title },
                    set: { newValue in
                        if let idx = subtasks.firstIndex(where: { $0.id == sub.id }) {
                            subtasks[idx].title = newValue
                        }
                    }
                )
            )
            .textFieldStyle(.plain)
            .font(DS.Typography.body(skin: skin))
            .strikethrough(sub.isDone, color: skin.resolvedTextTertiary)
            .foregroundStyle(sub.isDone ? skin.resolvedTextTertiary : skin.resolvedTextPrimary)

            Button {
                subtasks.removeAll { $0.id == sub.id }
            } label: {
                Image(systemName: "xmark")
                    .font(.footnote)
                    .foregroundStyle(skin.resolvedTextTertiary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Remove subtask \"\(sub.title)\"")
        }
    }

    private func commitNewSubtask() {
        let trimmed = newSubtaskTitle.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        subtasks.append(Subtask(title: trimmed))
        newSubtaskTitle = ""
    }

    // MARK: - Tags

    @ViewBuilder
    private var tagsSection: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.sm) {
            sectionLabel("Tags")

            if !tags.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: DS.Spacing.xs) {
                        ForEach(tags, id: \.self) { tag in
                            tagPill(tag)
                        }
                    }
                }
            }

            HStack(spacing: DS.Spacing.sm) {
                Image(systemName: "number")
                    .font(.footnote)
                    .foregroundStyle(skin.resolvedTextTertiary)
                TextField(
                    "Add tag",
                    text: $newTagInput,
                    prompt: Text("Add tag\u{2026} (press Return)")
                        .foregroundStyle(skin.resolvedTextSecondary)
                )
                .textFieldStyle(.plain)
                .font(DS.Typography.body(skin: skin))
                .onSubmit { commitNewTag() }
            }
        }
    }

    private func tagPill(_ tag: String) -> some View {
        HStack(spacing: DS.Spacing.xxs) {
            Text("#\(tag)")
                .font(.footnote)
                .lineLimit(1)
                .foregroundStyle(skin.resolvedTextPrimary)
            Button {
                tags.removeAll { $0 == tag }
            } label: {
                Image(systemName: "xmark")
                    .font(.footnote)
                    .foregroundStyle(skin.resolvedTextTertiary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Remove tag #\(tag)")
        }
        .padding(.horizontal, DS.Spacing.sm)
        .padding(.vertical, DS.Spacing.xxs)
        .background(
            Capsule().fill(skin.accentColor.opacity(DS.Opacity.subtleFill))
        )
    }

    private func commitNewTag() {
        // Accept space-separated batches: "#design urgent backend" → 3
        // tags in one keystroke. Mirrors Apple Reminders' title parser
        // even though we keep tags out of the title.
        let parts = newTagInput.split(whereSeparator: { $0.isWhitespace })
        for raw in parts {
            guard let normalized = BacklogTask.normalizeTag(String(raw)),
                  !tags.contains(normalized) else { continue }
            tags.append(normalized)
        }
        newTagInput = ""
    }

    // MARK: - Dependencies

    @ViewBuilder
    private var dependencySection: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.sm) {
            sectionLabel("Depends on")

            if !dependsOn.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: DS.Spacing.xs) {
                        ForEach(dependsOn, id: \.self) { depId in
                            dependencyPill(depId: depId)
                        }
                    }
                }
            }

            let allCandidates = backlogService.tasks.filter { other in
                other.id != task.id
                    && other.status != .done
                    && other.status != .frozen
                    && !dependsOn.contains(other.id)
            }
            let filtered = Self.filterDependencyCandidates(
                allCandidates,
                query: dependencyQuery
            )
            if !allCandidates.isEmpty {
                HStack(spacing: DS.Spacing.xs) {
                    if allCandidates.count >= Self.dependencySearchThreshold {
                        Image(systemName: "magnifyingglass")
                            .font(.footnote)
                            .foregroundStyle(skin.resolvedTextTertiary)
                        TextField("Filter", text: $dependencyQuery)
                            .textFieldStyle(.plain)
                            .font(.footnote)
                            .frame(maxWidth: 140)
                    }
                    Picker("Add dependency", selection: Binding(
                        get: { newDependencyId },
                        set: { selected in
                            if let selected, !dependsOn.contains(selected) {
                                dependsOn.append(selected)
                            }
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
                    .controlSize(.small)
                    .labelsHidden()
                    .disabled(filtered.isEmpty)
                }
            } else if dependsOn.isEmpty {
                Text("No other active tasks to depend on.")
                    .font(.footnote)
                    .foregroundStyle(skin.resolvedTextSecondary)
            }
        }
    }

    private func dependencyPill(depId: String) -> some View {
        let depTitle = backlogService.tasks.first(where: { $0.id == depId })?.title ?? "Unknown"
        return HStack(spacing: DS.Spacing.xxs) {
            Text(depTitle)
                .font(.footnote)
                .lineLimit(1)
                .foregroundStyle(skin.resolvedTextPrimary)
            Button {
                dependsOn.removeAll { $0 == depId }
            } label: {
                Image(systemName: "xmark")
                    .font(.footnote)
                    .foregroundStyle(skin.resolvedTextTertiary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Remove dependency on \u{201C}\(depTitle)\u{201D}")
        }
        .padding(.horizontal, DS.Spacing.sm)
        .padding(.vertical, DS.Spacing.xxs)
        .background(
            Capsule().fill(skin.accentColor.opacity(DS.Opacity.subtleFill))
        )
    }

    // MARK: - Save

    private func commitIfValid() {
        guard isTitleValid else { return }
        var updated = task
        updated.title = title.trimmingCharacters(in: .whitespaces)
        updated.durationMinutes = durationMinutes
        updated.priority = priority
        updated.deadline = hasDeadline ? deadline : nil
        let trimmedContext = context.trimmingCharacters(in: .whitespaces)
        updated.context = trimmedContext.isEmpty ? nil : trimmedContext
        updated.colorTag = colorTag
        updated.storyPoints = storyPoints
        updated.preferredPeriod = preferredPeriod
        updated.isRecurring = isRecurring
        let trimmedTag = recurrenceTag.trimmingCharacters(in: .whitespaces)
        updated.recurrenceTag = (isRecurring && !trimmedTag.isEmpty) ? trimmedTag : nil
        let trimmedNotes = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        updated.notes = trimmedNotes.isEmpty ? nil : trimmedNotes
        updated.url = Self.parseURL(urlString)
        let trimmedLocation = location.trimmingCharacters(in: .whitespaces)
        updated.location = trimmedLocation.isEmpty ? nil : trimmedLocation
        // Drop subtasks whose title was emptied by inline editing — keeping
        // them would round-trip a `- [ ]` line with no content through the
        // Apple Reminders codec, which the parser skips anyway.
        updated.subtasks = subtasks.compactMap { sub in
            let trimmed = sub.title.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { return nil }
            var s = sub
            s.title = trimmed
            return s
        }
        // Re-normalise on save so any half-typed input that slipped past
        // the inline `commitNewTag` (focus-stolen submit, paste of mixed
        // case) lands in the canonical lowercase form.
        updated.tags = tags.compactMap(BacklogTask.normalizeTag)
        updated.dependsOn = dependsOn

        backlogService.updateTask(updated)
        Haptics.impact()
        onSave()
    }
}
