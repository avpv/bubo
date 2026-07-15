import SwiftUI
import BuboDomain

// MARK: - New Task View

/// Compact creation form modeled on Apple Reminders' "New Reminder" sheet:
/// Title / Notes / URL up top, the three essentials (Date, Urgent,
/// Duration) below, everything else under a single "More options"
/// disclosure. Sits between `QuickCaptureView` (one line, no fields) and
/// `EditTaskView` (every field at once). The intermediate tier is the
/// surface that survives Apple's "feels light" critique without dropping
/// to a one-line capture — Birman: «don't show everything at once, but
/// don't hide what's important behind two clicks either».
///
/// Save creates a fresh `BacklogTask` via `backlogService.addTask`.
/// Cancel is a discard with no autosave; matching `EditTaskView`'s
/// commit model so the «did my change land?» anxiety stays absent.
struct NewTaskView: View {
    /// Pre-typed title carried over from the inline add-task field.
    /// Empty when the form was opened from a header `+` button.
    let prefillTitle: String
    /// Pre-parsed duration from `BacklogTitleParser` when the user wrote
    /// "Write report 30m". nil = no parse hit, fall back to user default.
    let prefillDuration: Int?
    /// User's default task duration — used when neither prefill nor an
    /// in-form chip pick supplies a value.
    let defaultDuration: Int
    var backlogService: BacklogService
    var onDismiss: () -> Void
    var onSave: (BacklogTask) -> Void

    @Environment(\.activeSkin) private var skin
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var title: String
    @State private var notes: String = ""
    @State private var urlString: String = ""
    @State private var hasDeadline: Bool = false
    @State private var deadline: Date = Date()
    @State private var isUrgent: Bool = false
    @State private var durationMinutes: Int
    @State private var priority: TaskPriority = .medium
    @State private var colorTag: EventColorTag? = nil
    @State private var context: String = ""
    @State private var preferredPeriod: Period? = nil
    @State private var subtasks: [Subtask] = []
    @State private var newSubtaskTitle: String = ""
    @State private var tags: [String] = []
    @State private var newTagInput: String = ""
    @State private var showMoreOptions: Bool = false

    @FocusState private var isTitleFocused: Bool

    private static let durationOptions = [15, 30, 45, 60, 90, 120, 180, 240]
    private static let periodOptions: [Period?] = [nil, .morning, .afternoon, .evening]

    init(
        prefillTitle: String = "",
        prefillDuration: Int? = nil,
        defaultDuration: Int = 60,
        backlogService: BacklogService,
        onDismiss: @escaping () -> Void,
        onSave: @escaping (BacklogTask) -> Void
    ) {
        self.prefillTitle = prefillTitle
        self.prefillDuration = prefillDuration
        self.defaultDuration = defaultDuration
        self.backlogService = backlogService
        self.onDismiss = onDismiss
        self.onSave = onSave
        _title = State(initialValue: prefillTitle)
        _durationMinutes = State(initialValue: prefillDuration ?? defaultDuration)
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
                title: "New Task",
                showBack: true,
                onBack: onDismiss
            )

            ScrollView {
                VStack(alignment: .leading, spacing: DS.Spacing.md) {

                    // Title / Notes / URL — Apple groups the three "what is
                    // this thing" fields on a single platter. Notes is a
                    // single-line affordance here (the long form lives in
                    // EditTaskView under More options); enough room for "buy
                    // milk + reminder of why" without the editor's heft.
                    sectionBlock {
                        VStack(alignment: .leading, spacing: DS.Spacing.sm) {
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

                            SkinSeparator()

                            TextField(
                                "Notes",
                                text: $notes,
                                prompt: Text("Notes")
                                    .foregroundStyle(skin.resolvedTextSecondary),
                                axis: .vertical
                            )
                            .textFieldStyle(.plain)
                            .lineLimit(1...4)
                            .font(DS.Typography.body(skin: skin))

                            SkinSeparator()

                            HStack(spacing: DS.Spacing.xs) {
                                Image(systemName: "link")
                                    .font(.footnote)
                                    .foregroundStyle(skin.resolvedTextTertiary)
                                TextField(
                                    "URL",
                                    text: $urlString,
                                    prompt: Text("URL")
                                        .foregroundStyle(skin.resolvedTextSecondary)
                                )
                                .textFieldStyle(.plain)
                                .font(DS.Typography.body(skin: skin))
                            }
                        }
                        .padding(DS.Spacing.md)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    // Date / Urgent / Duration — Apple's three toggles
                    // promoted to the top so the most common decisions live
                    // before "More options". Urgent here is shorthand for
                    // priority=high (Bubo's existing model) instead of
                    // Apple's alarm — same intent, different mechanism.
                    sectionBlock {
                        VStack(alignment: .leading, spacing: DS.Spacing.sm) {
                            HStack {
                                Toggle(isOn: $hasDeadline) {
                                    Label("Date", systemImage: "calendar")
                                        .labelStyle(.titleAndIcon)
                                }
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

                            Toggle(isOn: Binding(
                                get: { isUrgent },
                                set: { newValue in
                                    isUrgent = newValue
                                    // Urgent is a shortcut for "make this
                                    // priority high"; only flip to .high
                                    // when checking the toggle, leave the
                                    // user's explicit pick alone otherwise.
                                    if newValue { priority = .high }
                                    else if priority == .high { priority = .medium }
                                }
                            )) {
                                Label("Urgent", systemImage: "exclamationmark.circle")
                                    .labelStyle(.titleAndIcon)
                            }
                            .toggleStyle(.switch)
                            .controlSize(.small)

                            SkinSeparator()

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
                        }
                        .padding(DS.Spacing.md)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    // More options collapse — color, project, time of day,
                    // subtasks. Hidden by default so the form reads as
                    // "title + three switches" until the user opts in.
                    sectionBlock {
                        Button {
                            withAnimation(skin.resolvedMicroAnimation) {
                                showMoreOptions.toggle()
                            }
                        } label: {
                            HStack(spacing: DS.Spacing.xs) {
                                Text("More options")
                                    .font(.footnote.weight(.regular))
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
                        sectionBlock {
                            VStack(alignment: .leading, spacing: DS.Spacing.md) {
                                VStack(alignment: .leading, spacing: DS.Spacing.xs) {
                                    sectionLabel("Priority")
                                    HStack(spacing: DS.Spacing.xs) {
                                        ForEach(TaskPriority.allCases, id: \.self) { p in
                                            chipButton(label: p.label, isActive: priority == p) {
                                                priority = p
                                                isUrgent = (p == .high)
                                            }
                                        }
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

                                SkinSeparator()

                                VStack(alignment: .leading, spacing: DS.Spacing.xs) {
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

                                SkinSeparator()

                                VStack(alignment: .leading, spacing: DS.Spacing.xs) {
                                    sectionLabel("Project")
                                    TextField(
                                        "Project or category",
                                        text: $context,
                                        prompt: Text("e.g. backend, design, personal")
                                            .foregroundStyle(skin.resolvedTextSecondary)
                                    )
                                    .textFieldStyle(.plain)
                                }
                            }
                            .padding(DS.Spacing.md)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }

                        // Subtasks — same checklist UI as the editor; new
                        // tasks often arrive as projects with a built-in
                        // breakdown ("trip" → packing list), so it earns a
                        // slot in the creation flow too.
                        sectionBlock {
                            subtasksSection
                                .padding(DS.Spacing.md)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }

                        // Tags — same shape as the editor's pill row.
                        sectionBlock {
                            tagsSection
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
                    // Creation primary uses a creation-typed glyph (plus
                    // family). EditTaskView's «Save» keeps `checkmark.circle`
                    // because it's editing existing data — same convention
                    // AddEventView already follows for its create vs edit
                    // toggle, so all three forms speak one icon language.
                    Label("Add", systemImage: "plus.circle")
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

    // MARK: - Subtasks

    @ViewBuilder
    private var subtasksSection: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.sm) {
            HStack(spacing: DS.Spacing.xs) {
                sectionLabel("Subtasks")
                if !subtasks.isEmpty {
                    let progress = (
                        done: subtasks.lazy.filter(\.isDone).count,
                        total: subtasks.count
                    )
                    Text("\(progress.done)/\(progress.total)")
                        .font(.footnote.weight(.regular).monospacedDigit())
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
        }
        // Flat rows, matching `EditTaskView.subtaskRow` (PRINCIPLES §11
        // — rows never get frames): separation comes from row spacing,
        // not a per-row hairline box inside the section platter.
        .padding(.horizontal, DS.Spacing.sm)
        .padding(.vertical, DS.Spacing.xs)
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
        }
        .padding(.horizontal, DS.Spacing.sm)
        .padding(.vertical, DS.Spacing.xxs)
        .background(
            Capsule().fill(skin.accentColor.opacity(DS.Opacity.subtleFill))
        )
    }

    private func commitNewTag() {
        let parts = newTagInput.split(whereSeparator: { $0.isWhitespace })
        for raw in parts {
            guard let normalized = BacklogTask.normalizeTag(String(raw)),
                  !tags.contains(normalized) else { continue }
            tags.append(normalized)
        }
        newTagInput = ""
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

    /// Delegates to the shared `ChipButton` primitive so the form's
    /// duration / priority picker cells carry the same on/off treatment
    /// as every other picker in the app (working days, peak hours, time
    /// slots). The previous hand-rolled capsule used a solid accent fill
    /// no other picker cell had.
    private func chipButton(label: String, isActive: Bool, action: @escaping () -> Void) -> some View {
        ChipButton(
            variant: isActive ? .selected : .unselected,
            title: label,
            action: action
        )
    }

    // MARK: - Save

    private func commitIfValid() {
        guard isTitleValid else { return }
        let trimmedTitle = title.trimmingCharacters(in: .whitespaces)
        let trimmedNotes = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedContext = context.trimmingCharacters(in: .whitespaces)
        let cleanedSubtasks: [Subtask] = subtasks.compactMap { sub in
            let t = sub.title.trimmingCharacters(in: .whitespaces)
            guard !t.isEmpty else { return nil }
            var s = sub
            s.title = t
            return s
        }

        let cleanedTags = tags.compactMap(BacklogTask.normalizeTag)

        let task = BacklogTask(
            title: trimmedTitle,
            durationMinutes: durationMinutes,
            priority: priority,
            deadline: hasDeadline ? deadline : nil,
            context: trimmedContext.isEmpty ? nil : trimmedContext,
            colorTag: colorTag,
            preferredPeriod: preferredPeriod,
            notes: trimmedNotes.isEmpty ? nil : trimmedNotes,
            url: EditTaskView.parseURL(urlString),
            subtasks: cleanedSubtasks,
            tags: cleanedTags
        )

        backlogService.addTask(task)
        Haptics.impact()
        onSave(task)
    }
}
