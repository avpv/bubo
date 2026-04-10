import SwiftUI

struct MenuBarView: View {
    @Environment(\.activeSkin) private var skin
    var settings: ReminderSettings
    var reminderService: ReminderService
    var networkMonitor: NetworkMonitor
    var optimizerService: OptimizerService
    var agentService: AgentService

    @State private var navigation: Navigation = .list
    @State private var hasStartedSync = false
    @State private var toastState = ToastState()
    @State private var scrollPositionID: String?
    @State private var colorFilter: EventColorTag? = nil

    /// When true, BacklogView will grab focus on its "Add task…" field.
    /// Set from footer / keyboard shortcut, consumed by BacklogView.
    @State private var focusTaskInput = false

    /// Incremented to trigger a scroll-to-backlog inside the active ScrollView.
    @State private var scrollToBacklogTick = 0

    // Command palette — the single entry point for all optimize flows.
    @State private var paletteContext: PaletteContext? = nil
    @State private var dismissedBannerIds: Set<String> = {
        let stored = UserDefaults.standard.stringArray(forKey: "BuboDismissedBannerIds") ?? []
        return Set(stored)
    }()

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Enum-based navigation state machine replaces fragile boolean flags.
    enum Navigation: Equatable {
        case list
        case detail(CalendarEvent)
        case addEvent(editing: CalendarEvent? = nil, initialType: EventType = .standard)
        case timer(CalendarEvent)
        case quickAddTasks

        static var addPomodoro: Navigation { .addEvent(initialType: .pomodoro) }

        var isTimer: Bool {
            if case .timer = self { return true }
            return false
        }

        static func == (lhs: Navigation, rhs: Navigation) -> Bool {
            switch (lhs, rhs) {
            case (.list, .list): return true
            case (.detail(let a), .detail(let b)): return a.id == b.id
            case (.addEvent(let a, let t1), .addEvent(let b, let t2)): return a?.id == b?.id && t1 == t2
            case (.timer(let a), .timer(let b)): return a.id == b.id
            case (.quickAddTasks, .quickAddTasks): return true
            default: return false
            }
        }
    }

    /// Context for the command palette overlay. nil = hidden.
    struct PaletteContext: Equatable {
        var seedEvent: CalendarEvent? = nil
        var seedSlotMinutes: Int? = nil
        var seedSlotStart: Date? = nil
        var seedSlotEnd: Date? = nil
        var seedRecipeId: String? = nil
    }

    private var activeSkin: SkinDefinition { settings.selectedSkin }

    var body: some View {
        ZStack {
            AppBackgroundLayer(
                skin: activeSkin,
                wallpaper: settings.selectedWallpaper,
                customPhotoPath: settings.customBackgroundPhotoPath,
                customPhotoOpacity: settings.customBackgroundPhotoOpacity,
                customPhotoBlur: settings.customBackgroundPhotoBlur
            )

            Group {
                switch navigation {
                case .list:
                    mainContent
                        .task {
                            try? await Task.sleep(for: .milliseconds(300))
                            withAnimation(DS.Animation.smoothSpring) {
                                scrollPositionID = nil
                            }
                        }
                        .transition(
                            reduceMotion ? .opacity : .asymmetric(
                                insertion: .move(edge: .leading).combined(with: .opacity),
                                removal: .move(edge: .leading).combined(with: .opacity).combined(with: .scale(scale: 0.98))
                            )
                        )

                case .detail(let event):
                    EventDetailView(
                        event: event,
                        reminderService: reminderService,
                        onBack: { navigation = .list },
                        onEdit: { event in resolveEdit(event) },
                        onDelete: { event in
                            let deletedEvent = event
                            reminderService.removeLocalEvent(id: event.id)
                            navigation = .list
                            toastState.showSuccess("\u{201C}\(deletedEvent.title)\u{201D} deleted", icon: "trash.fill") {
                                reminderService.addLocalEvent(deletedEvent)
                            }
                            notifyScheduleChange()
                        },
                        onDeleteSeries: { event in
                            let seriesId = event.seriesId ?? event.id
                            let seriesEvent = reminderService.seriesEvent(for: event) ?? event
                            reminderService.removeLocalEvent(id: seriesId)
                            navigation = .list
                            toastState.showSuccess("All \u{201C}\(event.title)\u{201D} deleted", icon: "trash.fill") {
                                reminderService.addLocalEvent(seriesEvent)
                            }
                            notifyScheduleChange()
                        },
                        onDeleteOccurrence: { event in
                            reminderService.excludeOccurrence(occurrenceId: event.id)
                            navigation = .list
                            toastState.showSuccess("\u{201C}\(event.title)\u{201D} removed", icon: "trash.fill")
                        },
                        onTimer: { event in
                            navigation = .timer(event)
                        }
                    )
                    .transition(
                        reduceMotion ? .opacity : .asymmetric(
                            insertion: .move(edge: .trailing).combined(with: .opacity),
                            removal: .move(edge: .trailing).combined(with: .opacity).combined(with: .scale(scale: 0.98))
                        )
                    )

                case .timer(let event):
                    TimerScreenView(
                        event: event,
                        onBack: { navigation = .detail(event) },
                        onRepeat: { finishedEvent in
                            // Re-create the same pomodoro session starting now
                            var repeat_ = finishedEvent
                            repeat_.id = UUID().uuidString
                            repeat_.startDate = Date()
                            repeat_.endDate = Date().addingTimeInterval(finishedEvent.duration)
                            reminderService.addLocalEvent(repeat_)
                            navigation = .timer(repeat_)
                            toastState.showSuccess("Session restarted")
                        },
                        onScheduleNext: { _ in
                            navigation = .list
                            paletteContext = PaletteContext(seedRecipeId: "pomodoro")
                        }
                    )
                    .transition(
                        reduceMotion ? .opacity : .asymmetric(
                            insertion: .move(edge: .trailing).combined(with: .opacity),
                            removal: .move(edge: .trailing).combined(with: .opacity).combined(with: .scale(scale: 0.98))
                        )
                    )

                case .addEvent(let editing, let initialType):
                    AddEventView(
                        reminderService: reminderService,
                        editingEvent: editing,
                        initialEventType: initialType,
                        onDismiss: {
                            // Return to detail if we were editing, otherwise list
                            if let event = editing,
                               let updated = reminderService.allEvents.first(where: { $0.id == event.id }) {
                                navigation = .detail(updated)
                            } else {
                                navigation = .list
                            }
                        },
                        onSave: { isEdit in
                            // After saving an edit, return to detail view with updated data
                            if isEdit, let eventId = editing?.id,
                               let updated = reminderService.allEvents.first(where: { $0.id == eventId }) {
                                navigation = .detail(updated)
                            } else {
                                navigation = .list
                            }
                            toastState.showSuccess(isEdit ? "Event updated" : "Event created")
                            if isEdit, editing?.id != nil {
                                notifyScheduleChange()
                            }
                        },
                        settings: settings,
                        optimizerService: optimizerService
                    )
                    .transition(
                        reduceMotion ? .opacity : .asymmetric(
                            insertion: .move(edge: .trailing).combined(with: .opacity),
                            removal: .move(edge: .trailing).combined(with: .opacity).combined(with: .scale(scale: 0.98))
                        )
                    )

                case .quickAddTasks:
                    // Backlog is now inline — return to list and focus the task input.
                    EmptyView()
                        .onAppear {
                            navigation = .list
                            focusTaskInput = true
                        }
                }
            }
            .animation(
                reduceMotion ? DS.Animation.quick : DS.Animation.smoothSpring,
                value: navigation
            )

            // Command palette — inline overlay on top of everything else.
            if let context = paletteContext {
                CommandPalette(
                    optimizerService: optimizerService,
                    reminderService: reminderService,
                    agentService: agentService,
                    seedEvent: context.seedEvent,
                    seedSlotMinutes: context.seedSlotMinutes,
                    seedSlotStart: context.seedSlotStart,
                    seedSlotEnd: context.seedSlotEnd,
                    seedPreset: context.seedRecipeId.flatMap { id in IntentPresets.all.first { $0.name == id } },
                    onDismiss: {
                        withAnimation(DS.Animation.quick) { paletteContext = nil }
                    },
                    onApplied: { request, undo in
                        toastState.showSuccess(
                            "\(request.name ?? "Schedule") applied",
                            icon: "sparkles",
                            onUndo: undo
                        )
                    }
                )
                .transition(.opacity)
                .zIndex(10)
            }

            ToastOverlay(toastState: toastState)

            // Hidden button for ⌘K shortcut — lives outside the palette so it
            // can toggle the palette from the list.
            Button("") {
                Haptics.tap()
                withAnimation(DS.Animation.quick) {
                    if paletteContext == nil {
                        paletteContext = PaletteContext()
                    } else {
                        paletteContext = nil
                    }
                }
            }
            .keyboardShortcut("k", modifiers: .command)
            .opacity(0)
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)

            // Hidden button for ⇧⌘N shortcut — focuses the task input field.
            Button("") {
                Haptics.tap()
                scrollToBacklogTick += 1
                focusTaskInput = true
            }
            .keyboardShortcut("n", modifiers: [.command, .shift])
            .opacity(0)
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
        }
        .skinTinted(activeSkin)
        .skinTypography(activeSkin)
        .environment(\.activeSkin, activeSkin)
        .environment(\.navigateHome, { navigation = .list })
        .frame(width: DS.Popover.width, height: navigation.isTimer ? DS.Popover.timerHeight : DS.Popover.height)
        .onAppear {
            guard !hasStartedSync else { return }
            hasStartedSync = true
            reminderService.updateSettings(settings)
            reminderService.startSync()
            if let backlog = optimizerService.backlogService {
                optimizerService.setup(reminderService: reminderService, backlogService: backlog)
            } else {
                assertionFailure("BacklogService should be set in App.init")
            }
        }
    }

    // MARK: - Filtered Events

    private var filteredEventsByDay: [(date: Date, events: [CalendarEvent])] {
        let base: [(date: Date, events: [CalendarEvent])]
        if let filter = colorFilter {
            base = reminderService.eventsByDay.compactMap { dayGroup in
                let filtered = dayGroup.events.filter { $0.colorTag == filter }
                return filtered.isEmpty ? nil : (date: dayGroup.date, events: filtered)
            }
        } else {
            // Skip empty day groups (e.g. "Today" with 0 events when tomorrow has events)
            base = reminderService.eventsByDay.filter { !$0.events.isEmpty }
        }
        return base
    }

    /// Count of visible (non-disintegrating) events for a day group.
    private func visibleEventCount(for events: [CalendarEvent]) -> Int {
        events.filter { !reminderService.disintegratingEventIDs.contains($0.id) }.count
    }

    // MARK: - Helpers

    private var pendingTaskCount: Int {
        optimizerService.backlogService?.pending.count ?? 0
    }

    private var isScrolledFromTop: Bool {
        guard let pos = scrollPositionID else { return false }
        let allEvents = reminderService.eventsByDay.flatMap(\.events)
        let topIDs = Set(allEvents.prefix(5).map(\.id))
        return !topIDs.contains(pos)
    }

    private func resolveEdit(_ event: CalendarEvent) {
        if let seriesEvent = reminderService.seriesEvent(for: event) {
            navigation = .addEvent(editing: seriesEvent)
        } else {
            navigation = .addEvent(editing: event)
        }
    }

    private func handleDelete(_ event: CalendarEvent) {
        let deletedEvent = event
        reminderService.removeLocalEvent(id: event.id)
        toastState.showSuccess("\u{201C}\(deletedEvent.title)\u{201D} deleted", icon: "trash.fill") {
            reminderService.addLocalEvent(deletedEvent)
        }
        notifyScheduleChange()
    }

    private func notifyScheduleChange(deleted eventId: String? = nil, created: Bool = false) {
        optimizerService.suggestionEngine?.evaluate()
        // Fire reactive triggers
        if let eventId {
            Task {
                await optimizerService.triggerEngine?.onEventDeleted(eventId: eventId)
            }
        }
        if created {
            Task {
                await optimizerService.triggerEngine?.onNewEvent(eventId: "")
            }
        }
    }

    /// Create a focus block directly in the given slot, bypassing the optimizer.
    /// Same pattern as handleTaskDrop — direct event creation + undo toast.
    private func fillSlotWithFocus(start: Date, end: Date) {
        Haptics.tap()
        let eventId = "focus-\(UUID().uuidString)"
        let event = CalendarEvent(
            id: eventId,
            title: "Focus Time",
            startDate: start,
            endDate: end,
            location: nil,
            description: nil,
            calendarName: nil,
            eventType: .standard,
            colorTag: .blue
        )
        reminderService.addLocalEvent(event)

        let fmt = DateFormatter()
        fmt.setLocalizedDateFormatFromTemplate("H:mm")
        toastState.showSuccess(
            "Focus \(fmt.string(from: start))–\(fmt.string(from: end))",
            icon: "sparkles"
        ) {
            reminderService.removeLocalEvent(id: eventId)
        }
        notifyScheduleChange(created: true)
    }

    /// Reschedule overdue tasks into a free slot.
    /// Removes old events, creates new ones packed from slot start, registers batch undo.
    private func rescheduleOverdue(into start: Date, end: Date) {
        guard let backlog = optimizerService.backlogService else { return }
        Haptics.tap()

        let slotDuration = end.timeIntervalSince(start)
        // Pick overdue tasks sorted by deadline (soonest first), fitting into the slot.
        let sorted = backlog.overdue.sorted {
            ($0.deadline ?? .distantFuture) < ($1.deadline ?? .distantFuture)
        }
        var remaining = slotDuration
        var toReschedule: [BacklogTask] = []
        for task in sorted {
            let dur = TimeInterval(task.durationMinutes * 60)
            guard dur <= remaining else { continue }
            toReschedule.append(task)
            remaining -= dur
        }
        guard !toReschedule.isEmpty else { return }

        // Remove old events, create new ones packed sequentially from slot start.
        struct Snapshot { let task: BacklogTask; let oldEventId: String?; let newEventId: String }
        var snapshots: [Snapshot] = []
        var cursor = start
        for task in toReschedule {
            let oldEventId = task.scheduledEventId
            if let old = oldEventId { reminderService.removeLocalEvent(id: old) }

            let dur = TimeInterval(task.durationMinutes * 60)
            let newEventId = "task-\(task.id)"
            let event = CalendarEvent(
                id: newEventId,
                title: task.title,
                startDate: cursor,
                endDate: cursor.addingTimeInterval(dur),
                location: nil,
                description: nil,
                calendarName: nil,
                eventType: .standard,
                colorTag: .green
            )
            reminderService.addLocalEvent(event)
            backlog.markScheduled(id: task.id, eventId: newEventId, date: cursor)
            snapshots.append(Snapshot(task: task, oldEventId: oldEventId, newEventId: newEventId))
            cursor = cursor.addingTimeInterval(dur)
        }

        let count = toReschedule.count
        toastState.showSuccess(
            "Rescheduled \(count) task\(count == 1 ? "" : "s")",
            icon: "arrow.uturn.forward"
        ) {
            // Undo: remove new events, restore old events and scheduled state
            for snap in snapshots {
                reminderService.removeLocalEvent(id: snap.newEventId)
                if let old = snap.oldEventId {
                    // Restore the original event if we removed it
                    let original = CalendarEvent(
                        id: old,
                        title: snap.task.title,
                        startDate: snap.task.scheduledDate ?? start,
                        endDate: (snap.task.scheduledDate ?? start).addingTimeInterval(TimeInterval(snap.task.durationMinutes * 60)),
                        location: nil,
                        description: nil,
                        calendarName: nil,
                        eventType: .standard,
                        colorTag: .green
                    )
                    reminderService.addLocalEvent(original)
                }
                backlog.markScheduled(
                    id: snap.task.id,
                    eventId: snap.oldEventId ?? snap.newEventId,
                    date: snap.task.scheduledDate ?? start
                )
            }
        }
        notifyScheduleChange(created: true)
    }

    // MARK: - Inline Backlog

    /// Backlog section for embedding in the main timeline.
    /// Manages its own horizontal padding — do NOT wrap in additional padding.
    @ViewBuilder
    private func inlineBacklog(autoExpand: Bool = false) -> some View {
        if let backlog = optimizerService.backlogService {
            BacklogView(
                backlogService: backlog,
                optimizerService: optimizerService,
                reminderService: reminderService,
                onScheduleTasks: {
                    withAnimation(DS.Animation.quick) {
                        paletteContext = PaletteContext()
                    }
                },
                onDeleteTask: { task in
                    _ = backlog.removeTask(id: task.id)
                    toastState.showSuccess("\u{201C}\(task.title)\u{201D} deleted", icon: "trash.fill") {
                        backlog.restoreTask(task)
                    }
                },
                focusRequested: $focusTaskInput,
                autoExpand: autoExpand
            )
        }
    }

    /// Handle a backlog task being dropped onto a free slot.
    /// Creates a calendar event at the slot time and marks the task as scheduled.
    private func handleTaskDrop(taskId: String, slotStart: Date, slotEnd: Date) {
        guard let backlog = optimizerService.backlogService,
              let task = backlog.tasks.first(where: { $0.id == taskId }) else { return }

        let duration = min(
            TimeInterval(task.durationMinutes * 60),
            slotEnd.timeIntervalSince(slotStart)
        )
        let eventId = "task-\(task.id)"
        let event = CalendarEvent(
            id: eventId,
            title: task.title,
            startDate: slotStart,
            endDate: slotStart.addingTimeInterval(duration),
            location: nil,
            description: nil,
            calendarName: nil,
            eventType: .standard,
            colorTag: .green
        )
        reminderService.addLocalEvent(event)
        backlog.markScheduled(id: task.id, eventId: eventId, date: slotStart)

        let fmt = DateFormatter()
        fmt.setLocalizedDateFormatFromTemplate("H:mm")
        toastState.showSuccess(
            "\(task.title) → \(fmt.string(from: slotStart))",
            icon: "calendar.badge.plus"
        ) {
            // Undo: remove event and unschedule task
            reminderService.removeLocalEvent(id: eventId)
            backlog.unschedule(id: task.id)
        }
        notifyScheduleChange()
    }

    // MARK: - Main Content

    private var mainContent: some View {
        ScrollViewReader { scrollProxy in
        VStack(alignment: .leading, spacing: 0) {
            PopoverHeader(
                title: dayProgressTitle,
                trailing: AnyView(
                    HStack(spacing: DS.Spacing.sm) {
                        statusIndicators

                        if isScrolledFromTop {
                            Button {
                                Haptics.tap()
                                withAnimation(DS.Animation.smoothSpring) {
                                    scrollProxy.scrollTo("eventListTop", anchor: .top)
                                }
                                Task {
                                    try? await Task.sleep(for: .milliseconds(400))
                                    withAnimation(DS.Animation.smoothSpring) {
                                        scrollPositionID = nil
                                    }
                                }
                            } label: {
                                Image(systemName: "arrow.up")
                                    .font(.system(size: DS.Size.iconSmall, weight: .semibold))
                                    .foregroundStyle(skin.resolvedTextSecondary)
                            }
                            .buttonStyle(.borderless)
                            .help("Scroll to top")
                            .accessibilityLabel("Scroll to top")
                            .transition(.scale.combined(with: .opacity))
                        }
                    }
                )
            )

            // Status messages — show at most one banner to avoid stacking (HIG: keep primary content visible)
            if !networkMonitor.isConnected {
                StatusBanner(
                    icon: "wifi.slash",
                    text: "No internet — calendar data may be outdated",
                    color: skin.resolvedWarningColor
                )
            } else if settings.isCalendarSyncEnabled && !AppleCalendarService.hasAccess {
                CalendarAccessBanner()
                    .frame(maxWidth: .infinity, alignment: .center)
            } else if reminderService.isUsingCache {
                StatusBanner(
                    icon: "arrow.triangle.2.circlepath",
                    text: "Showing cached data",
                    color: skin.resolvedWarningColor
                )
                .frame(maxWidth: .infinity, alignment: .center)
            } else if let error = reminderService.syncError, settings.isCalendarSyncEnabled, networkMonitor.isConnected {
                StatusBanner(icon: "exclamationmark.triangle.fill", text: error, color: skin.resolvedWarningColor)
                    .frame(maxWidth: .infinity, alignment: .center)
            }

            // World Clock — only show when user has cities configured
            if !settings.worldClockCityIDs.isEmpty {
                WorldClockStripView(settings: settings)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // Color filter — show when at least one event has a color assigned
            if !usedColorTags.isEmpty {
                colorFilterBar
            }

            // Quick actions — pinned above the scroll area
            if reminderService.nonDisintegratingEventCount > 0 {
                QuickActions(
                    optimizerService: optimizerService,
                    reminderService: reminderService,
                    onExecuted: { label, undo in
                        toastState.showSuccess(label, icon: "sparkles", onUndo: undo)
                        notifyScheduleChange()
                    },
                    onOpenPalette: {
                        Haptics.tap()
                        withAnimation(DS.Animation.quick) {
                            paletteContext = PaletteContext()
                        }
                    }
                )
                .padding(.horizontal, DS.Spacing.md)
                .padding(.vertical, DS.Spacing.xs)
            }

            // Events — fill remaining space so header stays pinned
            Group {
                if reminderService.nonDisintegratingEventCount == 0 {
                    emptyState
                } else if filteredEventsByDay.isEmpty {
                    VStack(spacing: DS.Spacing.sm) {
                        Text("No events with this color")
                            .font(.subheadline)
                            .foregroundStyle(skin.resolvedTextSecondary)
                        Button("Clear filter") { colorFilter = nil }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    eventList
                }
            }
            .frame(maxHeight: .infinity)
            .animation(DS.Animation.smoothSpring, value: reminderService.nonDisintegratingEventCount == 0)

            SkinSeparator()
            footerActions
        }
        } // ScrollViewReader
    }

    // MARK: - Subviews

    private var statusIndicators: some View {
        HStack(spacing: DS.Spacing.sm) {
            if !networkMonitor.isConnected {
                Image(systemName: "wifi.slash")
                    .foregroundStyle(skin.resolvedDestructiveColor)
                    .font(.system(size: DS.Size.iconSmall))
                    .symbolEffect(.pulse, options: .repeating.speed(0.5))
                    .help("No internet connection")
                    .accessibilityLabel("No internet connection")
                    .transition(.scale.combined(with: .opacity))
            }

            if reminderService.isSyncing {
                ProgressView()
                    .controlSize(.mini)
                    .frame(width: DS.Size.syncIndicatorSize, height: DS.Size.syncIndicatorSize)
                    .transition(.scale.combined(with: .opacity))
            }
        }
        .animation(skin.resolvedMicroAnimation, value: networkMonitor.isConnected)
        .animation(skin.resolvedMicroAnimation, value: reminderService.isSyncing)
    }

    /// Dynamic header title showing today's progress and time until next event.
    private var dayProgressTitle: String {
        let cal = Calendar.current
        let now = Date()
        guard let todayGroup = reminderService.eventsByDay.first(where: { cal.isDateInToday($0.date) }) else {
            return "Bubo"
        }
        let todayEvents = todayGroup.events.filter { !reminderService.disintegratingEventIDs.contains($0.id) }
        let total = todayEvents.count
        guard total > 0 else { return "Bubo" }
        let done = todayEvents.filter { $0.endDate <= now }.count

        // Time until next upcoming event
        let nextSuffix: String = {
            guard let next = todayEvents.first(where: { $0.startDate > now }) else { return "" }
            let mins = Int(next.startDate.timeIntervalSince(now)) / 60
            if mins < 1 { return " \u{00B7} now" }
            if mins < 60 { return " \u{00B7} in\u{00A0}\(mins)\u{00A0}min" }
            let h = mins / 60
            let m = mins % 60
            if m == 0 { return " \u{00B7} in\u{00A0}\(h)\u{00A0}h" }
            return " \u{00B7} in\u{00A0}\(h)\u{00A0}h\u{00A0}\(m)\u{00A0}min"
        }()

        if done == 0 { return "\(total)\u{00A0}events today\(nextSuffix)" }
        if done == total { return "All\u{00A0}\(total) done" }
        return "\(done)\u{00A0}of\u{00A0}\(total)\(nextSuffix)"
    }

    /// Context-aware subtitle for the empty state.
    private var emptyStateSubtitle: String {
        let cal = Calendar.current
        let now = Date()

        // Check if there are any future events across all days (including ones currently filtered out by the time window)
        let allUpcoming = reminderService.allEvents
            .filter { $0.startDate > now }
            .sorted { $0.startDate < $1.startDate }

        if let next = allUpcoming.first {
            let interval = next.startDate.timeIntervalSince(now)
            let hours = Int(interval / 3600)
            let minutes = Int(interval / 60) % 60

            if cal.isDateInToday(next.startDate) {
                if hours > 0 {
                    return "Next: \(next.title) in\u{00A0}\(hours)\u{00A0}h\u{00A0}\(minutes)\u{00A0}min"
                }
                return "Next: \(next.title) in\u{00A0}\(minutes)\u{00A0}min"
            } else if cal.isDateInTomorrow(next.startDate) {
                let fmt = DateFormatter()
                fmt.dateFormat = "H:mm"
                return "Tomorrow: \(next.title) at\u{00A0}\(fmt.string(from: next.startDate))"
            } else {
                let fmt = DateFormatter()
                fmt.setLocalizedDateFormatFromTemplate("EEE")
                return "Next: \(next.title) on\u{00A0}\(fmt.string(from: next.startDate))"
            }
        }

        return "No upcoming events"
    }

    private var emptyState: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 0) {
                    // Backlog — accessible even when calendar is empty.
                    // Auto-expand: tasks are the primary content when no events exist.
                    inlineBacklog(autoExpand: true)
                        .id("backlogSection")

                    if pendingTaskCount > 0 {
                        // Tasks exist — keep the "no events" note compact so
                        // tasks dominate the screen (they're the actionable content).
                        HStack(spacing: DS.Spacing.sm) {
                            Image(systemName: "calendar")
                                .font(.caption)
                                .foregroundStyle(skin.resolvedTextTertiary)
                            Text(emptyStateSubtitle)
                                .font(.caption)
                                .foregroundStyle(skin.resolvedTextTertiary)
                            Spacer()
                            Button {
                                Haptics.tap()
                                navigation = .addEvent()
                            } label: {
                                Text("Add Event")
                                    .font(.caption.weight(.medium))
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(skin.accentColor)
                        }
                        .padding(.horizontal, DS.Spacing.lg)
                        .padding(.vertical, DS.Spacing.lg)
                    } else {
                        // Truly empty — no tasks, no events. Full empty state.
                        VStack(spacing: DS.EmptyState.spacing * 1.5) {
                            ZStack {
                                Circle()
                                    .fill(
                                        RadialGradient(
                                            colors: [
                                                skin.accentColor.opacity(0.25),
                                                .clear
                                            ],
                                            center: .center,
                                            startRadius: 0,
                                            endRadius: DS.EmptyState.iconSize * 1.5
                                        )
                                    )
                                    .frame(width: DS.EmptyState.iconSize * 3, height: DS.EmptyState.iconSize * 3)

                                Image(systemName: "calendar.badge.checkmark")
                                    .font(.system(size: DS.EmptyState.iconSize, weight: .light))
                                    .foregroundStyle(skin.accentColor, skin.resolvedTextSecondary)
                                    .symbolEffect(.pulse, options: .repeating.speed(0.1))
                            }

                            VStack(spacing: DS.Spacing.xs) {
                                Text("All clear")
                                    .font(.headline)
                                    .fontWeight(skin.resolvedHeadlineFontWeight)
                                    .foregroundStyle(skin.resolvedTextPrimary)
                                Text(emptyStateSubtitle)
                                    .font(.subheadline)
                                    .foregroundStyle(skin.resolvedTextSecondary)
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                            }

                            Button {
                                Haptics.tap()
                                navigation = .addEvent()
                            } label: {
                                Label("Add Event", systemImage: "plus")
                                    .font(.caption)
                                    .fontWeight(.medium)
                            }
                            .buttonStyle(.action(role: .primary, size: .compact))
                            .padding(.top, DS.Spacing.sm)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, DS.Spacing.xxl)
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .onChange(of: scrollToBacklogTick) { _, _ in
                withAnimation(DS.Animation.smoothSpring) {
                    proxy.scrollTo("backlogSection", anchor: .top)
                }
            }
        }
        .transition(.opacity.combined(with: .scale(scale: 0.95)))
    }

    private var usedColorTags: [EventColorTag] {
        let allEvents = reminderService.eventsByDay.flatMap(\.events)
        let usedTags = Set(allEvents.compactMap(\.colorTag))
        return EventColorTag.allCases.filter { usedTags.contains($0) }
    }

    private var colorFilterBar: some View {
        let selected = colorFilter
        return HStack(spacing: DS.Spacing.xs) {
            ForEach(EventColorTag.allCases, id: \.self) { tag in
                ColorDotButton(
                    tag: tag,
                    isActive: selected == tag,
                    isDimmed: selected != nil && selected != tag
                ) {
                    Haptics.tap()
                    withAnimation(skin.resolvedMicroAnimation) {
                        colorFilter = (colorFilter == tag) ? nil : tag
                    }
                }
            }

            if selected != nil {
                Button {
                    Haptics.tap()
                    withAnimation(skin.resolvedMicroAnimation) {
                        colorFilter = nil
                    }
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12, weight: skin.resolvedSymbolWeight, design: skin.resolvedFontDesign))
                        .symbolRenderingMode(skin.resolvedSymbolRendering)
                        .foregroundStyle(skin.resolvedTextTertiary)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Clear filter")
                .transition(.scale.combined(with: .opacity))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, DS.Spacing.md)
        .padding(.vertical, DS.Spacing.sm)
        .skinPlatter(activeSkin)
        .skinPlatterDepth(skin)
        .padding(.horizontal, DS.Spacing.md)
        .padding(.vertical, DS.Spacing.xs)
        .animation(skin.resolvedMicroAnimation, value: colorFilter)
    }

    private var eventList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    // Backlog tasks — always accessible at the top of the timeline.
                    // Birman: don't hide features behind navigation; show where the user already looks.
                    inlineBacklog()
                        .id("backlogSection")

                    if pendingTaskCount > 0 {
                        SkinSeparator()
                            .padding(.horizontal, DS.Spacing.md)
                    }

                    LazyVStack(alignment: .leading, spacing: DS.Spacing.md) {
                        // Smart banner — at most one contextual suggestion.
                        if let suggestion = activeBannerSuggestion {
                            SmartBanner(
                                request: suggestion.request,
                                reason: suggestion.reason,
                                onRun: {
                                    runQuickAction(suggestion.request, label: suggestion.reason)
                                },
                                onDismiss: {
                                    withAnimation(DS.Animation.quick) {
                                        optimizerService.suggestionEngine?.suggestion = nil
                                    }
                                }
                            )
                        }

                        ForEach(filteredEventsByDay, id: \.date) { dayGroup in
                            dayGroupSection(dayGroup)
                        }
                    }
                    .padding(.horizontal, DS.Spacing.md)
                    .padding(.top, DS.Spacing.md)
                    .padding(.bottom, DS.Spacing.xl)
                    .scrollTargetLayout()
                }
                .id("eventListTop")
                .animation(DS.Animation.smoothSpring, value: reminderService.disintegratingEventIDs)
            }
            .scrollPosition(id: $scrollPositionID)
            .scrollContentBackground(.hidden)
            .onChange(of: scrollToBacklogTick) { _, _ in
                withAnimation(DS.Animation.smoothSpring) {
                    proxy.scrollTo("backlogSection", anchor: .top)
                }
            }
        }
    }

    // MARK: - Day Group Section (extracted for release-mode type checker)

    @ViewBuilder
    private func dayGroupSection(_ dayGroup: (date: Date, events: [CalendarEvent])) -> some View {
        let visibleCount = visibleEventCount(for: dayGroup.events)

        DaySectionHeader(date: dayGroup.date, count: visibleCount)
            .padding(.horizontal, DS.Spacing.sm)
            .padding(.top, dayGroup.date == reminderService.eventsByDay.first?.date ? 0 : DS.Spacing.sm)

        let freeSlots = FreeSlotFinder.slots(
            for: dayGroup.events,
            on: dayGroup.date,
            workingHours: optimizerService.workingHours
        )

        ForEach(interleave(events: dayGroup.events, freeSlots: freeSlots), id: \.id) { item in
            switch item {
            case .event(let event):
                EventRowView(
                    event: event,
                    reminderService: reminderService,
                    onEdit: { event in resolveEdit(event) },
                    onDelete: { event in handleDelete(event) },
                    onDeleteOccurrence: { event in
                        reminderService.excludeOccurrence(occurrenceId: event.id)
                        toastState.showSuccess("\u{201C}\(event.title)\u{201D} removed", icon: "trash.fill")
                    },
                    onDeleteSeries: { event in
                        let seriesId = event.seriesId ?? event.id
                        reminderService.removeLocalEvent(id: seriesId)
                        toastState.showSuccess("All \u{201C}\(event.title)\u{201D} deleted", icon: "trash.fill")
                    },
                    onTap: { event in
                        navigation = .detail(event)
                    },
                    onCompleteTask: { event in
                        var completed = event
                        completed.taskStatus = .done
                        completed.completedAt = Date()
                        reminderService.updateLocalEvent(completed)
                        toastState.showSuccess("Task completed", icon: "checkmark.circle.fill")
                    },
                    onFindBetterTime: { event in
                        withAnimation(DS.Animation.quick) {
                            paletteContext = PaletteContext(seedEvent: event)
                        }
                    },
                    onSplitTask: { _ in
                        withAnimation(DS.Animation.quick) {
                            paletteContext = PaletteContext(seedRecipeId: "split-task")
                        }
                    },
                    onProtectBlock: { event in
                        let request = OptimizationRequest(
                            .keepFixed(eventIds: [event.id]),
                            .horizon(.today), .speed(.quick), .scenarios(count: 1),
                            name: "Protect Block"
                        )
                        Task {
                            _ = await optimizerService.executeRequest(request, reminderService: reminderService)
                            toastState.showSuccess("Focus block protected", icon: "shield.fill")
                        }
                    },
                    onAddPrep: { event in
                        withAnimation(DS.Animation.quick) {
                            paletteContext = PaletteContext(seedEvent: event, seedRecipeId: "prep-meeting")
                        }
                    },
                    isFreshlyCreated: optimizerService.freshlyCreatedEventIds.contains(event.id)
                )
            case .slot(let start, let end):
                FreeSlotRow(
                    start: start,
                    end: end,
                    onFillTapped: { _ in
                        let backlog = optimizerService.backlogService
                        let hasPending = !(backlog?.pending.isEmpty ?? true)
                        let hasOverdue = !(backlog?.overdue.isEmpty ?? true)

                        if !hasPending && !hasOverdue {
                            // No tasks at all → direct focus fill.
                            fillSlotWithFocus(start: start, end: end)
                        } else if !hasPending && hasOverdue {
                            // Only overdue → reschedule directly, no palette.
                            rescheduleOverdue(into: start, end: end)
                        } else {
                            // Pending tasks (maybe overdue too) → show palette for choice.
                            withAnimation(DS.Animation.quick) {
                                paletteContext = PaletteContext(
                                    seedSlotMinutes: Int(end.timeIntervalSince(start) / 60),
                                    seedSlotStart: start,
                                    seedSlotEnd: end
                                )
                            }
                        }
                    },
                    onTaskDropped: { taskId in
                        handleTaskDrop(taskId: taskId, slotStart: start, slotEnd: end)
                    }
                )
            }
        }
    }

    // MARK: - List Items (events + free slots interleaved)

    /// A row in the day list — either a real event or an empty slot.
    private enum DayListItem: Identifiable {
        case event(CalendarEvent)
        case slot(Date, Date)

        var id: String {
            switch self {
            case .event(let e): return "event:\(e.id)"
            case .slot(let s, let e): return "slot:\(s.timeIntervalSinceReferenceDate)-\(e.timeIntervalSinceReferenceDate)"
            }
        }
    }

    /// Interleaves events and free-slot pairs chronologically so the list reads
    /// top-to-bottom like a real timeline.
    private func interleave(
        events: [CalendarEvent],
        freeSlots: [(start: Date, end: Date)]
    ) -> [DayListItem] {
        var result: [DayListItem] = events.map(DayListItem.event)
        result += freeSlots.map { DayListItem.slot($0.start, $0.end) }
        result.sort { startOf($0) < startOf($1) }
        return result
    }

    private func startOf(_ item: DayListItem) -> Date {
        switch item {
        case .event(let e): return e.startDate
        case .slot(let s, _): return s
        }
    }

    // MARK: - Smart Banner

    /// The first non-dismissed suggested recipe from the monitor, or nil when
    /// nothing is worth suggesting.
    private var activeBannerSuggestion: SuggestionEngine.Suggestion? {
        optimizerService.suggestionEngine?.suggestion
    }

    /// Execute a request immediately — no palette, no configuration.
    /// One tap → done → undo toast. Birman: "sequential magic."
    private func runQuickAction(_ request: OptimizationRequest, label: String) {
        Task {
            let result = await optimizerService.executeRequest(request, reminderService: reminderService)
            if case .success = result, !optimizerService.scenarios.isEmpty {
                optimizerService.applyScenario(at: 0, to: reminderService)
                toastState.showSuccess(label, icon: "sparkles") {
                    optimizerService.undoLast(reminderService: reminderService)
                }
                notifyScheduleChange()
            } else if let error = result.errorMessage {
                toastState.showInfo(error, icon: "exclamationmark.triangle")
            }
        }
    }

    private var footerActions: some View {
        HStack {
            Menu {
                Button {
                    Haptics.tap()
                    navigation = .addEvent()
                } label: {
                    Label("New Event", systemImage: "calendar.badge.plus")
                }
                Button {
                    Haptics.tap()
                    navigation = .addPomodoro
                } label: {
                    Label("New Pomodoro", systemImage: "timer")
                }
                Button {
                    Haptics.tap()
                    scrollToBacklogTick += 1
                    focusTaskInput = true
                } label: {
                    Label("New Task", systemImage: "plus.circle")
                }
            } label: {
                Label("Add", systemImage: "plus")
            } primaryAction: {
                Haptics.tap()
                navigation = .addEvent()
            }
            .buttonStyle(.action(role: .primary, size: .regular))
            .help("Add a new event (\u{2318}N)")
            .keyboardShortcut("n", modifiers: .command)

            // Tasks — always-visible entry point into the backlog.
            // Birman: don't hide features in menus; show them where the user can see them.
            Button {
                Haptics.tap()
                scrollToBacklogTick += 1
                focusTaskInput = true
            } label: {
                let count = optimizerService.backlogService?.pending.count ?? 0
                HStack(spacing: DS.Spacing.xs) {
                    Image(systemName: "checklist")
                    if count > 0 {
                        Text("\(count)")
                            .font(.caption2.weight(.semibold).monospacedDigit())
                    }
                }
            }
            .buttonStyle(.borderless)
            .foregroundStyle(skin.resolvedTextSecondary)
            .help("Tasks (\u{21E7}\u{2318}N)")

            Spacer()

            HStack(spacing: DS.Spacing.md) {
                Menu {
                    Button {
                        Haptics.tap()
                        reminderService.syncNow()
                        toastState.showInfo("Refreshing\u{2026}", icon: "arrow.clockwise")
                    } label: {
                        Label("Refresh Calendars", systemImage: "arrow.clockwise")
                    }
                    .keyboardShortcut("r", modifiers: .command)

                    OpenSettingsButton()
                        .keyboardShortcut(",", modifiers: .command)
                    Divider()
                    Button("Quit Bubo", role: .destructive) {
                        NSApplication.shared.terminate(nil)
                    }
                    .keyboardShortcut("q", modifiers: .command)
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("More")
            }
            .font(.system(size: activeSkin.toolbarIconSize, weight: .semibold))
            .buttonStyle(.borderless)
            .symbolRenderingMode(.monochrome)
            .tint(activeSkin.resolvedToolbarTint)
        }
        .font(.system(size: 13, weight: .medium))
        .padding(.horizontal, DS.Spacing.lg)
        .frame(maxWidth: .infinity)
        .frame(height: DS.Size.actionFooterHeight)
        .skinBarBackground(activeSkin)
    }
}

// MARK: - Settings Button

private struct OpenSettingsButton: View {
    var iconOnly: Bool = false
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Button {
            Haptics.tap()
            NSApp.keyWindow?.close()
            openSettings()
            NSApp.activate()
        } label: {
            if iconOnly {
                Image(systemName: "gear")
            } else {
                Label("Settings", systemImage: "gear")
            }
        }
    }
}

private struct CalendarAccessBanner: View {
    @Environment(\.openSettings) private var openSettings
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.activeSkin) private var skin

    var body: some View {
        Button {
            Haptics.tap()
            NSApp.keyWindow?.close()
            SettingsViewModel.pendingPane = .calendars
            openSettings()
            NSApp.activate()
            NotificationCenter.default.post(name: SettingsViewModel.navigateToPaneNotification, object: SettingsView.SettingsPane.calendars)
        } label: {
            HStack(spacing: DS.Spacing.sm) {
                Image(systemName: "calendar.badge.exclamationmark")
                    .foregroundStyle(skin.resolvedWarningColor)
                    .font(.caption)
                    .symbolRenderingMode(.hierarchical)
                Text("Calendar access not granted")
                    .font(.caption)
                    .foregroundStyle(skin.resolvedTextPrimary)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption2)
                    .foregroundStyle(skin.resolvedTextTertiary)
            }
            .padding(.horizontal, DS.Spacing.md)
            .padding(.vertical, DS.Spacing.sm)
            .adaptiveBadgeFill(skin.resolvedWarningColor)
            .clipShape(Capsule())
            .shadow(color: skin.resolvedShadowColor, radius: skin.shadowRadius, y: skin.shadowY)
        }
        .padding(.horizontal, DS.Spacing.md)
        .padding(.vertical, DS.Spacing.xs)
        .buttonStyle(.plain)
        .accessibilityLabel("Calendar access not granted. Open settings to grant access.")
        .transition(
            reduceMotion
                ? .opacity
                : .move(edge: .top).combined(with: .opacity)
        )
    }
}

// ColorDotButton is now a shared component in Components/ColorDotButton.swift
