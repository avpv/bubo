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
    /// Fired when the user taps "Schedule" in `.all` mode. Same hook the
    /// inline backlog uses — opens the optimizer/palette so users don't have
    /// to leave the fullscreen view to plan the queue. Sprint mode keeps the
    /// header calm and omits this CTA on purpose.
    var onScheduleTasks: (() -> Void)? = nil
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
    /// Row-level keyboard focus, mirroring BacklogView. `nil` when the input
    /// field owns focus instead. Driven by ↑/↓ between rows; ⌘↑/↓ reorders
    /// in `.all` mode (sprint mode is curated by the machine — reorder there
    /// would fight smart-sort).
    @FocusState private var focusedTaskId: String?
    /// Hover state for the Schedule pill — same pattern as BacklogView so the
    /// affordance reads as a button at rest, brightens on hover.
    @State private var isScheduleHovering: Bool = false

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
        if showsModePicker { return true }
        if !activeTasks.isEmpty {
            if mode == .all, urgentCount > 0 || activeTasks.count > 1 { return true }
            // Schedule lives in both modes — see `controlsRow`. The presence
            // of the action alone is enough to render the strip; we don't
            // want a mode switch to be the price of «plan my tasks».
            if onScheduleTasks != nil { return true }
        }
        return false
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
        .background(hotKeyBindings)
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

    /// Header trailing: capacity ring + capacity label («сколько в очереди /
    /// сколько осталось дня») + count·time + ETA текущего видимого набора.
    /// Кольцо отвечает на «влезет ли весь backlog?», текст рядом — на
    /// «во сколько именно?». Бирман: цвет — это сигнал, число — данные;
    /// рядом — сильнее, чем порознь.
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

                BacklogCapacityLabel(
                    pendingMinutes: pendingWorkloadMinutes,
                    optimizerService: optimizerService
                )
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

                    // ETA пересчитывается каждую минуту через TimelineView
                    // — иначе цифра «протухает» сразу после открытия
                    // popover'а: пользователь сидит 30 минут, ETA всё ещё
                    // показывает время как при заходе. Бирман: «информация
                    // должна жить, не быть моментальным снимком».
                    TimelineView(.everyMinute) { ctx in
                        if let etaLabel = etaLabel(now: ctx.date) {
                            HStack(spacing: DS.Spacing.xxs) {
                                // Стрелка как визуальный «ведёт к»: сумма
                                // минут превращается в час окончания.
                                // ASCII (`→`) читается мгновенно и не
                                // требует SF-иконки.
                                Text("\u{2192}")
                                    .font(.caption2)
                                    .foregroundStyle(skin.resolvedTextTertiary)
                                Text(etaLabel)
                                    .font(.subheadline.weight(.regular).monospacedDigit())
                                    .foregroundStyle(skin.resolvedTextSecondary)
                                    .contentTransition(.numericText())
                                    .accessibilityLabel("Estimated finish time \(etaLabel)")
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: - Controls row

    /// Row под header'ом: переключатель Sprint/All слева, фильтры/тоглы
    /// справа. Urgent + smart-sort показываются только в `.all` — Sprint
    /// держим чистым (top-N smart-sort + спокойные строки), там не место
    /// дополнительным фильтрам. Schedule, наоборот, живёт в обоих режимах:
    /// «спланировать backlog» — это намерение того же уровня, что и «что
    /// делать сейчас», и прятать его за переключателем означало заставить
    /// пользователя гулять в `.all` и обратно ради одной кнопки.
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

            // Same hook the inline backlog uses — opens the optimizer
            // palette. Visible in both modes so users never have to exit
            // fullscreen (or flip to `.all`) to plan the queue.
            if !activeTasks.isEmpty, onScheduleTasks != nil {
                scheduleButton
            }
        }
    }

    /// Schedule pill — primary action in `.all` mode. Visual mirrors the
    /// inline BacklogView button so muscle memory carries between surfaces.
    private var scheduleButton: some View {
        Button {
            onScheduleTasks?()
        } label: {
            Text("Schedule")
                .font(.caption.weight(.medium))
                .foregroundStyle(skin.accentColor)
                .padding(.horizontal, DS.Spacing.sm)
                .padding(.vertical, DS.Spacing.xxs)
                .background {
                    Capsule()
                        .fill(skin.accentColor.opacity(isScheduleHovering ? 0.16 : DS.Opacity.lightFill))
                }
                .overlay {
                    Capsule()
                        .strokeBorder(
                            skin.accentColor.opacity(isScheduleHovering ? DS.Opacity.softAccent : DS.Opacity.subtleBorder),
                            lineWidth: DS.Border.thin
                        )
                }
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(DS.Animation.motionAware(DS.Animation.quick, reduceMotion: reduceMotion)) {
                isScheduleHovering = hovering
            }
        }
        .help("Schedule tasks into free slots")
        .accessibilityLabel("Schedule tasks")
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
                    ForEach(Array(visibleTasks.enumerated()), id: \.element.id) { index, task in
                        // Первая строка в Sprint mode получает «now playing»
                        // полосу — визуальный ответ на «с чего начать?». В
                        // `.all` строки равноценны, метка не появляется.
                        // Hot-key digit передаётся первым maxSprintTasks
                        // строкам в Sprint mode — checkbox tooltip учит
                        // «press N to complete» при наведении.
                        row(
                            for: task,
                            isPrimary: mode == .sprint && index == 0,
                            sprintHotKey: (mode == .sprint && index < Self.maxSprintTasks) ? index + 1 : nil
                        )
                    }
                    tombstones
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

    // MARK: - Hot-keys

    /// Hidden surface that registers number-key shortcuts for completing
    /// the first N visible Sprint tasks. Pressing «1» in Sprint mode
    /// completes the primary row, «2» the second, etc. — same idea Things
    /// and Linear use for keyboard-first task completion.
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
        if mode == .sprint, !isInputFocused, !visibleTasks.isEmpty {
            // SF doesn't have a more compact way to register N shortcuts
            // dynamically, so explicit ForEach. `.frame(width: 0, height: 0)`
            // + `.opacity(0)` makes the buttons invisible without removing
            // them from the tree (which would also remove the shortcut).
            ForEach(Array(visibleTasks.prefix(Self.maxSprintTasks).enumerated()), id: \.element.id) { index, task in
                Button("Complete task \(index + 1)") {
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

    @ViewBuilder
    private func row(for task: BacklogTask, isPrimary: Bool, sprintHotKey: Int?) -> some View {
        HStack(spacing: 0) {
            // Sprint-mode rows get a «now playing» gutter on the left:
            // accent bar on the primary (first) row, transparent reservation
            // on the rest so the row content stays aligned. `.all` mode skips
            // the gutter entirely — нет primary, нет смысла резервировать
            // место под пустую колонку.
            if mode == .sprint {
                Rectangle()
                    .fill(isPrimary ? skin.accentColor : Color.clear)
                    .frame(width: 3)
                    .padding(.vertical, DS.Spacing.xs)
                    .clipShape(RoundedRectangle(cornerRadius: 1.5))
                    .padding(.trailing, DS.Spacing.xs)
                    .accessibilityHidden(!isPrimary)
                    .accessibilityLabel(isPrimary ? "Up next" : "")
            }

            // `.all` mode wires the full reorder/drag affordances so the
            // fullscreen surface behaves like an expanded BacklogView — same
            // hover chevrons, same drag-to-reorder, same context menu. Sprint
            // mode keeps the read-only calm: machine curates the order, user
            // can't fight it row by row.
            let isAllMode = mode == .all
            BacklogTaskRow(
                task: task,
                isUrgent: BacklogLogic.isUrgent(task),
                canMoveUp: isAllMode ? canMoveUp(task) : true,
                canMoveDown: isAllMode ? canMoveDown(task) : true,
                isSprintMode: mode == .sprint,
                onComplete: { complete(task) },
                onEdit: { onEditTask(task) },
                onDelete: { delete(task) },
                onFreeze: { freeze(task) },
                onReorderDrop: isAllMode ? { dropped in
                    handleReorderDrop(dropped: dropped, targetId: task.id)
                } : { _ in },
                onMoveUp: isAllMode ? { moveTask(task, by: -1) } : {},
                onMoveDown: isAllMode ? { moveTask(task, by: +1) } : {},
                onMoveToTop: isAllMode ? { moveTaskToEdge(task, toTop: true) } : {},
                onMoveToBottom: isAllMode ? { moveTaskToEdge(task, toTop: false) } : {},
                isFocused: focusedTaskId == task.id,
                onFocusPrev: { focusRow(offsetFrom: task.id, by: -1) },
                onFocusNext: { focusRow(offsetFrom: task.id, by: +1) },
                sprintHotKey: sprintHotKey
            )
            .focusable()
            .focused($focusedTaskId, equals: task.id)
            .focusEffectDisabled()
        }
    }

    // MARK: - Tombstones

    /// Shared completed-today + frozen summary rows.
    ///
    /// `.all` mode rows mirror BacklogView 1:1, so we ask for the same
    /// leading-gutter alignment + 40pt floor — the checkmark/snowflake
    /// column lines up under the active rows above. `.sprint` mode rows
    /// open with a 3pt accent bar (not the 16pt icon gutter), so reusing
    /// `alignedLeadingGutter` there would create phantom whitespace; the
    /// tombstones stay content-sized.
    private var tombstones: some View {
        BacklogTombstones(
            completedToday: completedToday,
            frozen: backlogService.frozen,
            showCompleted: $showCompletedToday,
            showFrozen: $showFrozen,
            alignedLeadingGutter: mode == .all,
            minRowHeight: mode == .all ? BacklogView.compactRowHeight : nil,
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

    // MARK: - Reorder helpers (`.all` mode only)
    //
    // Mirror BacklogView's behaviour so users get identical reorder semantics
    // across the two surfaces. Sprint mode never calls these — its order is
    // owned by smart-sort and the cap.

    private func canMoveUp(_ task: BacklogTask) -> Bool {
        guard mode == .all else { return false }
        return visibleTasks.first?.id != task.id
            && visibleTasks.contains(where: { $0.id == task.id })
    }

    private func canMoveDown(_ task: BacklogTask) -> Bool {
        guard mode == .all else { return false }
        return visibleTasks.last?.id != task.id
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
