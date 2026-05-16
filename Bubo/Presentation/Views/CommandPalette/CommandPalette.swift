import SwiftUI
import BuboDomain
import BuboOptimizer

// MARK: - Command Palette
//
// Design (Birman):
// - "Let the machine sweat": user says WHAT, system figures out HOW
// - 3-5 smart suggestions based on current schedule context
// - Free text → AI composes intents automatically
// - Enter runs instantly, Esc closes, undo via toast
// - No categories, no phases, no "ACTIVE/SUGGESTED/MORE"
// - Power mode (⌥) reveals intent composer for advanced users
// - One action, one result, one undo

struct CommandPalette: View {
    @Environment(\.activeSkin) var skin
    @Environment(\.accessibilityReduceMotion) var reduceMotion

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
    /// Cross-cutting #2: open the event detail for a search result. nil
    /// = the palette never surfaces event matches. Wired from
    /// `MenuBarView` to `navigation = .detail(event)` so the palette
    /// doubles as Bubo's spotlight for events without a separate
    /// search bar (§4 — don't add modes).
    var onOpenEvent: ((CalendarEvent) -> Void)? = nil

    // MARK: - State

    @State var searchText = ""
    @State var selectedIndex = 0
    @State var phase: Phase = .picking
    @State var dryRunPreview: String? = nil
    @State var dryRunTask: Task<Void, Never>? = nil
    @State var showPowerMode = false
    @State var composedRequest: OptimizationRequest? = nil
    @State var lastExecutedRequest: OptimizationRequest? = nil
    @State var conflicts: [IntentConflictDetector.Conflict] = []
    @State var appliedNotice: String? = nil
    @State var workingTask: Task<Void, Never>? = nil
    /// Disclosure state for the «All intents» catch-all section. False
    /// by default so the palette stays glanceable on first open; the
    /// user expands it explicitly when they want the full preset
    /// catalogue. Birman: «don't show 50 options at once where
    /// six cover 90% of cases».
    @State var showAllIntents: Bool = false
    @State var composerPreview: String? = nil
    @State var composerPreviewTask: Task<Void, Never>? = nil
    @FocusState var isSearchFocused: Bool

    enum Phase: Equatable {
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
                label: "Focus \(minutes)\u{00A0}min",
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

    var visibleItems: [SmartSuggestion] {
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
                .font(DS.Typography.body(skin: skin))
                .foregroundStyle(phaseColor)
                .symbolEffect(.pulse, isActive: isBusy)
                .frame(width: 18)

            TextField(placeholder, text: $searchText)
                .textFieldStyle(.plain)
                .font(DS.Typography.headline(skin: skin))
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

    /// Picking-phase body — restructured into a clear vertical flow:
    ///
    ///   1. Burnout Rescue       (urgent, energy-driven, top of stack)
    ///   2. RIGHT NOW            (dynamic ranker suggestions)
    ///   3. PLAN TODAY           (6 outcome-named presets)
    ///   4. ALL INTENTS          (collapsed-by-default catalogue)
    ///   5. Power-mode composer  (when active)
    ///
    /// Each section is independently gated: search input collapses
    /// 2-4 in favour of the search results / AI fallback; a seed
    /// context (event/task/slot) drives only the focused suggestions
    /// in section 2 since the user is already in a specific scope.
    /// Power mode (5) replaces the «PLAN TODAY» section to keep the
    /// surface area finite.
    ///
    /// Birman: «hierarchy from the nature of the data» — urgent rescue is on
    /// top, common day-scope recipes are visible by default, the
    /// long tail of intents is one disclosure away.
    @ViewBuilder
    private var pickingContent: some View {
        if shouldShowBurnoutRescue {
            burnoutRescueButton
        }

        rightNowSection

        // Cross-cutting #2: Events search. Matches today + future
        // events by title / location while the user types, surfacing
        // them as a separate section below the dynamic ranker
        // suggestions. Selecting a row opens the event detail —
        // turning ⌘K into Bubo's spotlight without adding a
        // dedicated search bar (§4 — don't add modes).
        if !matchingEvents.isEmpty, onOpenEvent != nil {
            SkinSeparator()
            eventsSection
        }

        if searchText.isEmpty,
           seedEvent == nil, seedTask == nil, seedSlotMinutes == nil,
           !showPowerMode {
            SkinSeparator()
            planTodayPresets

            SkinSeparator()
            allIntentsSection
        }

        // Power mode (intent composer) — replaces Plan today / All
        // intents when active so we don't stack three full-width
        // sections in one popover.
        if showPowerMode, let request = composedRequest {
            SkinSeparator()
            powerModeComposer(request)
        }

        footer
    }

    /// Footer with keyboard hints. Birman: label describes the specific
    /// action, not a generic verb.
    @ViewBuilder
    private var footer: some View {
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

    /// Whether the burnout-rescue card should appear at the top of the
    /// picking content — surfaces when the energy-check-in service has
    /// recent data showing a low energy reading at the current hour
    /// AND the search field is empty (typing replaces the section).
    private var shouldShowBurnoutRescue: Bool {
        guard searchText.isEmpty,
              let checkInService = optimizerService.energyCheckInService,
              let energy = checkInService.predictEnergy(
                atHour: Calendar.current.component(.hour, from: Date())
              ) else { return false }
        return energy <= 2.5
    }

    @ViewBuilder
    private var burnoutRescueButton: some View {
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
                    .font(DS.Typography.body(skin: skin))
                    .foregroundStyle(skin.resolvedDestructiveColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Unload my day (Burnout Rescue)")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(skin.resolvedDestructiveColor)
                    Text("Energy level is low. Defer everything except the 2 top tasks.")
                        .font(.footnote)
                        .foregroundStyle(skin.resolvedDestructiveColor.opacity(DS.Opacity.overlayDark))
                }
            }
            .padding(.vertical, DS.Spacing.sm)
            .padding(.horizontal, DS.Spacing.sm)
            .background(skin.resolvedDestructiveColor.opacity(DS.Opacity.lightFill))
            .clipShape(RoundedRectangle(cornerRadius: DS.Size.subtleCornerRadius))
        }
        .buttonStyle(.plain)
        .padding(.horizontal, DS.Spacing.sm)
        .padding(.bottom, DS.Spacing.xs)
    }

    /// Dynamic ranker output (or search results, or AI fallback). The
    /// «RIGHT NOW» section header is shown only when the section
    /// reflects current-context suggestions (search empty, no seed
    /// context, ranker produced items). Search results and AI
    /// fallback render below the same `VStack` without the section
    /// header so the user reads them as «direct response to my
    /// query», not «system observation».
    @ViewBuilder
    private var rightNowSection: some View {
        VStack(alignment: .leading, spacing: 2) {
            if searchText.isEmpty,
               !visibleItems.isEmpty,
               seedEvent == nil, seedTask == nil, seedSlotMinutes == nil {
                Text("Right now")
                    .font(DS.Typography.label(skin: skin))
                    .tracking(0.5)
                    .textCase(.uppercase)
                    .foregroundStyle(skin.resolvedTextTertiary)
                    .padding(.horizontal, DS.Spacing.md)
                    .padding(.top, DS.Spacing.xxs)
                    .padding(.bottom, DS.Spacing.xxs)
            }

            ForEach(Array(visibleItems.enumerated()), id: \.element.id) { index, item in
                suggestionRow(item, index: index)
            }

            if visibleItems.isEmpty && !searchText.isEmpty {
                HStack(spacing: DS.Spacing.sm) {
                    Image(systemName: "sparkles")
                        .font(DS.Typography.body(skin: skin))
                        .foregroundStyle(skin.accentColor)
                        .frame(width: 18)
                    Text("Ask AI: \u{201C}\(searchText)\u{201D}")
                        .font(.subheadline.weight(.regular))
                        .foregroundStyle(skin.resolvedTextPrimary)
                }
                .padding(.vertical, DS.Spacing.sm)
                .padding(.horizontal, DS.Spacing.md)
            }
        }
        .padding(.horizontal, DS.Spacing.sm)
    }

    // MARK: - Events Search (Cross-cutting #2)

    /// Cross-cutting #2 cap. Surfacing more than 5 events would crowd
    /// the picker; the ones that don't fit teach the user to refine
    /// the query.
    private static let maxEventResults = 5

    /// Cross-cutting #2: case-insensitive substring match on title +
    /// location. Limited to upcoming + today's events so we don't
    /// turn the palette into an archive search. Returns up to
    /// `maxEventResults` items, sorted chronologically.
    private var matchingEvents: [CalendarEvent] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty, query.count >= 2 else { return [] }

        let cal = Calendar.current
        let startOfToday = cal.startOfDay(for: Date())

        return reminderService.allEvents
            .filter { event in
                guard event.endDate >= startOfToday else { return false }
                if event.title.lowercased().contains(query) { return true }
                if let location = event.location, location.lowercased().contains(query) { return true }
                return false
            }
            .sorted { $0.startDate < $1.startDate }
            .prefix(Self.maxEventResults)
            .map { $0 }
    }

    @ViewBuilder
    private var eventsSection: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: DS.Spacing.xs) {
                Text("Events")
                    .font(DS.Typography.label(skin: skin))
                    .tracking(0.5)
                    .textCase(.uppercase)
                    .foregroundStyle(skin.resolvedTextTertiary)
                Spacer(minLength: 0)
                Text("\(matchingEvents.count)")
                    .font(DS.Typography.machineHint)
                    .foregroundStyle(skin.resolvedTextTertiary)
            }
            .padding(.horizontal, DS.Spacing.md)
            .padding(.top, DS.Spacing.xxs)
            .padding(.bottom, DS.Spacing.xxs)

            ForEach(matchingEvents) { event in
                Button {
                    Haptics.tap()
                    onOpenEvent?(event)
                    onDismiss()
                } label: {
                    HStack(alignment: .top, spacing: DS.Spacing.sm) {
                        Image(systemName: "calendar")
                            .font(DS.Typography.body(skin: skin))
                            .foregroundStyle(skin.accentColor)
                            .frame(width: 18)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(event.title)
                                .font(.subheadline.weight(.regular))
                                .foregroundStyle(skin.resolvedTextPrimary)
                                .lineLimit(1)
                                .truncationMode(.tail)
                            Text("\(event.formattedDate) \u{00B7} \(event.formattedTimeRange)")
                                .font(DS.Typography.machineHint)
                                .foregroundStyle(skin.resolvedTextTertiary)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, DS.Spacing.xxs)
                    .padding(.horizontal, DS.Spacing.md)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, DS.Spacing.sm)
    }

    /// «ALL INTENTS» — the long-tail catalogue, collapsed by default.
    /// The disclosure header carries a «Show ▾» / «Hide ▴» chevron
    /// and the count so the user knows what they're hiding/revealing.
    /// When expanded, every entry from `IntentPresets.all` renders as
    /// a tappable row using the same suggestion-row visuals as the
    /// «RIGHT NOW» section above. Birman: «don't show 50 options
    /// at once» — power users find them, casual users don't trip over
    /// them.
    @ViewBuilder
    private var allIntentsSection: some View {
        let allRequests = IntentPresets.all
        VStack(alignment: .leading, spacing: 2) {
            Button {
                Haptics.tap()
                withAnimation(DS.Animation.quick) {
                    showAllIntents.toggle()
                }
            } label: {
                HStack(spacing: DS.Spacing.xs) {
                    Text("All intents")
                        .font(DS.Typography.label(skin: skin))
                        .tracking(0.5)
                        .textCase(.uppercase)
                        .foregroundStyle(skin.resolvedTextTertiary)
                    Spacer(minLength: 0)
                    Text("\(allRequests.count)")
                        .font(DS.Typography.machineHint)
                        .foregroundStyle(skin.resolvedTextTertiary)
                    Image(systemName: showAllIntents ? "chevron.up" : "chevron.down")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(skin.resolvedTextTertiary)
                }
                .padding(.horizontal, DS.Spacing.md)
                .padding(.vertical, DS.Spacing.xs)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(showAllIntents
                  ? "Hide the full preset catalogue"
                  : "Show every preset (\(allRequests.count) total)")

            if showAllIntents {
                ForEach(Array(allRequests.enumerated()), id: \.offset) { _, request in
                    Button {
                        Haptics.tap()
                        runRequest(request)
                    } label: {
                        HStack(spacing: DS.Spacing.sm) {
                            Image(systemName: "circle.dotted")
                                .font(DS.Typography.body(skin: skin))
                                .foregroundStyle(skin.resolvedTextTertiary)
                                .frame(width: 18)
                            Text(request.name ?? "Optimize")
                                .font(.subheadline)
                                .foregroundStyle(skin.resolvedTextPrimary)
                            Spacer(minLength: 0)
                        }
                        .padding(.vertical, DS.Spacing.xxs)
                        .padding(.horizontal, DS.Spacing.md)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.bottom, DS.Spacing.xs)
    }

    // MARK: - Plan-today presets

    /// The six outcome-named day-scope recipes from `IntentPresets`.
    /// Mirrors the `SmartActions` calm-state popover so the canonical
    /// «Plan day…» actions live both inline (next to the backlog) and
    /// in the global ⌘K palette. Calling either path goes through the
    /// same `runRequest` pipeline so toast / undo / reasoning surface
    /// fire identically.
    @ViewBuilder
    private var planTodayPresets: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Plan today")
                .font(DS.Typography.label(skin: skin))
                .tracking(0.5)
                .textCase(.uppercase)
                .foregroundStyle(skin.resolvedTextTertiary)
                .padding(.horizontal, DS.Spacing.md)
                .padding(.top, DS.Spacing.xs)
                .padding(.bottom, DS.Spacing.xxs)

            presetButton(icon: "wand.and.stars",     label: "Organize today",        request: .organizeDay)
            presetButton(icon: "brain.head.profile", label: "Find 2 h focus",        request: .findFocus(minutes: 120, period: .morning))
            presetButton(icon: "leaf",               label: "Low energy day",        request: .lowEnergyDay)
            presetButton(icon: "timer",              label: "Schedule pomodoro day", request: .pomodoroBlock)
            presetButton(icon: "person.2",           label: "Batch meetings",        request: .batchMeetingsPreset)
            presetButton(icon: "calendar",           label: "Plan whole week",       request: .planWeek)
        }
        .padding(.bottom, DS.Spacing.xs)
    }

    @ViewBuilder
    private func presetButton(icon: String, label: String, request: OptimizationRequest) -> some View {
        Button {
            Haptics.tap()
            runRequest(request)
        } label: {
            HStack(spacing: DS.Spacing.sm) {
                Image(systemName: icon)
                    .font(DS.Typography.body(skin: skin))
                    .foregroundStyle(skin.accentColor)
                    .frame(width: 18)
                Text(label)
                    .font(.subheadline.weight(.regular))
                    .foregroundStyle(skin.resolvedTextPrimary)
                Spacer(minLength: 0)
            }
            .padding(.vertical, DS.Spacing.xs)
            .padding(.horizontal, DS.Spacing.md)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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
                        .font(isTop ? .headline.weight(.semibold) : .subheadline.weight(isSelected ? .semibold : .regular))
                        .foregroundStyle(skin.resolvedTextPrimary)
                        .lineLimit(1)

                    if isTop, let preview = dryRunPreview {
                        Text(preview)
                            .font(.footnote)
                            .foregroundStyle(skin.accentColor.opacity(DS.Opacity.loudOverlay))
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
                    ? skin.accentColor.opacity(isSelected ? DS.Opacity.strongFill : DS.Opacity.lightFill)
                    : (isSelected ? skin.accentColor.opacity(DS.Opacity.mediumFill) : .clear))
        )
        .onHover { if $0 { selectedIndex = index } }
    }

}
