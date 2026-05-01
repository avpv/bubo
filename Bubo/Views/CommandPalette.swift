import SwiftUI

// MARK: - Command Palette
//
// Design (Birman):
// - "Пусть потеет машина": user says WHAT, system figures out HOW
// - 3-5 smart suggestions based on current schedule context
// - Free text → AI composes intents automatically
// - Enter runs instantly, Esc closes, undo via toast
// - No categories, no phases, no "ACTIVE/SUGGESTED/MORE"
// - Power mode (⌥) reveals intent composer for advanced users
// - One action, one result, one undo

struct CommandPalette: View {
    @Environment(\.activeSkin) private var skin
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var optimizerService: OptimizerService
    var reminderService: ReminderService
    var agentService: AgentService

    var seedEvent: CalendarEvent? = nil
    var seedTask: BacklogTask? = nil
    var seedSlotMinutes: Int? = nil
    var seedSlotStart: Date? = nil
    var seedSlotEnd: Date? = nil
    var seedPreset: OptimizationRequest? = nil

    var onDismiss: () -> Void
    var onApplied: (_ request: OptimizationRequest, _ undo: @escaping () -> Void) -> Void

    // MARK: - State

    @State private var searchText = ""
    @State private var selectedIndex = 0
    @State private var phase: Phase = .picking
    @State private var dryRunPreview: String? = nil
    @State private var dryRunTask: Task<Void, Never>? = nil
    @State private var showPowerMode = false
    @State private var composedRequest: OptimizationRequest? = nil
    @State private var lastExecutedRequest: OptimizationRequest? = nil
    @State private var conflicts: [IntentConflictDetector.Conflict] = []
    @State private var appliedNotice: String? = nil
    @State private var workingTask: Task<Void, Never>? = nil
    @FocusState private var isSearchFocused: Bool

    private enum Phase: Equatable {
        case picking
        case working(String, intentName: String?)
        case applied([EventInfo], resolutions: [ActionableResolution])
        case failed(message: String, resolutions: [ActionableResolution])

        static func == (lhs: Phase, rhs: Phase) -> Bool {
            switch (lhs, rhs) {
            case (.picking, .picking): return true
            case (.working(let a, let an), .working(let b, let bn)): return a == b && an == bn
            case (.applied(let a, _), .applied(let b, _)): return a == b
            case (.failed(let a, _), .failed(let b, _)): return a == b
            default: return false
            }
        }
    }

    struct EventInfo: Equatable, Identifiable {
        let id: String
        let title: String
        let timeRange: String
    }

    // MARK: - Smart Suggestions

    /// 3-5 context-aware suggestions ranked by algorithm.
    private var suggestions: [SmartSuggestion] {
        // Seed context overrides (not ranked — explicit user intent)
        if let event = seedEvent {
            return [
                SmartSuggestion(
                    label: "Reschedule \u{201C}\(event.title)\u{201D}",
                    request: OptimizationRequest(
                        .onlyOptimize(eventIds: [event.id]),
                        .horizon(.today), .speed(.quick), .scenarios(count: 3),
                        name: "Reschedule"
                    )
                ),
                SmartSuggestion(
                    label: "Find better time",
                    request: OptimizationRequest(
                        .onlyOptimize(eventIds: [event.id]),
                        .findSlotsForBacklog,
                        .horizon(.today), .speed(.quick), .scenarios(count: 1),
                        name: "Find better time"
                    )
                ),
            ]
        }

        // Per-task scope: row's right-click → «Reschedule…» seeds the task
        // here. The optimizer schedules just this one backlog task into a
        // free slot, mirroring the per-event «Reschedule» flow above.
        if let task = seedTask {
            return [
                SmartSuggestion(
                    label: "Schedule \u{201C}\(task.title)\u{201D}",
                    request: OptimizationRequest(
                        .includeBacklogTasks(ids: [task.id]),
                        .horizon(.today), .speed(.quick), .scenarios(count: 3),
                        name: "Schedule task"
                    )
                ),
                SmartSuggestion(
                    label: "Find best time",
                    request: OptimizationRequest(
                        .includeBacklogTasks(ids: [task.id]),
                        .findSlotsForBacklog,
                        .prioritizeFocus(),
                        .horizon(.today), .speed(.quick), .scenarios(count: 1),
                        name: "Find best time"
                    )
                ),
            ]
        }

        if let minutes = seedSlotMinutes {
            // Pin requests to the clicked slot's time window.
            // In findSlotsOnly mode existing events are fixed obstacles,
            // so narrowing working hours constrains only new blocks.
            var focusRequest = OptimizationRequest.findFocus(minutes: minutes, period: nil)
            pinToSlot(&focusRequest)
            let focusSuggestion = SmartSuggestion(
                label: "Focus \(minutes) min",
                request: focusRequest
            )

            guard let backlog = optimizerService.backlogService,
                  !backlog.schedulable.isEmpty else {
                return [focusSuggestion]
            }

            var backlogRequest = OptimizationRequest.scheduleBacklog
            // Cap total task duration to slot size so the optimizer
            // schedules a subset that fits instead of failing.
            backlogRequest.add(.capTotal(minutesPerDay: minutes))
            pinToSlot(&backlogRequest)
            let taskSuggestion = SmartSuggestion(
                label: "Fill with tasks (\(backlog.schedulable.count))",
                request: backlogRequest
            )

            // Urgent/overdue context → tasks first; otherwise focus first.
            let tasksFirst = !backlog.overdue.isEmpty || !backlog.urgent(withinDays: 2).isEmpty
            return tasksFirst
                ? [taskSuggestion, focusSuggestion]
                : [focusSuggestion, taskSuggestion]
        }

        // Algorithm-ranked suggestions
        guard let backlog = optimizerService.backlogService else {
            return [SmartSuggestion(label: "Organize day", request: .organizeDay)]
        }
        let ranker = QuickActionRanker(
            backlogService: backlog,
            reminderService: reminderService,
            intentLearner: optimizerService.intentLearner
        )
        return ranker.rank(limit: 5).map { scored in
            SmartSuggestion(label: scored.action.label, request: scored.action.request)
        }
    }

    struct SmartSuggestion: Identifiable {
        let id = UUID()
        let label: String
        let request: OptimizationRequest
    }

    // MARK: - Search

    private var searchResults: [SmartSuggestion] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return [] }

        return IntentPresets.all
            .filter { $0.matchesSearch(query) }
            .prefix(5)
            .map { SmartSuggestion(label: $0.name ?? "Optimize", request: $0) }
    }

    private var visibleItems: [SmartSuggestion] {
        searchText.isEmpty ? suggestions : searchResults
    }

    // MARK: - Body

    var body: some View {
        ZStack {
            Rectangle()
                .fill(DS.Colors.overlayBackground.opacity(DS.Opacity.strongFill))
                .contentShape(Rectangle())
                .onTapGesture { onDismiss() }

            card
                .padding(.horizontal, DS.Spacing.md)
                .padding(.top, DS.Spacing.xl)
                .frame(maxHeight: .infinity, alignment: .top)

            shortcuts
        }
        .onAppear {
            if let seed = seedPreset {
                composedRequest = seed
                showPowerMode = true
            }
            isSearchFocused = true
            refreshPreview()
        }
        .onDisappear {
            dryRunTask?.cancel()
            workingTask?.cancel()
        }
    }

    // MARK: - Card

    private var card: some View {
        VStack(spacing: 0) {
            searchField
            SkinSeparator()
            content
        }
        .skinPlatter(skin)
        // Command palette is a modal surface floating above the popover body
        // — z2 plane so its depth reads against the z1 cards underneath.
        .skinPlatterDepth(skin, level: .z2)
        .onKeyPress(.upArrow) { move(-1); return .handled }
        .onKeyPress(.downArrow) { move(1); return .handled }
        .transition(reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity))
    }

    private func move(_ delta: Int) {
        let count = visibleItems.count
        guard count > 0 else { return }
        selectedIndex = max(0, min(count - 1, selectedIndex + delta))
    }

    // MARK: - Search Field

    private var searchField: some View {
        HStack(spacing: DS.Spacing.sm) {
            Image(systemName: phaseIcon)
                .font(.body)
                .foregroundStyle(phaseColor)
                .symbolEffect(.pulse, isActive: isBusy)
                .frame(width: 18)

            TextField(placeholder, text: $searchText)
                .textFieldStyle(.plain)
                .font(.headline)
                .focused($isSearchFocused)
                .disabled(isBusy)
                .onSubmit { handleSubmit() }
                .onChange(of: searchText) {
                    selectedIndex = 0
                    composedRequest = nil
                    showPowerMode = false
                }

            if !isBusy {
                Button {
                    if searchText.isEmpty {
                        onDismiss()
                    } else {
                        searchText = ""
                        isSearchFocused = true
                    }
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.footnote)
                        .foregroundStyle(skin.resolvedTextTertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, DS.Spacing.md)
        .padding(.vertical, DS.Spacing.md)
    }

    private var phaseIcon: String {
        switch phase {
        case .picking: "sparkles"
        case .working: "hourglass"
        case .applied: "checkmark.circle.fill"
        case .failed: "exclamationmark.triangle.fill"
        }
    }

    private var phaseColor: Color {
        switch phase {
        case .picking, .working: skin.accentColor
        case .applied: skin.resolvedSuccessColor
        case .failed: skin.resolvedWarningColor
        }
    }

    private var isBusy: Bool {
        if case .working = phase { return true }
        return false
    }

    private var placeholder: String {
        if seedEvent != nil { return "What to do with this event?" }
        if seedSlotMinutes != nil { return "Fill this slot\u{2026}" }
        return "What do you need?"
    }

    // MARK: - Content

    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                switch phase {
                case .picking: pickingContent
                case .working(let label, let intentName): statusView(label, intentName: intentName)
                case .applied(let events, let resolutions): appliedView(events, resolutions: resolutions)
                case .failed(let message, let resolutions): failedView(message, resolutions: resolutions)
                }
            }
            .padding(.vertical, DS.Spacing.sm)
        }
        .frame(maxHeight: showPowerMode ? 440 : 300)
        .scrollContentBackground(.hidden)
    }

    // MARK: - Picking (Simple Mode)

    @ViewBuilder
    private var pickingContent: some View {
        // Burnout Rescue
        if let checkInService = optimizerService.energyCheckInService,
           let energy = checkInService.predictEnergy(atHour: Calendar.current.component(.hour, from: Date())),
           energy <= 2.5, searchText.isEmpty {
            Button {
                var newReq = OptimizationRequest()
                newReq.add(.limitToTopTasks(count: 2))
                newReq.add(.protectLunch(start: 12, end: 14))
                newReq.add(.breakEvery(workMinutes: 45, breakMinutes: 15))
                newReq.add(.noEventsAfter(hour: 18))
                
                composedRequest = newReq
                showPowerMode = true
                runRequest(newReq)
            } label: {
                HStack(spacing: DS.Spacing.sm) {
                    Image(systemName: "lifepreserver.fill")
                        .font(.body)
                        .foregroundStyle(.red) // Highlight color
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Unload my day (Burnout Rescue)")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.red)
                        Text("Energy level is low. Defer everything except the 2 top tasks.")
                            .font(.footnote)
                            .foregroundStyle(.red.opacity(0.8))
                    }
                }
                .padding(.vertical, DS.Spacing.sm)
                .padding(.horizontal, DS.Spacing.sm)
                .background(Color.red.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)
            .padding(.horizontal, DS.Spacing.sm)
            .padding(.bottom, DS.Spacing.xs)
        }

        // Smart suggestions — the main UI
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(visibleItems.enumerated()), id: \.element.id) { index, item in
                suggestionRow(item, index: index)
            }

            if visibleItems.isEmpty && !searchText.isEmpty {
                // No matches — will go to AI on Enter
                HStack(spacing: DS.Spacing.sm) {
                    Image(systemName: "sparkles")
                        .font(.body)
                        .foregroundStyle(skin.accentColor)
                        .frame(width: 18)
                    Text("Ask AI: \u{201C}\(searchText)\u{201D}")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(skin.resolvedTextPrimary)
                }
                .padding(.vertical, DS.Spacing.sm)
                .padding(.horizontal, DS.Spacing.md)
            }
        }
        .padding(.horizontal, DS.Spacing.sm)

        // Power mode (intent composer) — hidden by default
        if showPowerMode, let request = composedRequest {
            SkinSeparator()
            powerModeComposer(request)
        }

        // Footer — Birman: label describes the specific action, not a generic verb.
        HStack(spacing: DS.Spacing.md) {
            hint("↵", selectedIndex < visibleItems.count
                 ? visibleItems[selectedIndex].label
                 : (searchText.isEmpty ? "run" : "Ask AI"))
            if visibleItems.count > 1 {
                hint("↑↓", "select")
            }
            if !showPowerMode {
                hint("⌥", "customize")
            }
            Spacer()
            Button { onDismiss() } label: {
                hint("esc", "close")
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, DS.Spacing.md)
        .padding(.top, DS.Spacing.sm)
        .padding(.bottom, DS.Spacing.xs)
    }

    // MARK: - Suggestion Row

    private func suggestionRow(_ item: SmartSuggestion, index: Int) -> some View {
        let isSelected = index == selectedIndex
        let isTop = index == 0 && searchText.isEmpty

        return Button {
            runRequest(item.request)
        } label: {
            HStack(spacing: DS.Spacing.sm) {
                // Concrete preview for top suggestion
                VStack(alignment: .leading, spacing: isTop ? 2 : 1) {
                    Text(item.label)
                        .font(isTop ? .headline.weight(.semibold) : .subheadline.weight(isSelected ? .semibold : .medium))
                        .foregroundStyle(skin.resolvedTextPrimary)
                        .lineLimit(1)

                    if isTop, let preview = dryRunPreview {
                        Text(preview)
                            .font(.footnote)
                            .foregroundStyle(skin.accentColor.opacity(0.85))
                            .lineLimit(1)
                    }
                }

                Spacer()

                // Power mode toggle (only on selected)
                if isSelected {
                    Button {
                        withAnimation(DS.Animation.quick) {
                            composedRequest = item.request
                            showPowerMode.toggle()
                        }
                    } label: {
                        Image(systemName: "slider.horizontal.3")
                            .font(.footnote)
                            .foregroundStyle(skin.resolvedTextTertiary)
                            .frame(width: 20, height: 20)
                    }
                    .buttonStyle(.plain)
                    .help("Customize")
                }
            }
            .padding(.vertical, isTop ? DS.Spacing.sm : DS.Spacing.xs)
            .padding(.horizontal, DS.Spacing.sm)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(
            RoundedRectangle(cornerRadius: DS.Size.subtleCornerRadius)
                .fill(isTop
                    ? skin.accentColor.opacity(isSelected ? 0.18 : 0.08)
                    : (isSelected ? skin.accentColor.opacity(0.14) : .clear))
        )
        .onHover { if $0 { selectedIndex = index } }
    }

    // MARK: - Power Mode (Progressive Disclosure)

    @State private var composerPreview: String? = nil
    @State private var composerPreviewTask: Task<Void, Never>? = nil

    /// Advanced composer — only shown when user explicitly opts in.
    /// This is where the 65 intents live. But the user chose to see them.
    private func powerModeComposer(_ request: OptimizationRequest) -> some View {
        // Read through the long-lived cache so SwiftUI body re-evaluations
        // (every chip toggle re-renders this view) hit a warm graph
        // instead of rebuilding 65-intent auto-resolution per keystroke.
        let graph = optimizerService.optimizer.intentGraphCache.graph(for: request.intents)
        let phases = graph.intentsByPhase()
        let suggested = graph.suggestedIntents()

        return VStack(alignment: .leading, spacing: DS.Spacing.sm) {
            // Active intents grouped by phase
            ForEach(phases, id: \.phase) { group in
                VStack(alignment: .leading, spacing: 2) {
                    Text(group.phase.displayName.uppercased())
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(skin.resolvedTextTertiary)
                        .tracking(0.5)

                    FlowLayout(spacing: DS.Spacing.xs) {
                        ForEach(group.intents) { node in
                            chip(
                                node.intent.label,
                                active: true,
                                dimmed: node.isAutoResolved
                            ) {
                                guard !node.isAutoResolved else { return }
                                var m = request
                                m.toggle(node.intent)
                                updateComposed(m)
                            }
                        }
                    }
                }
            }

            // Suggested
            if !suggested.isEmpty {
                FlowLayout(spacing: DS.Spacing.xs) {
                    ForEach(Array(suggested.prefix(6).enumerated()), id: \.offset) { _, intent in
                        chip(intent.label, active: false) {
                            var m = request
                            m.add(intent)
                            updateComposed(m)
                        }
                    }
                }
            }

            // Tunable parameters
            ForEach(Array(request.intents.enumerated()), id: \.offset) { idx, intent in
                parameterSlider(intent, at: idx, in: request)
            }

            // Conflicts
            if !conflicts.isEmpty {
                ForEach(conflicts) { conflict in
                    VStack(alignment: .leading, spacing: DS.Spacing.xs) {
                        HStack(spacing: DS.Spacing.xs) {
                            Image(systemName: conflict.severity == .error ? "xmark.circle.fill" : "info.circle.fill")
                                .font(.footnote)
                                .foregroundStyle(conflict.severity == .error ? skin.resolvedDestructiveColor : skin.resolvedTextTertiary)
                            Text(conflict.message)
                                .font(.footnote)
                                .foregroundStyle(skin.resolvedTextSecondary)
                        }
                        
                        if !conflict.resolutions.isEmpty {
                            FlowLayout(spacing: DS.Spacing.xs) {
                                ForEach(conflict.resolutions) { res in
                                    Button(res.title) {
                                        var newReq = request
                                        newReq.merge(res.modifier)
                                        updateComposed(newReq)
                                    }
                                    .buttonStyle(.action(role: .secondary, size: .compact))
                                }
                            }
                            .padding(.leading, 20)
                        }
                    }
                }
            }

            // Preview
            if let preview = composerPreview {
                HStack(spacing: DS.Spacing.xs) {
                    Image(systemName: "eye.fill")
                        .font(.footnote)
                        .foregroundStyle(skin.accentColor.opacity(0.6))
                    Text(preview)
                        .font(.footnote)
                        .foregroundStyle(skin.accentColor.opacity(0.8))
                }
            }
        }
        .padding(DS.Spacing.sm)
        .onAppear { refreshComposerPreview(request) }
    }

    @ViewBuilder
    private func parameterSlider(_ intent: ScheduleIntent, at idx: Int, in request: OptimizationRequest) -> some View {
        switch intent {
        case .focusBlock(let m, _):
            stepper("Focus", value: m, range: 30...240, step: 15, unit: "min") { v in
                var r = request; r.intents[idx] = .focusBlock(minutes: v); updateComposed(r)
            }
        case .noEventsBefore(let h):
            stepper("Start after", value: h, range: 6...14, step: 1, unit: ":00") { v in
                var r = request; r.intents[idx] = .noEventsBefore(hour: v); updateComposed(r)
            }
        case .noEventsAfter(let h):
            stepper("End by", value: h, range: 14...22, step: 1, unit: ":00") { v in
                var r = request; r.intents[idx] = .noEventsAfter(hour: v); updateComposed(r)
            }
        case .maxMeetings(let n):
            stepper("Max meetings", value: n, range: 0...10, step: 1, unit: "/day") { v in
                var r = request; r.intents[idx] = .maxMeetings(perDay: v); updateComposed(r)
            }
        default:
            EmptyView()
        }
    }

    private func stepper(_ label: String, value: Int, range: ClosedRange<Int>, step: Int, unit: String, onChange: @escaping (Int) -> Void) -> some View {
        HStack(spacing: DS.Spacing.sm) {
            Text(label)
                .font(.footnote)
                .foregroundStyle(skin.resolvedTextSecondary)
                .frame(width: 70, alignment: .leading)

            Button { onChange(max(range.lowerBound, value - step)) } label: {
                Image(systemName: "minus").font(.footnote.weight(.bold)).frame(width: 18, height: 18)
            }.buttonStyle(.plain)

            Text("\(value)\(unit)")
                .font(.footnote.monospacedDigit().weight(.medium))
                .frame(minWidth: 44)

            Button { onChange(min(range.upperBound, value + step)) } label: {
                Image(systemName: "plus").font(.footnote.weight(.bold)).frame(width: 18, height: 18)
            }.buttonStyle(.plain)

            Spacer()
        }
    }

    private func updateComposed(_ request: OptimizationRequest) {
        composedRequest = request
        conflicts = IntentConflictDetector.analyze(request.intents)
        refreshComposerPreview(request)
    }

    private func refreshComposerPreview(_ request: OptimizationRequest) {
        composerPreviewTask?.cancel()
        guard request.isCreative || request.findSlotOnly else {
            composerPreview = request.intents.prefix(3).map(\.label).joined(separator: " + ")
            return
        }
        composerPreviewTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            var w = request; w.speed = .quick; w.maxScenarios = 1
            let genes = await optimizerService.executeDryRun(w, reminderService: reminderService)
            guard !Task.isCancelled else { return }
            if let genes, !genes.isEmpty {
                let fmt = DateFormatter()
                fmt.setLocalizedDateFormatFromTemplate("H:mm")
                composerPreview = genes.prefix(2).map {
                    "\($0.title) \(fmt.string(from: $0.startTime))–\(fmt.string(from: $0.endTime))"
                }.joined(separator: " · ")
            } else { composerPreview = "No slot found" }
        }
    }

    private func chip(_ label: String, active: Bool, dimmed: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 3) {
                if dimmed {
                    Image(systemName: "link").font(.system(size: 7, weight: .semibold))
                }
                Text(label).font(.footnote.weight(.medium))
                if active && !dimmed {
                    Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
                }
            }
            .foregroundStyle(dimmed ? skin.resolvedTextTertiary : active ? .white : skin.resolvedTextPrimary)
            .padding(.horizontal, DS.Spacing.sm)
            .padding(.vertical, 4)
            .background(
                Capsule().fill(dimmed ? skin.accentColor.opacity(0.05) : active ? skin.accentColor : skin.accentColor.opacity(0.10))
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Status Views

    private func statusView(_ label: String, intentName: String?) -> some View {
        VStack(spacing: DS.Spacing.sm) {
            Image(systemName: "hourglass")
                .font(.title3)
                .foregroundStyle(skin.accentColor)
                .symbolEffect(.pulse, isActive: true)
            if let intentName, !intentName.isEmpty {
                Text(intentName)
                    .font(.subheadline.weight(.semibold))
                    .multilineTextAlignment(.center)
            }
            Text(label)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(skin.resolvedTextSecondary)

            Button("Cancel") { cancelWorking() }
                .buttonStyle(.action(role: .secondary, size: .compact))
                .padding(.top, DS.Spacing.xs)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, DS.Spacing.xxl)
    }

    private func cancelWorking() {
        workingTask?.cancel()
        workingTask = nil
        Haptics.tap()
        withAnimation(DS.Animation.quick) { phase = .picking }
    }

    private func appliedView(_ events: [EventInfo], resolutions: [ActionableResolution]) -> some View {
        VStack(spacing: DS.Spacing.sm) {
            Image(systemName: "checkmark.circle.fill")
                .font(.title3)
                .foregroundStyle(skin.resolvedSuccessColor)
            ForEach(events) { info in
                HStack(spacing: DS.Spacing.xs) {
                    Text(info.title).font(.subheadline.weight(.medium))
                    Text(info.timeRange).font(.subheadline.monospacedDigit()).foregroundStyle(skin.accentColor)
                }
            }
            if let notice = appliedNotice {
                Text(notice)
                    .font(.footnote)
                    .foregroundStyle(DS.Colors.textTertiary)
            }
            
            if !resolutions.isEmpty {
                VStack(spacing: DS.Spacing.xs) {
                    ForEach(resolutions) { res in
                        Button(res.title) {
                            var newReq = lastExecutedRequest ?? composedRequest ?? OptimizationRequest()
                            newReq.merge(res.modifier)
                            runRequest(newReq)
                        }
                        .buttonStyle(.action(role: .secondary, size: .compact))
                    }
                }
                .padding(.top, DS.Spacing.sm)
            }

            Button("Undo") {
                optimizerService.undoLast(reminderService: reminderService)
                let resolutions = [
                    ActionableResolution(title: "Too dense", modifier: OptimizationRequest(.addBuffer(minutes: 15))),
                    ActionableResolution(title: "Too late", modifier: OptimizationRequest(.noEventsAfter(hour: 18))),
                    ActionableResolution(title: "Move to tomorrow", modifier: OptimizationRequest(.horizon(.tomorrow)))
                ]
                withAnimation(DS.Animation.quick) {
                    phase = .failed(message: "Why did you undo?", resolutions: resolutions)
                }
            }
            .buttonStyle(.action(role: .secondary, size: .compact))
            .padding(.top, DS.Spacing.xs)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, DS.Spacing.xl)
    }

    private func failedView(_ message: String, resolutions: [ActionableResolution]) -> some View {
        VStack(spacing: DS.Spacing.md) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.title3)
                .foregroundStyle(skin.resolvedWarningColor)
            Text(message)
                .font(.subheadline.weight(.medium))
                .multilineTextAlignment(.center)
            
            if !resolutions.isEmpty {
                VStack(spacing: DS.Spacing.xs) {
                    ForEach(resolutions) { res in
                        Button(res.title) {
                            var newReq = lastExecutedRequest ?? composedRequest ?? OptimizationRequest()
                            newReq.merge(res.modifier)
                            runRequest(newReq)
                        }
                        .buttonStyle(.action(role: .secondary, size: .compact))
                    }
                }
                .padding(.top, DS.Spacing.sm)
            }

            HStack(spacing: DS.Spacing.sm) {
                Button("Back") {
                    withAnimation(DS.Animation.quick) { phase = .picking }
                }
                .font(.footnote.weight(.medium))
                .foregroundStyle(skin.accentColor)
                .buttonStyle(.plain)
                
                Button("Close") { onDismiss() }
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(skin.resolvedTextSecondary)
                    .buttonStyle(.plain)
            }
            .padding(.top, resolutions.isEmpty ? 0 : DS.Spacing.sm)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, DS.Spacing.xxl)
    }

    // MARK: - Actions

    private func handleSubmit() {
        if let composed = composedRequest, showPowerMode {
            runRequest(composed)
        } else if !visibleItems.isEmpty {
            runRequest(visibleItems[min(selectedIndex, visibleItems.count - 1)].request)
        } else if !searchText.isEmpty {
            askAI(searchText)
        }
    }

    private func runRequest(_ request: OptimizationRequest) {
        if IntentConflictDetector.hasErrors(request.intents) {
            conflicts = IntentConflictDetector.analyze(request.intents)
            showPowerMode = true
            composedRequest = request
            return
        }

        Haptics.tap()
        var working = request
        if let seedEvent { working = working.withEventContext(seedEvent) }
        lastExecutedRequest = request

        let label = working.findSlotOnly ? "Scheduling\u{2026}" : "Optimizing\u{2026}"
        phase = .working(label, intentName: working.name)

        workingTask?.cancel()
        workingTask = Task {
            let result = await optimizerService.executeRequest(working, reminderService: reminderService)
            if Task.isCancelled { return }
            await MainActor.run {
                workingTask = nil
                switch result {
                case .success, .partialSuccess:
                    guard !optimizerService.scenarios.isEmpty else {
                        phase = .failed(message: "No valid schedule found", resolutions: [])
                        return
                    }
                    optimizerService.applyScenario(at: 0, to: reminderService)
                    let fmt = DateFormatter()
                    fmt.setLocalizedDateFormatFromTemplate("H:mm")
                    let scenario = optimizerService.scenarios[0]
                    let infos = scenario.activeGenes.prefix(3).map { g in
                        EventInfo(id: g.eventId, title: g.title,
                                  timeRange: "\(fmt.string(from: g.startTime))–\(fmt.string(from: g.endTime))")
                    }
                    let resList: [ActionableResolution]
                    if case .partialSuccess(_, let warnings, let resolutions) = result {
                        appliedNotice = warnings.first
                        resList = resolutions
                    } else {
                        resList = []
                    }
                    phase = .applied(infos, resolutions: resList)
                    onApplied(request) { optimizerService.undoLast(reminderService: reminderService) }
                    Task { @MainActor in
                        if resList.isEmpty {
                            try? await Task.sleep(for: .seconds(3))
                            if case .applied = phase {
                                onDismiss()
                            }
                        }
                    }
                case .noEventsToOptimize:
                    phase = .failed(message: "Add tasks first", resolutions: [])
                case .infeasible(let reason, _, let resolutions):
                    phase = .failed(message: reason, resolutions: resolutions)
                }
            }
        }
    }

    private func askAI(_ prompt: String) {
        guard agentService.isConfigured else {
            phase = .failed(message: "Add API key in Settings → Assistant", resolutions: [])
            return
        }
        Haptics.tap()
        phase = .working("Thinking\u{2026}", intentName: prompt)
        workingTask?.cancel()
        workingTask = Task {
            let result = await agentService.generateRequest(from: prompt)
            if Task.isCancelled { return }
            await MainActor.run {
                workingTask = nil
                switch result {
                case .success(let req): runRequest(req)
                case .failure(let err): phase = .failed(message: err.localizedDescription, resolutions: [])
                }
            }
        }
    }

    /// Narrow working hours to the hour boundaries of the seeded slot.
    private func pinToSlot(_ request: inout OptimizationRequest) {
        guard let s = seedSlotStart, let e = seedSlotEnd else { return }
        let cal = Calendar.current
        let startHour = cal.component(.hour, from: s)
        let endHour = min(cal.component(.hour, from: e) + (cal.component(.minute, from: e) > 0 ? 1 : 0), 24)
        request.add(.workingHours(start: startHour, end: max(endHour, startHour + 1)))
    }

    private func refreshPreview() {
        dryRunTask?.cancel()
        guard let top = visibleItems.first else { return }
        guard top.request.isCreative || top.request.findSlotOnly else { return }
        dryRunTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled else { return }
            var w = top.request; w.speed = .quick; w.maxScenarios = 1
            let genes = await optimizerService.executeDryRun(w, reminderService: reminderService)
            guard !Task.isCancelled else { return }
            if let genes, !genes.isEmpty {
                let fmt = DateFormatter()
                fmt.setLocalizedDateFormatFromTemplate("H:mm")
                dryRunPreview = genes.prefix(2).map {
                    "\($0.title) \(fmt.string(from: $0.startTime))–\(fmt.string(from: $0.endTime))"
                }.joined(separator: " · ")
            }
        }
    }

    private func hint(_ key: String, _ label: String) -> some View {
        HStack(spacing: DS.Spacing.xs) {
            Text(key)
                .font(.footnote.monospaced())
                .foregroundStyle(skin.resolvedTextSecondary)
                .padding(.horizontal, DS.Spacing.xs)
                .padding(.vertical, DS.Spacing.xxs)
                .background(RoundedRectangle(cornerRadius: DS.Spacing.xs).strokeBorder(skin.resolvedTextTertiary.opacity(0.35), lineWidth: 0.5))
            Text(label)
                .font(.footnote)
                .foregroundStyle(skin.resolvedTextTertiary)
        }
    }

    // MARK: - Keyboard

    @ViewBuilder
    private var shortcuts: some View {
        Group {
            Button("Power mode") {
                withAnimation(DS.Animation.quick) {
                    if !showPowerMode, let top = visibleItems.first {
                        composedRequest = top.request
                    }
                    showPowerMode.toggle()
                }
            }
            .keyboardShortcut("e", modifiers: .option)
            Button("Close") { onDismiss() }
                .keyboardShortcut(.cancelAction)
        }
        .opacity(0).frame(width: 0, height: 0).accessibilityHidden(true)
    }
}
