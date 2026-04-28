import SwiftUI

// MARK: - Backlog Fullscreen View

/// Full-screen Backlog view that lives inside the popover navigation stack.
/// Reachable via the fullscreen-affordance button in `BacklogView`'s header.
///
/// Visually it is **the same Tasks card** the user sees collapsed on the main
/// view, distended to popover height. One platter chrome (`.skinTasksBlockChrome`)
/// wraps the whole surface — header, list, add-task field — so collapsed-on-main
/// and fullscreen-Backlog read as the same object in two states. Бирман:
/// один объект — одна форма.
///
/// Design:
/// - Полноразмерный Backlog: показывает весь активный список в
///   пользовательском порядке (или в smart-sort, если включён toggle).
///   Отдельных «режимов» нет — это просто та же карточка задач, что и
///   на главной, но во весь popover. Бирман: одно действие — одна форма;
///   режим-переключатель внутри карточки только запутывал.
/// - Schedule, urgent filter, smart-sort, drag-reorder, keyboard reorder —
///   всё, что есть в inline BacklogView, доступно и здесь.
/// - The list itself stays inline-editable: complete with a tap, edit by
///   pushing the same `EditTaskView` the backlog uses, undo via toast.
/// - Inline `+ Add task…` поле снизу — пустое состояние не должно быть
///   тупиком; добавлять задачу можно прямо отсюда.
/// - Completed-today / frozen tombstones — те же квартиранты, что и в
///   inline Backlog'е, чтобы история сегодняшнего дня не терялась при
///   переходе в fullscreen.
/// - Hot-keys 1–9 — быстрое завершение N-й видимой задачи. Это надстройка
///   к inline Backlog'у (там цифры заняты обычным вводом в add-field), но
///   для fullscreen-режима они уместны: руки уже на клавиатуре.
struct BacklogFullscreenView: View {
    var backlogService: BacklogService
    var optimizerService: OptimizerService
    /// Calendar event source — surfaced for parity with the inline backlog;
    /// reserved for future cross-context affordances inside fullscreen.
    var reminderService: ReminderService
    var onExit: () -> Void
    var onEditTask: (BacklogTask) -> Void
    /// Fired when the «Schedule» pill in the block header is tapped —
    /// same role the pill plays inside `BacklogView`. The parent opens the
    /// command palette (`PaletteContext`) so the optimizer can plan the
    /// queue without leaving fullscreen.
    var onOpenPalette: (() -> Void)? = nil
    var onUndoableAction: ((_ message: String, _ undo: @escaping () -> Void) -> Void)? = nil

    @Environment(\.activeSkin) private var skin
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Hot-keys are bound to the first N visible rows. 9 covers the digit
    /// keyboard 1…9; tasks beyond that need scrolling and a click. Same
    /// «keyboard-first completion» idea as Things and Linear.
    static let maxHotKeyTasks = 9

    @State private var newTaskTitle = ""
    /// Cached parse result for `newTaskTitle`. Updated from `onChange` so
    /// the title/duration pair is computed once per keystroke.
    @State private var parsedNewTaskTitle: (cleaned: String, durationMinutes: Int?) = ("", nil)
    @FocusState private var isInputFocused: Bool
    /// Row-level keyboard focus, mirroring BacklogView. `nil` when the input
    /// field owns focus instead. Driven by ↑/↓ between rows; ⌘↑/↓ reorders.
    @FocusState private var focusedTaskId: String?

    @State private var showCompletedToday: Bool = false
    @State private var showFrozen: Bool = false
    /// Urgent-only filter — narrows the list to tasks whose deadline falls
    /// inside the urgency window. Session-local. Mirrors BacklogView's
    /// `urgentOnlyFilter` so users carry the same mental model across views.
    @State private var urgentOnlyFilter: Bool = false
    /// Smart-sort toggle — re-orders the list by `BacklogLogic.smartScore`
    /// instead of user drag order. Session-local.
    @State private var useSmartSort: Bool = false

    /// Все активные задачи (без urgent-фильтров и пр.) — общая основа для
    /// расчёта capacity ring (тот показывает общий груз очереди, а не
    /// отфильтрованный подсет).
    private var activeTasks: [BacklogTask] {
        BacklogLogic.activeTasks(backlogService.tasks)
    }

    /// Active set after the urgent-only filter — common base for the visible
    /// list and the auto-disengage rule when the urgent set dries up.
    private var activeFiltered: [BacklogTask] {
        guard urgentOnlyFilter else { return activeTasks }
        return activeTasks.filter { BacklogLogic.isUrgent($0) }
    }

    /// Tasks rendered in the list. Пользовательский порядок (или smart-sort,
    /// если toggle включён), плюс urgent-only фильтр. Параллельно inline
    /// BacklogView'у — один и тот же мысленный набор задач, просто на весь
    /// popover.
    private var visibleTasks: [BacklogTask] {
        useSmartSort ? BacklogLogic.smartSorted(activeFiltered) : activeFiltered
    }

    /// Total scheduled minutes across the visible set — drives the ETA chip
    /// («когда закончится backlog, если браться сейчас»).
    private var totalMinutes: Int {
        visibleTasks.reduce(0) { $0 + $1.durationMinutes }
    }

    /// Projected end-of-session time: `now` + total visible minutes. Answers
    /// «когда я закончу, если возьмусь прямо сейчас?» — превращает суммарную
    /// длительность из числа в час дня. Если ETA выходит за пределы суток,
    /// добавляется бейдж `+Nd` чтобы пользователь видел, что «всё-сегодня»
    /// — иллюзия. Nil когда видимых задач нет.
    ///
    /// `now` принимается параметром (а не читается через `Date()`), чтобы
    /// `TimelineView` мог пересчитывать ETA каждую минуту без перекапывания
    /// computed-свойств. Иначе цифра залипает на момент открытия popover'а
    /// — пользователь сидит час, ETA показывает время как при заходе.
    private func etaLabel(now: Date) -> String? {
        guard !visibleTasks.isEmpty else { return nil }
        let eta = now.addingTimeInterval(TimeInterval(totalMinutes * 60))
        let timeStr = eta.formatted(date: .omitted, time: .shortened)

        let cal = Calendar.current
        if cal.isDate(eta, inSameDayAs: now) {
            return timeStr
        }
        let dayDelta = cal.dateComponents(
            [.day],
            from: cal.startOfDay(for: now),
            to: cal.startOfDay(for: eta)
        ).day ?? 0
        if dayDelta >= 1 {
            return "\(timeStr) +\(dayDelta)d"
        }
        return timeStr
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

    var body: some View {
        VStack(spacing: 0) {
            PopoverHeader(
                title: "Backlog",
                showBack: true,
                // HIG: back label = название предыдущего экрана. Возвращаемся
                // в основной popover (today + timeline + inline backlog
                // card) — это «Today», не «Backlog» (полноэкранная форма
                // которого мы сейчас и есть).
                backLabel: "Today",
                onBack: onExit
            )

            // Block container — same chrome as the inline Tasks card on the
            // main view (`.skinTasksBlockChrome`). The whole fullscreen
            // surface lives inside one rounded platter so it reads as the
            // same object the user sees collapsed on the main screen, just
            // distended to popover height. Бирман: один объект — одна форма.
            VStack(spacing: 0) {
                blockHeader
                mainContent
                addTaskField
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .skinTasksBlockChrome(skin)
            .padding(.horizontal, DS.Spacing.contentMargin)
            .padding(.top, DS.Spacing.md)
            .padding(.bottom, DS.Spacing.md)
        }
        .frame(width: DS.Popover.width, height: DS.Popover.height)
        .background(hotKeyBindings)
        .onChange(of: newTaskTitle) { _, newValue in
            parsedNewTaskTitle = BacklogTitleParser.parse(newValue)
        }
        .onChange(of: activeTasks.count) { _, _ in
            // Auto-disengage urgent filter if the urgent set dries up — same
            // safety net as in BacklogView, prevents stranding the user in
            // an empty filtered view.
            if urgentOnlyFilter, activeFiltered.isEmpty {
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

    // MARK: - Block header
    //
    // Один ряд внутри карточки, зеркало BacklogView'овского `backlogHeader`:
    //
    //   [ring] [Done by 6:18] [count] [→ ETA] [urgent] [smart] [⊕]
    //
    // Capacity ring + verdict — общий груз очереди. Total count — то же
    // число, что в inline-карточке (без чеврона: здесь раскрытие/свёртка
    // не нужны — это и есть полная карточка). ETA показывает, во сколько
    // закончится backlog, если взяться прямо сейчас, и обновляется через
    // TimelineView. Schedule-иконка открывает палитру.

    private var blockHeader: some View {
        HStack(spacing: DS.Spacing.sm) {
            if !activeTasks.isEmpty {
                BacklogCapacityRing(
                    pendingMinutes: pendingWorkloadMinutes,
                    remainingWorkdayMinutes: remainingWorkdayMinutes,
                    optimizerService: optimizerService
                )
                .help(capacityRingTooltip)

                BacklogCapacityLabel(
                    pendingMinutes: pendingWorkloadMinutes,
                    optimizerService: optimizerService
                )

                // Total count — same role as the chevron+count button in
                // inline Backlog. Здесь нет disclosure (карточка и так во
                // весь popover), поэтому это не button, а просто число.
                Text("\(activeTasks.count)")
                    .font(.subheadline.weight(.medium).monospacedDigit())
                    .foregroundStyle(skin.resolvedTextPrimary)
                    .contentTransition(.numericText())
                    .help("\(activeTasks.count) task\(activeTasks.count == 1 ? "" : "s") in backlog")
                    .accessibilityLabel("\(activeTasks.count) tasks")
            }

            if !visibleTasks.isEmpty {
                etaChip
            }

            if urgentCount > 0 {
                urgentFilterButton
            }
            if activeTasks.count > 1 {
                smartSortButton
            }

            Spacer(minLength: 0)

            if !activeTasks.isEmpty, onOpenPalette != nil {
                scheduleButton
            }
        }
        .padding(.horizontal, DS.Spacing.sm)
        .padding(.vertical, DS.Spacing.sm)
        // Publish the block header's bottom Y so the command palette (a
        // sibling overlay anchored via `OptimizerBottomKey` in MenuBarView)
        // lands right under the header inside the fullscreen block — same
        // pattern QuickActions uses on the main view. Without this the
        // palette inherits the stale main-view Y when ⌘K is pressed in
        // fullscreen and ends up floating inside the task list.
        .background(
            GeometryReader { geo in
                Color.clear.preference(
                    key: OptimizerBottomKey.self,
                    value: geo.frame(in: .named(menuBarRootCoordinateSpace)).maxY
                )
            }
        )
    }

    /// ETA-чип у block header'а: «→ 17:30 (+1d)» — когда закончится весь
    /// видимый backlog, если браться сейчас. TimelineView прокручивает
    /// цифру каждую минуту, иначе она зависнет на момент открытия popover'а.
    @ViewBuilder
    private var etaChip: some View {
        TimelineView(.everyMinute) { ctx in
            if let etaLabel = etaLabel(now: ctx.date) {
                HStack(spacing: DS.Spacing.xxs) {
                    Text("\u{2192}")
                        .font(.caption2)
                        .foregroundStyle(skin.resolvedTextTertiary)
                    Text(etaLabel)
                        .font(.caption.weight(.medium).monospacedDigit())
                        .foregroundStyle(skin.resolvedTextSecondary)
                        .contentTransition(.numericText())
                        .accessibilityLabel("Estimated finish time \(etaLabel)")
                }
            }
        }
    }

    /// Schedule pill — copy of BacklogView's `scheduleButton`. Открывает
    /// command palette: пользователь не уходит из fullscreen-Backlog'а, чтобы
    /// запланировать очередь — Бирман: «не отрывай человека от текущего
    /// объекта».
    private var scheduleButton: some View {
        // Зеркалирует BacklogView.scheduleButton: иконка вместо «Schedule»,
        // та же accent-капсула. Хедер так же узок, как у inline-карточки,
        // текстовая pill там обрезалась.
        Button {
            onOpenPalette?()
        } label: {
            Image(systemName: "calendar.badge.plus")
                .font(.caption.weight(.semibold))
                .foregroundStyle(skin.accentColor)
                .frame(width: DS.Size.iconSmall, height: DS.Size.iconSmall)
                .padding(.horizontal, DS.Spacing.xs)
                .padding(.vertical, DS.Spacing.xxs)
                .background {
                    Capsule().fill(skin.accentColor.opacity(DS.Opacity.lightFill))
                }
                .overlay {
                    Capsule().strokeBorder(
                        skin.accentColor.opacity(DS.Opacity.subtleBorder),
                        lineWidth: DS.Border.thin
                    )
                }
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help("Open scheduler")
        .accessibilityLabel("Open scheduler")
    }

    /// Red «N urgent» pill — toggles the urgent-only filter. Filled
    /// background while engaged so the user can see the filter is active;
    /// hidden когда нет urgent-задач (контрол без эффекта — украшение).
    private var urgentFilterButton: some View {
        Button {
            // `.levelChange` haptic for filter mode switch — discrete
            // state change «list narrows / list opens up», not a
            // micro-click. Same pattern on every Backlog filter toggle.
            Haptics.impact()
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

    /// Smart-sort toggle. Иконка переключается между «обычная сортировка»
    /// (пользовательский drag-порядок) и «магия по smart-score» (deadline +
    /// priority). Зеркало того же toggle в overflow-меню inline Backlog'а.
    private var smartSortButton: some View {
        Button {
            // `.levelChange` for sort-order switch — list reorders, not a
            // micro-click on a button.
            Haptics.impact()
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

    // MARK: - Main content

    @ViewBuilder
    private var mainContent: some View {
        if visibleTasks.isEmpty && completedToday.isEmpty && backlogService.frozen.isEmpty {
            emptyState
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                VStack(spacing: DS.Spacing.xs) {
                    ForEach(Array(visibleTasks.enumerated()), id: \.element.id) { index, task in
                        // Hot-key digit передаётся первым `maxHotKeyTasks`
                        // строкам — checkbox tooltip учит «press N to
                        // complete» при наведении. Все строки равноценны,
                        // порядок задаёт user drag (или smart-sort, если
                        // включён).
                        row(
                            for: task,
                            hotKey: index < Self.maxHotKeyTasks ? index + 1 : nil
                        )
                    }
                    tombstones
                }
                // Inside the card chrome — match BacklogView's inner padding
                // so the column of rows aligns visually with the inline
                // version on the main view.
                .padding(.horizontal, DS.Spacing.sm)
                .padding(.vertical, DS.Spacing.sm)
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
            Text("Backlog is empty")
                .font(.headline)
                .foregroundStyle(skin.resolvedTextPrimary)
            Text("Add a task below to get going.")
                .font(.callout)
                .foregroundStyle(skin.resolvedTextSecondary)
        }
        .multilineTextAlignment(.center)
        .padding(DS.Spacing.lg)
    }

    // MARK: - Hot-keys

    /// Hidden surface that registers number-key shortcuts for completing
    /// the first N visible tasks. Pressing «1» completes the first row,
    /// «2» the second, etc. — same idea Things and Linear use for
    /// keyboard-first completion. Available только во fullscreen-Backlog'е,
    /// потому что в inline-варианте цифры заняты обычным вводом в
    /// add-field над таймлайном.
    ///
    /// Gated on `isInputFocused`: when the add-task field is active, digit
    /// keys must be normal text input, not commands. Conditionally rendering
    /// the buttons keeps them out of the responder chain entirely while the
    /// field is focused.
    ///
    /// Mounted as `.background(...)` of the popover root so it occupies no
    /// visual space but still participates in shortcut routing.
    @ViewBuilder
    private var hotKeyBindings: some View {
        if !isInputFocused, !visibleTasks.isEmpty {
            // SF doesn't have a more compact way to register N shortcuts
            // dynamically, so explicit ForEach. `.frame(width: 0, height: 0)`
            // + `.opacity(0)` makes the buttons invisible without removing
            // them from the tree (which would also remove the shortcut).
            ForEach(Array(visibleTasks.prefix(Self.maxHotKeyTasks).enumerated()), id: \.element.id) { index, task in
                Button("Complete task \(index + 1)") {
                    // Hot-key path bypasses the row's checkbox button, so we
                    // fire the same tactile click here. Tap-to-complete via
                    // the checkbox already haptics from `IconPressStyle`'s
                    // host button (`BacklogTaskRow.checkbox`); `complete()`
                    // itself stays haptic-free so the cue follows the user
                    // gesture, not the model mutation.
                    Haptics.tap()
                    complete(task)
                }
                .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: [])
                .frame(width: 0, height: 0)
                .opacity(0)
                .accessibilityHidden(true)
            }
        }
    }

    // MARK: - Task row

    /// Builds one task row. Полные reorder/drag affordances — то же поведение,
    /// что в inline BacklogView'е: hover-чевроны, drag-to-reorder, контекстное
    /// меню. Все строки равноценны, порядок диктует пользовательский drag
    /// (или smart-sort, если включён).
    @ViewBuilder
    private func row(for task: BacklogTask, hotKey: Int?) -> some View {
        BacklogTaskRow(
            task: task,
            isUrgent: BacklogLogic.isUrgent(task),
            canMoveUp: canMoveUp(task),
            canMoveDown: canMoveDown(task),
            onComplete: { complete(task) },
            onEdit: { onEditTask(task) },
            onDelete: { delete(task) },
            onFreeze: { freeze(task) },
            onReorderDrop: { dropped in
                handleReorderDrop(dropped: dropped, targetId: task.id)
            },
            onMoveUp: { moveTask(task, by: -1) },
            onMoveDown: { moveTask(task, by: +1) },
            onMoveToTop: { moveTaskToEdge(task, toTop: true) },
            onMoveToBottom: { moveTaskToEdge(task, toTop: false) },
            isFocused: focusedTaskId == task.id,
            onFocusPrev: { focusRow(offsetFrom: task.id, by: -1) },
            onFocusNext: { focusRow(offsetFrom: task.id, by: +1) },
            sprintHotKey: hotKey
        )
        .focusable()
        .focused($focusedTaskId, equals: task.id)
        .focusEffectDisabled()
    }

    // MARK: - Tombstones

    /// Shared completed-today + frozen summary rows. Mirror BacklogView 1:1
    /// — same leading-gutter alignment + 40pt floor, so the checkmark/snowflake
    /// column lines up under the active rows above.
    private var tombstones: some View {
        BacklogTombstones(
            completedToday: completedToday,
            frozen: backlogService.frozen,
            showCompleted: $showCompletedToday,
            showFrozen: $showFrozen,
            alignedLeadingGutter: true,
            minRowHeight: BacklogView.compactRowHeight,
            onUncomplete: { task in uncomplete(task) },
            onUnfreezeOne: { task in unfreezeOneWithUndo(task) },
            onUnfreezeAll: { unfreezeAllWithUndo() }
        )
    }

    /// Unfreeze a single task with an undo toast that re-freezes on tap.
    /// Same pattern as BacklogView, kept duplicated until the controllers
    /// themselves get extracted (out of scope for this refactor).
    private func unfreezeOneWithUndo(_ task: BacklogTask) {
        let snapshot = task
        withAnimation(DS.Animation.motionAware(DS.Animation.standard, reduceMotion: reduceMotion)) {
            backlogService.unfreezeTask(id: task.id)
        }
        onUndoableAction?("Unfroze \u{201C}\(task.title)\u{201D}") { [backlogService] in
            backlogService.updateTask(snapshot)
            backlogService.freezeTask(id: snapshot.id)
        }
    }

    private func unfreezeAllWithUndo() {
        let restoredIds = backlogService.frozen.map(\.id)
        withAnimation(DS.Animation.motionAware(DS.Animation.standard, reduceMotion: reduceMotion)) {
            backlogService.unfreezeAll()
        }
        onUndoableAction?("Unfroze \(restoredIds.count) task\(restoredIds.count == 1 ? "" : "s")") { [backlogService] in
            for id in restoredIds { backlogService.freezeTask(id: id) }
        }
    }

    // MARK: - Add task field

    /// Inline add-task field. Mirror of BacklogView's, без ghost-preview
    /// (timeline здесь нет, предсказывать слот некуда). Включает три
    /// одинаковых с inline-версией affordances: syntax-teaching placeholder
    /// в пустом состоянии, empty-state hint, focused-state shortcut hint —
    /// чтобы карточка-fullscreen и inline-карточка обучали одинаково.
    private var addTaskField: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.xxs) {
            HStack(spacing: DS.Spacing.sm) {
                Image(systemName: "plus")
                    .font(.caption)
                    .foregroundStyle(isInputFocused ? AnyShapeStyle(skin.accentColor) : AnyShapeStyle(.tertiary))

                TextField(addTaskPlaceholder, text: $newTaskTitle)
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

            // Hint for new users — disappears once they add a task. Same
            // copy as inline BacklogView so the empty-state lesson is
            // identical across surfaces.
            if activeTasks.isEmpty && !isInputFocused {
                Text("Tasks you add here will be scheduled into free slots")
                    .font(.caption2)
                    .foregroundStyle(skin.resolvedTextTertiary)
                    .transition(.opacity)
            }

            // Focused-state shortcut hint. HIG: discoverable shortcuts —
            // surface the two keys that matter (submit + cancel) exactly
            // while the field is active, then get out of the way. Birman:
            // подсказка живёт в том же месте, что и поле.
            if isInputFocused {
                HStack(spacing: DS.Spacing.xs) {
                    Text("\u{23CE} Add")
                    Text("·").foregroundStyle(skin.resolvedTextTertiary.opacity(DS.Opacity.half))
                    Text("\u{238B} Cancel")
                    Spacer(minLength: 0)
                }
                .font(.caption2)
                .foregroundStyle(skin.resolvedTextTertiary)
                .transition(.opacity)
                .accessibilityHidden(true)
            }
        }
        // Match BacklogView's add-field padding so the field sits at the
        // same offset from the card edge as the inline version.
        .padding(.horizontal, DS.Spacing.sm)
        .padding(.vertical, DS.Spacing.sm)
        .motionAwareAnimation(DS.Animation.quick, value: isInputFocused, reduceMotion: reduceMotion)
    }

    /// TextField placeholder. Teaching syntax when the backlog is empty
    /// («try: Write report 30m»), compact «Add task…» otherwise. Identical
    /// copy to inline BacklogView.
    private var addTaskPlaceholder: String {
        activeTasks.isEmpty
            ? "Add task — try: Write report 30m"
            : "Add task\u{2026}"
    }

    // MARK: - Reorder helpers
    //
    // Mirror BacklogView's behaviour so users get identical reorder semantics
    // across the two surfaces.

    private func canMoveUp(_ task: BacklogTask) -> Bool {
        visibleTasks.first?.id != task.id
            && visibleTasks.contains(where: { $0.id == task.id })
    }

    private func canMoveDown(_ task: BacklogTask) -> Bool {
        visibleTasks.last?.id != task.id
            && visibleTasks.contains(where: { $0.id == task.id })
    }

    /// Move keyboard focus between visible rows. Boundaries clamp silently —
    /// no wrap-around. Identical to BacklogView so the two views share muscle
    /// memory.
    private func focusRow(offsetFrom currentId: String, by delta: Int) {
        let tasks = visibleTasks
        guard let idx = tasks.firstIndex(where: { $0.id == currentId }) else { return }
        let target = idx + delta
        guard target >= 0, target < tasks.count else { return }
        focusedTaskId = tasks[target].id
    }

    /// Reorder by ±1 slot via keyboard / context menu. Honours user-order
    /// only; in smart-sort mode the call still mutates storage order, but
    /// the visible position depends on the score — same as BacklogView.
    private func moveTask(_ task: BacklogTask, by delta: Int) {
        let ordered = visibleTasks
        guard let current = ordered.firstIndex(where: { $0.id == task.id }) else { return }
        let target = current + delta
        guard ordered.indices.contains(target) else { return }
        let targetId = ordered[target].id

        let previousIndex = backlogService.indexOfTask(id: task.id)
        withAnimation(DS.Animation.motionAware(DS.Animation.standard, reduceMotion: reduceMotion)) {
            if delta < 0 {
                backlogService.moveTask(id: task.id, before: targetId)
            } else if target + 1 < ordered.count {
                backlogService.moveTask(id: task.id, before: ordered[target + 1].id)
            } else {
                backlogService.moveTaskToEnd(id: task.id)
            }
        }

        let taskId = task.id
        onUndoableAction?("Reordered \u{201C}\(task.title)\u{201D}") { [backlogService] in
            guard let previousIndex,
                  let current = backlogService.tasks.first(where: { $0.id == taskId })
            else { return }
            _ = backlogService.removeTask(id: taskId)
            backlogService.restoreTask(current, at: previousIndex)
        }
    }

    private func moveTaskToEdge(_ task: BacklogTask, toTop: Bool) {
        let previousIndex = backlogService.indexOfTask(id: task.id)
        withAnimation(DS.Animation.motionAware(DS.Animation.standard, reduceMotion: reduceMotion)) {
            if toTop {
                if let firstVisible = visibleTasks.first, firstVisible.id != task.id {
                    backlogService.moveTask(id: task.id, before: firstVisible.id)
                }
            } else {
                backlogService.moveTaskToEnd(id: task.id)
            }
        }
        let taskId = task.id
        onUndoableAction?("Moved \u{201C}\(task.title)\u{201D} to \(toTop ? "top" : "bottom")") { [backlogService] in
            guard let previousIndex,
                  let current = backlogService.tasks.first(where: { $0.id == taskId })
            else { return }
            _ = backlogService.removeTask(id: taskId)
            backlogService.restoreTask(current, at: previousIndex)
        }
    }

    /// Drop one task onto another to reorder. If the dropped task and the
    /// target live in different context groups, the dropped task adopts the
    /// target's context (otherwise grouping would silently undo the visual
    /// move). Mirrors BacklogView's `handleReorderDrop` 1:1.
    private func handleReorderDrop(dropped: BacklogTaskDrag, targetId: String) {
        guard dropped.taskId != targetId,
              let originalTask = backlogService.tasks.first(where: { $0.id == dropped.taskId }),
              backlogService.tasks.contains(where: { $0.id == targetId }),
              let target = backlogService.tasks.first(where: { $0.id == targetId })
        else { return }

        let previousIndex = backlogService.indexOfTask(id: originalTask.id)
        let previousContext = originalTask.context
        let contextChanged = originalTask.context != target.context

        withAnimation(DS.Animation.motionAware(DS.Animation.standard, reduceMotion: reduceMotion)) {
            if contextChanged {
                var updated = originalTask
                updated.context = target.context
                backlogService.updateTask(updated)
            }
            backlogService.moveTask(id: originalTask.id, before: targetId)
        }

        let taskId = originalTask.id
        let originalSnapshot = originalTask
        onUndoableAction?(
            contextChanged
                ? "Moved \u{201C}\(originalTask.title)\u{201D} to \(target.context ?? "No project")"
                : "Reordered \u{201C}\(originalTask.title)\u{201D}"
        ) { [backlogService] in
            guard var current = backlogService.tasks.first(where: { $0.id == taskId }) else {
                backlogService.restoreTask(originalSnapshot, at: previousIndex)
                return
            }
            current.context = previousContext
            backlogService.updateTask(current)
            if let previousIndex {
                _ = backlogService.removeTask(id: taskId)
                backlogService.restoreTask(current, at: previousIndex)
            }
        }
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
        // Tap-to-complete via checkbox already fires `Haptics.tap()` from
        // the press itself (`BacklogTaskRow.checkbox` + `IconPressStyle`),
        // so no haptic here. Hot-key completion (digits 1-9) is the other
        // entry path; the haptic for that case fires from the digit-shortcut
        // button before delegating into `complete(_:)`.
        let snapshot = task
        withAnimation(DS.Animation.motionAware(DS.Animation.entrance, reduceMotion: reduceMotion)) {
            backlogService.completeTask(id: task.id)
        }
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
