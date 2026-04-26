import SwiftUI

// MARK: - Sprint View

/// Full-screen Tasks view that lives inside the popover navigation stack.
/// Reachable via the fullscreen-affordance button in `BacklogView`'s header.
///
/// Replaces both the old in-place "isSprintMode" modifier on `BacklogView` and
/// `BacklogView`'s third-state «.expanded» chevron click — раньше у нас были
/// две дороги к одному состоянию «много задач, без таймлайна», теперь одна.
///
/// Design (Birman):
/// - One thing on screen at a time. Sprint is "what's next" — everything
///   that isn't a task is gone, including the brand chrome.
/// - Two modes inside the same surface: `Sprint` (top-N by smart-score, calmer
///   row style) и `All` (полный активный список в пользовательском порядке —
///   именно то, что раньше делал `.expanded` BacklogView'а). Переключатель —
///   сегментированная пилюля под header'ом.
/// - The list itself stays inline-editable: complete with a tap, edit by
///   pushing the same `EditTaskView` the backlog uses, undo via toast.
/// - Inline `+ Add task…` поле снизу — раньше пустое состояние SprintView
///   было тупиком, заставляло возвращаться в backlog ради добавления.
/// - Completed-today / frozen tombstones — те же квартиранты, что и в
///   backlog'е, чтобы история сегодняшнего дня не терялась при переключении.
struct SprintView: View {
    var backlogService: BacklogService
    var optimizerService: OptimizerService
    var onExit: () -> Void
    var onEditTask: (BacklogTask) -> Void
    var onUndoableAction: ((_ message: String, _ undo: @escaping () -> Void) -> Void)? = nil

    @Environment(\.activeSkin) private var skin
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Hard cap on rows visible in `.sprint` mode. Small on purpose: «sprint»
    /// — это «что прямо сейчас», а не весь список. Для всего списка есть
    /// `.all`. Cap намеренно оставлен константой; делать его настройкой —
    /// отдельная история, которая не должна тормозить рефакторинг view.
    static let maxSprintTasks = 5

    enum Mode: String, Hashable, CaseIterable {
        case sprint
        case all

        var label: String {
            switch self {
            case .sprint: return "Sprint"
            case .all:    return "All"
            }
        }
    }

    /// Текущий режим. Пилюля переключает между «top-5» и «full active list».
    /// Sprint — дефолт: пользователь сюда заходит ради фокуса, а не ради
    /// просмотра всех задач разом (для этого есть BacklogView'овский chevron).
    @State private var mode: Mode = .sprint

    @State private var newTaskTitle = ""
    /// Cached parse result for `newTaskTitle`. Updated from `onChange` so
    /// the title/duration pair is computed once per keystroke.
    @State private var parsedNewTaskTitle: (cleaned: String, durationMinutes: Int?) = ("", nil)
    @FocusState private var isInputFocused: Bool

    @State private var showCompletedToday: Bool = false
    @State private var showFrozen: Bool = false
    /// Urgent-only filter — narrows `.all` mode to tasks whose deadline falls
    /// inside the urgency window. Hidden in Sprint mode (top-N smart-sort
    /// already prioritises urgent), session-local. Mirrors BacklogView's
    /// `urgentOnlyFilter` so users carry the same mental model across views.
    @State private var urgentOnlyFilter: Bool = false
    /// Smart-sort toggle — re-orders `.all` mode by `BacklogLogic.smartScore`
    /// instead of user drag order. Sprint mode is always smart-sorted; this
    /// toggle is only meaningful in `.all`. Session-local.
    @State private var useSmartSort: Bool = false

    /// Все активные задачи (без urgent-фильтров и пр.) — общая основа для
    /// обоих режимов и для расчёта capacity ring (тот должен показывать
    /// общий груз очереди, не отфильтрованный подсет).
    private var activeTasks: [BacklogTask] {
        BacklogLogic.activeTasks(backlogService.tasks)
    }

    /// Active set after the urgent-only filter. Применяется только в `.all`
    /// — Sprint игнорирует фильтр осознанно (top-5 smart-sort уже выводит
    /// urgent наверх, накладывать ещё один фильтр поверх — масло на масло).
    private var allActiveFiltered: [BacklogTask] {
        guard urgentOnlyFilter else { return activeTasks }
        return activeTasks.filter { BacklogLogic.isUrgent($0) }
    }

    /// Tasks visible in the current mode. Sprint всегда smart-sort + cap;
    /// All — пользовательский порядок (или smart-sort, если toggle включён),
    /// плюс urgent-only фильтр.
    private var visibleTasks: [BacklogTask] {
        switch mode {
        case .sprint:
            let sorted = BacklogLogic.smartSorted(activeTasks)
            return BacklogLogic.sprintCapped(sorted, max: Self.maxSprintTasks)
        case .all:
            let base = allActiveFiltered
            return useSmartSort ? BacklogLogic.smartSorted(base) : base
        }
    }

    /// Total scheduled minutes across the visible set — surfaces «how big is
    /// this session?» (sprint) or «how big is the whole queue?» (all).
    private var totalMinutes: Int {
        visibleTasks.reduce(0) { $0 + $1.durationMinutes }
    }

    /// Tasks completed since local midnight. Same data source as BacklogView's
    /// tombstone — keeps «сделано сегодня» доступным внутри fullscreen-режима.
    private var completedToday: [BacklogTask] {
        BacklogLogic.completedToday(backlogService.tasks)
    }

    /// Number of urgent tasks in the active set — drives both the urgent
    /// filter pill (visibility + label) and the auto-disengage rule when
    /// the set dries up.
    private var urgentCount: Int {
        backlogService.urgent(withinDays: 2).count
    }

    /// Total scheduled minutes across the entire active queue — workload
    /// the user would still need to fit. Used by the capacity ring; intentional
    /// difference from `totalMinutes` (which sums only the visible set).
    private var pendingWorkloadMinutes: Int {
        activeTasks.reduce(0) { $0 + $1.durationMinutes }
    }

    /// Remaining minutes between now and the end of the working day.
    private var remainingWorkdayMinutes: Int {
        BacklogLogic.remainingWorkdayMinutes(
            workingHours: optimizerService.workingHours,
            workingDays: optimizerService.workingDays
        )
    }

    private var capacityRingTooltip: String {
        "Backlog: \(DS.formatMinutes(pendingWorkloadMinutes)); remaining today: \(DS.formatMinutes(remainingWorkdayMinutes))"
    }

    /// Should the segmented mode picker render? Если задач ≤ sprint cap, оба
    /// режима покажут одно и то же. Но если пользователь уже выбрал `.all`,
    /// пилюлю прятать нельзя — иначе он окажется в режиме без переключателя
    /// обратно. Бирман: «контрол без выбора — украшение, но и контрол
    /// без выхода — ловушка».
    private var showsModePicker: Bool {
        guard !activeTasks.isEmpty else { return false }
        return activeTasks.count > Self.maxSprintTasks || mode == .all
    }

    /// True iff a controls row needs to render (mode picker, urgent filter
    /// pill, smart-sort toggle). Hides the row entirely on small/clean
    /// states so the empty surface stays calm.
    private var showsControlsRow: Bool {
        showsModePicker || (mode == .all && (urgentCount > 0 || activeTasks.count > 1))
    }

    var body: some View {
        VStack(spacing: 0) {
            PopoverHeader(
                title: "Sprint",
                showBack: true,
                backLabel: "Exit",
                onBack: onExit,
                trailing: AnyView(headerTrailing)
            )

            if showsControlsRow {
                controlsRow
                    .padding(.horizontal, DS.Spacing.lg)
                    .padding(.top, DS.Spacing.sm)
            }

            mainContent

            addTaskField
        }
        .frame(width: DS.Popover.width, height: DS.Popover.height)
        .onChange(of: newTaskTitle) { _, newValue in
            parsedNewTaskTitle = BacklogTitleParser.parse(newValue)
        }
        .onChange(of: activeTasks.count) { _, _ in
            // Auto-disengage urgent filter if the urgent set dries up — same
            // safety net as in BacklogView, prevents stranding the user in
            // an empty filtered view.
            if urgentOnlyFilter, allActiveFiltered.isEmpty {
                urgentOnlyFilter = false
            }
        }
        .onChange(of: urgentCount) { _, newValue in
            // Same safety net for the case where active count is unchanged
            // but the last urgent task lost its urgency (deadline edited
            // farther out) — onChange of `activeTasks.count` wouldn't fire.
            if urgentOnlyFilter, newValue == 0 {
                urgentOnlyFilter = false
            }
        }
    }

    // MARK: - Header trailing

    /// Header trailing: capacity ring (общая нагрузка очереди) + count·time
    /// текущего видимого набора. Кольцо отвечает на «влезет ли весь backlog
    /// сегодня?», count·time — «сколько всего в текущем экране?». Два разных
    /// вопроса, рядом, без коллизий — Бирман: «информация, не украшения».
    @ViewBuilder
    private var headerTrailing: some View {
        HStack(spacing: DS.Spacing.xs) {
            if !activeTasks.isEmpty {
                BacklogCapacityRing(
                    pendingMinutes: pendingWorkloadMinutes,
                    remainingWorkdayMinutes: remainingWorkdayMinutes,
                    optimizerService: optimizerService
                )
                .help(capacityRingTooltip)
            }

            if !visibleTasks.isEmpty {
                HStack(spacing: DS.Spacing.xxs) {
                    Text("\(visibleTasks.count)")
                        .font(.subheadline.weight(.medium).monospacedDigit())
                        .foregroundStyle(skin.resolvedTextPrimary)
                        .contentTransition(.numericText())
                    Text("·")
                        .font(.caption2)
                        .foregroundStyle(skin.resolvedTextTertiary)
                    Text(DS.formatMinutes(totalMinutes))
                        .font(.subheadline.weight(.regular).monospacedDigit())
                        .foregroundStyle(skin.resolvedTextSecondary)
                        .contentTransition(.numericText())
                }
            }
        }
    }

    // MARK: - Controls row

    /// Row под header'ом: переключатель Sprint/All слева, фильтры/тоглы
    /// справа. Фильтры показываются только в `.all` — Sprint мы держим
    /// чистым (top-N smart-sort + спокойные строки), там не место
    /// дополнительным контролам.
    @ViewBuilder
    private var controlsRow: some View {
        HStack(spacing: DS.Spacing.sm) {
            if showsModePicker {
                modePicker
                    .layoutPriority(0)
            }

            Spacer(minLength: 0)

            if mode == .all {
                if urgentCount > 0 {
                    urgentFilterButton
                }
                if activeTasks.count > 1 {
                    smartSortButton
                }
            }
        }
    }

    /// Red «N urgent» pill — toggles the urgent-only filter. Filled
    /// background while engaged so the user can see the filter is active;
    /// hidden in Sprint mode (uncluttered focus surface) and когда нет
    /// urgent-задач (контрол без эффекта — украшение).
    private var urgentFilterButton: some View {
        Button {
            withAnimation(DS.Animation.motionAware(DS.Animation.quick, reduceMotion: reduceMotion)) {
                urgentOnlyFilter.toggle()
            }
        } label: {
            Text("\(urgentCount) urgent")
                .font(.caption2.weight(.semibold).monospacedDigit())
                .foregroundStyle(skin.resolvedDestructiveColor)
                .contentTransition(.numericText())
                .padding(.horizontal, DS.Spacing.xs)
                .padding(.vertical, DS.Spacing.xxs)
                .background(
                    Capsule().fill(
                        skin.resolvedDestructiveColor
                            .opacity(urgentOnlyFilter ? DS.Opacity.lightFill : 0)
                    )
                )
                .overlay(
                    Capsule().strokeBorder(
                        skin.resolvedDestructiveColor.opacity(urgentOnlyFilter ? DS.Opacity.softAccent : 0),
                        lineWidth: DS.Border.thin
                    )
                )
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(urgentOnlyFilter ? "Show all tasks" : "Show only urgent tasks")
        .accessibilityLabel(
            urgentOnlyFilter
                ? "Showing only urgent tasks — tap to clear filter"
                : "\(urgentCount) urgent tasks — tap to filter"
        )
    }

    /// Smart-sort toggle. Sprint режим всегда smart-sort'ится — этот
    /// контрол меняет порядок только в `.all`. Иконка переключается между
    /// «обычная сортировка» и «магия по smart-score».
    private var smartSortButton: some View {
        Button {
            withAnimation(DS.Animation.motionAware(DS.Animation.standard, reduceMotion: reduceMotion)) {
                useSmartSort.toggle()
            }
        } label: {
            Image(systemName: useSmartSort ? "wand.and.stars" : "arrow.up.arrow.down")
                .font(.caption.weight(.medium))
                .foregroundStyle(useSmartSort ? skin.accentColor : skin.resolvedTextSecondary)
                .frame(width: DS.Size.iconLarge, height: DS.Size.iconLarge)
                .background(
                    Circle().fill(
                        skin.accentColor.opacity(useSmartSort ? DS.Opacity.lightFill : 0)
                    )
                )
                .contentShape(Circle())
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(.plain)
        .help(useSmartSort ? "Show in user order" : "Smart sort by deadline + priority")
        .accessibilityLabel(useSmartSort ? "Smart sort on — tap for user order" : "Smart sort off — tap to enable")
    }

    // MARK: - Mode picker

    private var modePicker: some View {
        SegmentedPillPicker(
            options: Mode.allCases,
            selection: Binding(
                get: { mode },
                set: { newMode in
                    withAnimation(DS.Animation.motionAware(DS.Animation.standard, reduceMotion: reduceMotion)) {
                        mode = newMode
                    }
                }
            ),
            labelProvider: { mode -> String in
                switch mode {
                case .sprint: return "Sprint \(min(activeTasks.count, Self.maxSprintTasks))"
                case .all:    return "All \(activeTasks.count)"
                }
            }
        )
    }

    // MARK: - Main content

    @ViewBuilder
    private var mainContent: some View {
        if visibleTasks.isEmpty && completedToday.isEmpty && backlogService.frozen.isEmpty {
            emptyState
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                VStack(spacing: DS.Spacing.xs) {
                    ForEach(visibleTasks) { task in
                        row(for: task)
                    }
                    completedTombstone
                    frozenTombstone
                }
                .padding(.horizontal, DS.Spacing.lg)
                .padding(.vertical, DS.Spacing.lg)
            }
            .scrollContentBackground(.hidden)
            .frame(maxHeight: .infinity)
        }
    }

    // MARK: - Empty state

    @ViewBuilder
    private var emptyState: some View {
        VStack(spacing: DS.Spacing.md) {
            Image(systemName: "checkmark.circle")
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(skin.resolvedTextTertiary)
            Text("Nothing to sprint on")
                .font(.headline)
                .foregroundStyle(skin.resolvedTextPrimary)
            Text("Add a task below to get going.")
                .font(.callout)
                .foregroundStyle(skin.resolvedTextSecondary)
        }
        .multilineTextAlignment(.center)
        .padding(DS.Spacing.lg)
    }

    // MARK: - Task row

    @ViewBuilder
    private func row(for task: BacklogTask) -> some View {
        BacklogTaskRow(
            task: task,
            isUrgent: BacklogLogic.isUrgent(task),
            // Sprint-mode visual styling — calmer row, larger title, less
            // metadata. Used in `.sprint`; `.all` keeps standard backlog
            // styling so the user sees full info when reviewing the queue.
            isSprintMode: mode == .sprint,
            onComplete: { complete(task) },
            onEdit: { onEditTask(task) },
            onDelete: { delete(task) },
            onFreeze: { freeze(task) }
        )
    }

    // MARK: - Tombstones

    @ViewBuilder
    private var completedTombstone: some View {
        if !completedToday.isEmpty {
            VStack(spacing: 0) {
                Button {
                    withAnimation(DS.Animation.motionAware(DS.Animation.standard, reduceMotion: reduceMotion)) {
                        showCompletedToday.toggle()
                    }
                } label: {
                    HStack(spacing: DS.Spacing.xs) {
                        Image(systemName: showCompletedToday ? "chevron.down" : "chevron.right")
                            .font(.caption2)
                            .contentTransition(.symbolEffect(.replace))
                        Text("\(completedToday.count) completed today")
                            .font(.caption2.monospacedDigit())
                            .contentTransition(.numericText())
                        Spacer()
                    }
                    .foregroundStyle(skin.resolvedTextTertiary)
                    .padding(.horizontal, DS.Spacing.xs)
                    .padding(.vertical, DS.Spacing.xs)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(completedToday.count) tasks completed today")

                if showCompletedToday {
                    ForEach(completedToday) { task in
                        completedRow(task)
                            .transition(.opacity)
                    }
                }
            }
            .motionAwareAnimation(DS.Animation.standard, value: showCompletedToday, reduceMotion: reduceMotion)
        }
    }

    @ViewBuilder
    private func completedRow(_ task: BacklogTask) -> some View {
        HStack(spacing: DS.Spacing.sm) {
            Button {
                uncomplete(task)
            } label: {
                Image(systemName: "checkmark.circle.fill")
                    .font(.callout)
                    .foregroundStyle(skin.resolvedTextTertiary)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Restore task")
            .accessibilityLabel("Restore \u{201C}\(task.title)\u{201D}")

            Text(task.title)
                .font(.callout)
                .foregroundStyle(skin.resolvedTextTertiary)
                .strikethrough()
                .lineLimit(1)

            Spacer()
        }
        .padding(.vertical, DS.Spacing.xxs)
        .padding(.horizontal, DS.Spacing.xs)
    }

    @ViewBuilder
    private var frozenTombstone: some View {
        let frozen = backlogService.frozen
        if !frozen.isEmpty {
            VStack(spacing: 0) {
                HStack(spacing: DS.Spacing.xs) {
                    Button {
                        withAnimation(DS.Animation.motionAware(DS.Animation.standard, reduceMotion: reduceMotion)) {
                            showFrozen.toggle()
                        }
                    } label: {
                        HStack(spacing: DS.Spacing.xs) {
                            Image(systemName: showFrozen ? "chevron.down" : "chevron.right")
                                .font(.caption2)
                                .contentTransition(.symbolEffect(.replace))
                            Image(systemName: "snowflake")
                                .font(.caption2)
                            Text("\(frozen.count) frozen")
                                .font(.caption2.monospacedDigit())
                                .contentTransition(.numericText())
                            Spacer()
                        }
                        .foregroundStyle(skin.resolvedTextTertiary)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(frozen.count) frozen tasks")

                    Button("Unfreeze all") {
                        let restoredIds = frozen.map(\.id)
                        withAnimation(DS.Animation.motionAware(DS.Animation.standard, reduceMotion: reduceMotion)) {
                            backlogService.unfreezeAll()
                        }
                        onUndoableAction?("Unfroze \(restoredIds.count) task\(restoredIds.count == 1 ? "" : "s")") { [backlogService] in
                            for id in restoredIds { backlogService.freezeTask(id: id) }
                        }
                    }
                    .font(.caption2)
                    .buttonStyle(.plain)
                    .foregroundStyle(skin.accentColor)
                }
                .padding(.horizontal, DS.Spacing.xs)
                .padding(.vertical, DS.Spacing.xs)

                if showFrozen {
                    ForEach(frozen) { task in
                        frozenRow(task)
                            .transition(.opacity)
                    }
                }
            }
            .motionAwareAnimation(DS.Animation.standard, value: showFrozen, reduceMotion: reduceMotion)
        }
    }

    @ViewBuilder
    private func frozenRow(_ task: BacklogTask) -> some View {
        HStack(spacing: DS.Spacing.sm) {
            Button {
                let snapshot = task
                withAnimation(DS.Animation.motionAware(DS.Animation.standard, reduceMotion: reduceMotion)) {
                    backlogService.unfreezeTask(id: task.id)
                }
                onUndoableAction?("Unfroze \u{201C}\(task.title)\u{201D}") { [backlogService] in
                    backlogService.updateTask(snapshot)
                    backlogService.freezeTask(id: snapshot.id)
                }
            } label: {
                Image(systemName: "snowflake")
                    .font(.callout)
                    .foregroundStyle(skin.resolvedTextTertiary)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Unfreeze task")
            .accessibilityLabel("Unfreeze \u{201C}\(task.title)\u{201D}")

            Text(task.title)
                .font(.callout)
                .foregroundStyle(skin.resolvedTextTertiary)
                .lineLimit(1)

            Spacer()
        }
        .padding(.vertical, DS.Spacing.xxs)
        .padding(.horizontal, DS.Spacing.xs)
    }

    // MARK: - Add task field

    /// Inline add-task field. Узкий клон того, что в BacklogView, без
    /// ghost-preview (timeline здесь нет, предсказывать слот некуда), но
    /// с тем же распознаванием duration в стиле «Write report 30m». Раньше
    /// SprintView был тупиком в empty-state — приходилось возвращаться в
    /// backlog ради добавления.
    private var addTaskField: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.xxs) {
            HStack(spacing: DS.Spacing.sm) {
                Image(systemName: "plus")
                    .font(.caption)
                    .foregroundStyle(isInputFocused ? AnyShapeStyle(skin.accentColor) : AnyShapeStyle(.tertiary))

                TextField("Add task\u{2026}", text: $newTaskTitle)
                    .textFieldStyle(.plain)
                    .font(.callout)
                    .focused($isInputFocused)
                    .onSubmit { addTask() }
                    .onExitCommand {
                        newTaskTitle = ""
                        parsedNewTaskTitle = ("", nil)
                        isInputFocused = false
                    }

                if let minutes = parsedNewTaskTitle.durationMinutes {
                    Text(DS.formatMinutes(minutes))
                        .font(.caption2.weight(.medium).monospacedDigit())
                        .foregroundStyle(skin.accentColor)
                        .padding(.horizontal, DS.Spacing.sm)
                        .padding(.vertical, DS.Spacing.xxs)
                        .background(
                            Capsule().fill(skin.accentColor.opacity(DS.Opacity.subtleFill))
                        )
                        .transition(.opacity.combined(with: .scale(scale: 0.9)))
                        .accessibilityLabel("Parsed duration: \(DS.formatMinutes(minutes))")
                }
            }
            .padding(.horizontal, DS.Spacing.sm)
            .padding(.vertical, DS.Spacing.xs)
            .background(
                RoundedRectangle(cornerRadius: DS.Size.subtleCornerRadius, style: .continuous)
                    .fill(skin.accentColor.opacity(isInputFocused ? DS.Opacity.lightFill : DS.Opacity.subtleFill))
            )
            .motionAwareAnimation(DS.Animation.quick, value: parsedNewTaskTitle.durationMinutes, reduceMotion: reduceMotion)
        }
        .padding(.horizontal, DS.Spacing.lg)
        .padding(.vertical, DS.Spacing.md)
    }

    // MARK: - Actions

    private func addTask() {
        let parsed = parsedNewTaskTitle
        let title = parsed.cleaned
        guard !title.isEmpty else { return }

        let task = BacklogTask(
            title: title,
            durationMinutes: parsed.durationMinutes ?? optimizerService.defaultTaskDurationMinutes,
            priority: .medium
        )
        withAnimation(DS.Animation.motionAware(DS.Animation.standard, reduceMotion: reduceMotion)) {
            backlogService.addTask(task)
        }
        newTaskTitle = ""
        parsedNewTaskTitle = ("", nil)
    }

    private func complete(_ task: BacklogTask) {
        let snapshot = task
        withAnimation(DS.Animation.motionAware(DS.Animation.entrance, reduceMotion: reduceMotion)) {
            backlogService.completeTask(id: task.id)
        }
        Haptics.tap()
        onUndoableAction?("Completed \u{201C}\(task.title)\u{201D}") { [backlogService] in
            backlogService.updateTask(snapshot)
        }
    }

    private func delete(_ task: BacklogTask) {
        let originalIndex = backlogService.indexOfTask(id: task.id)
        _ = backlogService.removeTask(id: task.id)
        onUndoableAction?("\u{201C}\(task.title)\u{201D} deleted") { [backlogService] in
            backlogService.restoreTask(task, at: originalIndex)
        }
    }

    private func freeze(_ task: BacklogTask) {
        let snapshot = task
        withAnimation(DS.Animation.motionAware(DS.Animation.standard, reduceMotion: reduceMotion)) {
            backlogService.freezeTask(id: task.id)
        }
        onUndoableAction?("Froze \u{201C}\(task.title)\u{201D}") { [backlogService] in
            backlogService.updateTask(snapshot)
        }
    }

    private func uncomplete(_ task: BacklogTask) {
        var restored = task
        restored.status = .pending
        restored.completedAt = nil
        withAnimation(DS.Animation.motionAware(DS.Animation.standard, reduceMotion: reduceMotion)) {
            backlogService.updateTask(restored)
        }
    }
}
