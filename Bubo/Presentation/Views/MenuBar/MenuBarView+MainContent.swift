import SwiftUI
import AppKit
import BuboDomain

// MARK: - Main Content
//
// The `.list` destination's content: PopoverHeader + inline suggestion +
// World Clock strip + filter bar + SmartActions bar + LazyVStack timeline
// (or empty / syncing / no-match states) + FooterActions.

extension MenuBarView {

    // MARK: - Day-nav cluster

    /// Three-button day-nav cluster (`← Today →`) for the popover
    /// header trailing area. Taps scroll the list to the requested
    /// day's section.
    /// Scroll the timeline to the day at `index` — the model clamps and
    /// records the focus, the view owns the ScrollViewProxy hop.
    func navigateToDay(at index: Int, scroll: ScrollViewProxy) {
        guard let targetDate = screen.focusDay(at: index) else { return }
        Haptics.tap()
        withAnimation(DS.Animation.smoothSpring) {
            scroll.scrollTo(targetDate, anchor: .top)
        }
    }

    @ViewBuilder
    func dayNavCluster(scroll: ScrollViewProxy) -> some View {
        let days = screen.filteredEventsByDay
        let idx = screen.focusedDayIndex
        HStack(spacing: DS.Spacing.xxs) {
            Button {
                navigateToDay(at: idx - 1, scroll: scroll)
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: DS.Size.iconSmall, weight: .semibold))
                    .foregroundStyle(skin.resolvedTextSecondary)
            }
            .buttonStyle(.borderless)
            .disabled(idx <= 0)
            .help("Previous day")
            .accessibilityLabel("Previous day")

            Button {
                if let todayIdx = days.firstIndex(where: { Calendar.current.isDateInToday($0.date) }) {
                    navigateToDay(at: todayIdx, scroll: scroll)
                }
            } label: {
                Text("Today")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(skin.accentColor)
                    .opacity(screen.focusedDayIsToday ? 0.4 : 1.0)
            }
            .buttonStyle(.borderless)
            .disabled(screen.focusedDayIsToday)
            .help("Jump to today")
            .accessibilityLabel("Jump to today")

            Button {
                navigateToDay(at: idx + 1, scroll: scroll)
            } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: DS.Size.iconSmall, weight: .semibold))
                    .foregroundStyle(skin.resolvedTextSecondary)
            }
            .buttonStyle(.borderless)
            .disabled(idx >= days.count - 1)
            .help("Next day")
            .accessibilityLabel("Next day")
        }
    }

    // MARK: - Inline status row

    /// Single thin status slot — highest-priority issue only. Offline
    /// trumps everything; next, per-service permission banners (clickable,
    /// deep-link to the Settings pane that fixes them — two share one
    /// vertical slot as a paged carousel); last, a generic sync error.
    /// Hidden when everything is healthy. Cached-data state lives as a
    /// quiet glyph next to the header subtitle, not here.
    @ViewBuilder
    var inlineStatusRow: some View {
        if !networkMonitor.isConnected {
            StatusBanner(
                icon: "wifi.slash",
                text: "No internet — calendar data may be outdated",
                color: skin.resolvedWarningColor
            )
        } else if !screen.permissionBannerSpecs.isEmpty {
            PermissionBannersCarousel(specs: screen.permissionBannerSpecs)
                .frame(maxWidth: .infinity, alignment: .center)
        } else if let error = reminderService.syncError, settings.isCalendarSyncEnabled {
            StatusBanner(
                icon: "exclamationmark.triangle.fill",
                text: error,
                color: skin.resolvedWarningColor
            )
            .frame(maxWidth: .infinity, alignment: .center)
        }
    }

    // MARK: - Main Content
    //
    // Apple-philosophy «deference» pass: the previous version stacked
    // a focus-summary pill row above the timeline («Today: 5 · Tasks:
    // 12 · Free slots: 3»). Every one of those numbers is rendered a
    // few pt below in the day-section header summary or the footer —
    // duplicating them at the top added a second chrome band competing
    // with the timeline. Apple lists don't carry a stat pill row above
    // the headers; the headers ARE the stats. Row deleted, footnote
    // copy folded into the existing header subtitle stream.

    var mainContent: some View {
        ScrollViewReader { scrollProxy in
            // Stage-4 scaffold: the slot order (header → action rail →
            // status → strips → content → footer) is fixed by the type.
            // Slots carry no outer vertical nudges — inter-band rhythm is
            // each band's own chrome under a spacing-0 scaffold (§2).
            PopoverScreenLayout {
                headerBlock(scrollProxy: scrollProxy)
            } actionRail: {
                actionRail
            } status: {
                // Single inline status row — already conditional, hidden
                // when everything is healthy. No chrome cost at rest.
                inlineStatusRow
            } strips: {
                // REDESIGN.md R2 — the resting screen carries no strips.
                // The world clock lives as one quiet line in the header
                // block; the filter bar appears only while the user is
                // filtering (glyph toggled or a filter active — an
                // active filter must never hide, or «no events» becomes
                // an unexplained lie).
                if screen.showingFilterBar || hasActiveTimelineFilter {
                    ColorFilterBar(colorFilter: $screen.colorFilter, freeSlotFilter: $screen.freeSlotFilter)
                }
            } content: {
                timelineContent
            } footer: {
                FooterActions(
                    navigation: $screen.navigation,
                    reminderService: reminderService,
                    toastState: screen.toastState,
                    quickAddPresented: $screen.showingQuickAdd,
                    onQuickAddTask: { title, minutes in
                        handleQuickAddTask(title, explicitMinutes: minutes)
                    },
                    onQuickAddEvent: { title, start, minutes in
                        handleQuickAddEvent(title, start: start, minutes: minutes)
                    },
                    onQuickAddDetails: { interpretation in
                        routeQuickAddDetails(interpretation)
                    },
                    activeSkin: activeSkin,
                    workingHours: optimizerService.workingHoursStart...optimizerService.workingHoursEnd,
                    workingDays: optimizerService.workingDays
                )
            }
        }
    }

    // MARK: - Slot pieces

    /// Date / day title — the popover leads with «what day am I looking
    /// at». The block is tappable to open the command palette
    /// (Spotlight-style); the ⌘K hotkey continues to work — the title IS
    /// the entry point, no separate bar above it (PRINCIPLES §1/§4).
    /// True when any timeline filter is narrowing the canvas — keeps the
    /// filter bar visible (a hidden active filter is a trap: the user
    /// sees «no events» with no visible cause) and fills the glyph.
    var hasActiveTimelineFilter: Bool {
        screen.colorFilter != nil || screen.freeSlotFilter != .all
    }

    /// Quiet filter toggle in the header's trailing cluster — the filter
    /// bar's only entry point at rest (REDESIGN.md R2). PRINCIPLES §5:
    /// it is a verb, so it is a button; the active state rides the
    /// accent fill, not a second surface.
    @ViewBuilder
    private var filterToggleButton: some View {
        Button {
            Haptics.tap()
            withAnimation(DS.Animation.quick) {
                screen.showingFilterBar.toggle()
            }
        } label: {
            Image(systemName: hasActiveTimelineFilter
                ? "line.3.horizontal.decrease.circle.fill"
                : "line.3.horizontal.decrease.circle")
                .font(.system(size: DS.Size.iconSmall + 2, weight: .regular))
                .foregroundStyle(hasActiveTimelineFilter ? skin.accentColor : skin.resolvedTextSecondary)
        }
        .buttonStyle(.borderless)
        .help(screen.showingFilterBar ? "Hide timeline filters" : "Filter the timeline")
        .accessibilityLabel(hasActiveTimelineFilter
            ? "Timeline filters, active"
            : "Timeline filters")
    }

    @ViewBuilder
    private func headerBlock(scrollProxy: ScrollViewProxy) -> some View {
        VStack(alignment: .leading, spacing: DS.Spacing.xxs) {
            headerTitleRow(scrollProxy: scrollProxy)

            // World clock — one quiet line inside the header block
            // instead of a band of pills between header and canvas
            // (REDESIGN.md R2).
            WorldClockInlineLine(settings: settings)
        }
        // PRINCIPLES §2 — inter-band rhythm is not the band's job. The
        // gap to the action rail comes from the rail's own chrome
        // (SmartActionsBar's internal padding); no outer nudge here.
        .padding(.horizontal, DS.Spacing.contentMargin)
    }

    /// Date title (palette entry point), filter toggle, and the day-nav
    /// cluster — the header block's top row.
    @ViewBuilder
    private func headerTitleRow(scrollProxy: ScrollViewProxy) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Button {
                Haptics.tap()
                withAnimation(DS.Animation.quick) {
                    screen.paletteContext = MenuBarPaletteContext()
                }
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: DS.Spacing.xs) {
                        Text(screen.headerTitle)
                            .font(DS.Typography.headline(skin: skin))
                            .foregroundStyle(skin.resolvedTextPrimary)
                        Text("\u{2318}K")
                            .font(DS.Typography.machineHint)
                            .foregroundStyle(skin.resolvedTextTertiary)
                    }
                    if !screen.headerSubtitle.isEmpty || reminderService.isUsingCache {
                        HStack(spacing: DS.Spacing.xs) {
                            if !screen.headerSubtitle.isEmpty {
                                Text(screen.headerSubtitle)
                                    .font(.subheadline)
                                    .foregroundStyle(skin.resolvedTextSecondary)
                            }
                            // Cached-data state as a quiet glyph: the data
                            // is still usable, and a banner-sized alarm for
                            // a routine offline read pushed the timeline a
                            // whole band down. Hover carries the words.
                            if reminderService.isUsingCache {
                                Image(systemName: "arrow.triangle.2.circlepath")
                                    .font(.caption)
                                    .foregroundStyle(skin.resolvedTextTertiary)
                                    .help("Showing cached data — events refresh when sync resumes")
                                    .accessibilityLabel("Showing cached data")
                            }
                        }
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Open command palette \u{2318}K")
            .accessibilityLabel("\(screen.headerTitle). Open command palette.")

            Spacer(minLength: 0)
            filterToggleButton
            if screen.filteredEventsByDay.count > 1 {
                dayNavCluster(scroll: scrollProxy)
            }
        }
    }

    /// Slim actions row beneath the day title — the date leads the
    /// panel, the optimizer verbs follow.
    @ViewBuilder
    private var actionRail: some View {
        if let backlog = optimizerService.backlogService {
            SmartActionsBar(
                backlogService: backlog,
                optimizerService: optimizerService,
                reminderService: reminderService,
                onScheduleBacklog: {
                    await runQuickAction(.scheduleBacklog, label: "Scheduled backlog")
                },
                onFocusOnDeadlines: {
                    await runQuickAction(.deadlineMode, label: "Focused on deadlines")
                },
                onRunRequest: { request, label in
                    await runQuickAction(request, label: label)
                },
                onOpenPalette: {
                    Haptics.tap()
                    withAnimation(DS.Animation.quick) {
                        screen.paletteContext = MenuBarPaletteContext()
                    }
                },
                onEnterFullscreen: {
                    screen.navigation = .backlog
                },
                onUndoableAction: { message, undo in
                    screen.toastState.showSuccess(
                        message,
                        icon: "arrow.uturn.backward",
                        onUndo: undo
                    )
                },
                quickCapturePresented: $screen.showingQuickCapture
            )
            .background(
                GeometryReader { geo in
                    Color.clear.preference(
                        key: OptimizerBottomKey.self,
                        value: geo.frame(in: .named(menuBarRootCoordinateSpace)).maxY
                    )
                }
            )
            // PRINCIPLES §2 — no outer vertical nudge; the rail's own
            // padding and the next band's chrome carry the rhythm.
            .padding(.horizontal, DS.Spacing.contentMargin)
        }
    }

    /// Events — the syncing panel, the empty states, or the day list.
    /// The timeline is intentionally NOT wrapped in a platter card.
    @ViewBuilder
    private var timelineContent: some View {
        Group {
            if reminderService.nonDisintegratingEventCount == 0 {
                // Cold start: brief «Syncing calendars…» panel while
                // the first sync is running, otherwise the empty state.
                if screen.showSyncingState {
                    syncingState
                } else {
                    EmptyState(
                        pendingTaskCount: screen.pendingTaskCount,
                        subtitle: screen.emptyStateSubtitle,
                        showCalendarSettingsLink: screen.calendarHasAccess && settings.isCalendarSyncEnabled,
                        onAddEvent: { screen.navigation = .addEvent() },
                        onAdjustCalendars: {
                            SettingsViewModel.pendingPane = .calendars
                            openSettings()
                            NSApp.activate()
                        }
                    )
                }
            } else if screen.filteredEventsByDay.isEmpty {
                VStack(spacing: DS.Spacing.sm) {
                    Text(screen.emptyFilteredStateMessage)
                        .font(.subheadline)
                        .foregroundStyle(skin.resolvedTextSecondary)
                    Button("Clear filter") {
                        screen.clearFilters()
                    }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                eventList
            }
        }
        .animation(DS.Animation.smoothSpring, value: reminderService.nonDisintegratingEventCount == 0)
    }

    /// Cold-start sync panel — quiet `ProgressView` + caption. After
    /// 3 s without data the caption escalates to a long-running
    /// hint with a link to the system Calendars settings.
    @ViewBuilder
    var syncingState: some View {
        VStack(spacing: DS.Spacing.md) {
            ProgressView()
                .controlSize(.regular)
            if screen.initialSyncTimeoutFired {
                VStack(spacing: DS.Spacing.xs) {
                    Text("Sync is taking longer than usual.")
                        .font(.subheadline)
                        .foregroundStyle(skin.resolvedTextSecondary)
                    Button {
                        Haptics.tap()
                        SettingsViewModel.pendingPane = .calendars
                        openSettings()
                        NSApp.activate()
                    } label: {
                        Text("Check Calendar Settings \u{2192}")
                            .font(.footnote.weight(.regular))
                            .foregroundStyle(skin.accentColor)
                    }
                    .buttonStyle(.plain)
                }
            } else {
                Text("Syncing calendars\u{2026}")
                    .font(.subheadline)
                    .foregroundStyle(skin.resolvedTextSecondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.vertical, DS.Spacing.xxl)
        .transition(.opacity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(screen.initialSyncTimeoutFired
            ? "Sync is taking longer than usual. Tap to check Calendar settings."
            : "Syncing calendars")
    }

    /// Parallax fraction applied to `listScrollY` before it reaches the
    /// wallpaper. 0.15 was tuned by hand. Returns 0 when Reduce Motion
    /// is on or when not on the list view.
    var parallaxOffset: CGFloat {
        guard screen.navigation == .list, !reduceMotion else { return 0 }
        let raw = screen.listScrollY * 0.15
        return max(-40, min(40, raw))
    }

    var eventList: some View {
        EventList(
            scrollPositionID: $screen.scrollPositionID,
            listScrollY: $screen.listScrollY,
            days: screen.timelineDays(),
            extraDaysShown: screen.extraDaysShown,
            extraDaysCap: MenuBarScreenModel.extraDaysCap,
            onLoadMoreDays: {
                withAnimation(DS.Animation.smoothSpring) {
                    screen.loadMoreDays()
                }
            },
            disintegratingEventIDs: reminderService.disintegratingEventIDs,
            // The Unscheduled shelf is CONTENT, not chrome — it scrolls
            // with the canvas as its first block (REDESIGN.md R1).
            leadingContent: { unscheduledShelf },
            dayHeader: { day in
                dayGroupHeader(date: day.date, events: day.events)
            },
            daySection: { day in
                dayGroupSection(day)
            }
        )
    }

    // MARK: - Unscheduled shelf

    /// Pending backlog surfaced on the canvas (REDESIGN.md R1). Renders
    /// nothing when the backlog service is absent or nothing is pending.
    @ViewBuilder
    private var unscheduledShelf: some View {
        if let backlog = optimizerService.backlogService {
            UnscheduledShelfView(
                tasks: backlog.pending,
                expansion: $screen.unscheduledExpansion,
                onOpenTask: { task in
                    // Planner seeded with the task — the palette renders
                    // task-specific suggestions for the seed.
                    withAnimation(DS.Animation.quick) {
                        screen.paletteContext = MenuBarPaletteContext(seedTask: task)
                    }
                },
                onOpenAll: {
                    screen.navigation = .backlog
                }
            )
        }
    }

    // MARK: - Quick Add commits
    //
    // The unified «Add» front door (UX_AUDIT.md F8): QuickAddView parses
    // the text, these handlers commit the interpretation. Both paths are
    // «sequential magic» — direct mutation plus an undo toast, no form —
    // with ⇧↩ escaping to the detailed form via `routeQuickAddDetails`.

    /// Task interpretation → backlog, mirroring `handleCapturedBacklogTask`
    /// (the ⇧⌘N path) so both capture surfaces behave identically.
    func handleQuickAddTask(_ title: String, explicitMinutes: Int?) {
        guard let backlog = optimizerService.backlogService else { return }
        let minutes = explicitMinutes
            ?? BacklogTitleParser.guessDuration(for: title)
        let task = minutes.map { BacklogTask(title: title, durationMinutes: $0) }
            ?? BacklogTask(title: title)
        backlog.addTask(task)
        let trimmed = title.count > 32 ? String(title.prefix(32)) + "\u{2026}" : title
        screen.toastState.showSuccess(
            "Added \u{201C}\(trimmed)\u{201D}",
            icon: "plus.circle.fill"
        ) {
            _ = backlog.removeTask(id: task.id)
        }
    }

    /// Event interpretation → local calendar event, same idiom as the
    /// drag-to-slot path (`scheduleBacklogTask`): create + undo toast.
    func handleQuickAddEvent(_ title: String, start: Date, minutes: Int) {
        let eventId = "quick-\(UUID().uuidString)"
        let event = CalendarEvent(
            id: eventId,
            title: title,
            startDate: start,
            endDate: start.addingTimeInterval(TimeInterval(minutes * 60)),
            location: nil,
            description: nil,
            calendarName: "Local",
            eventType: .standard
        )
        reminderService.addLocalEvent(event)

        let fmt = DateFormatter()
        fmt.setLocalizedDateFormatFromTemplate("H:mm")
        let day = Calendar.current.isDateInToday(start)
            ? fmt.string(from: start)
            : start.formatted(date: .abbreviated, time: .shortened)
        screen.toastState.showSuccess(
            "\(title) \u{2192} \(day)",
            icon: "calendar.badge.plus"
        ) {
            reminderService.removeLocalEvent(id: eventId)
            notifyScheduleChange(deleted: eventId)
        }
        notifyScheduleChange(created: true)
    }

    /// ⇧↩ — the user wants the detailed form. Route the interpretation
    /// to the matching editor pre-filled; the popover closes first so
    /// the navigation transition isn't hidden behind it.
    func routeQuickAddDetails(_ interpretation: QuickAddParser.Interpretation) {
        screen.showingQuickAdd = false
        switch interpretation {
        case .task(let title, let minutes):
            screen.navigation = .newTask(prefillTitle: title, prefillDuration: minutes)
        case .event(let title, let start, let minutes):
            let draft = CalendarEvent(
                id: UUID().uuidString,
                title: title == "Untitled" ? "" : title,
                startDate: start,
                endDate: start.addingTimeInterval(TimeInterval(minutes * 60)),
                location: nil,
                description: nil,
                calendarName: nil,
                eventType: .standard
            )
            screen.navigation = .addEvent(prefillFrom: draft)
        }
    }

}
