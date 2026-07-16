import SwiftUI
import AppKit
import BuboDomain

// MARK: - Main Content
//
// The `.list` destination's content: PopoverHeader + inline suggestion +
// World Clock strip + filter bar + SmartActions bar + LazyVStack timeline
// (or empty / syncing / no-match states) + FooterActions.

// MARK: - Header title-line alignment

/// Custom vertical alignment for the header's top row: the trailing
/// controls (filter glyph, day-nav cluster) center against the TITLE
/// LINE. `.firstTextBaseline` parked the glyphs on the big title's
/// baseline — SF Symbols hang below a baseline, so they read as
/// sagging — and `.center` would center them against the whole
/// title+subtitle block, drifting them downward instead. The title
/// Text pins the guide to its own line's center; every view that
/// doesn't define the guide falls back to its own center.
private enum HeaderTitleCenterID: AlignmentID {
    static func defaultValue(in context: ViewDimensions) -> CGFloat {
        context[VerticalAlignment.center]
    }
}

extension VerticalAlignment {
    fileprivate static let headerTitleCenter = VerticalAlignment(HeaderTitleCenterID.self)
}

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
            // HIG toolbars: every toolbar verb needs a command-level
            // path — the chevrons can't be pointer-only.
            .keyboardShortcut(.leftArrow, modifiers: .command)
            .help("Previous day (\u{2318}\u{2190})")
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
            // ⌥⌘T — Calendar's ⌘T is already taken by «Tasks» here.
            .keyboardShortcut("t", modifiers: [.command, .option])
            .help("Jump to today (\u{2325}\u{2318}T)")
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
            .keyboardShortcut(.rightArrow, modifiers: .command)
            .help("Next day (\u{2318}\u{2192})")
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
        // The main screen's identity chrome, banded like every other
        // popover destination: `PopoverHeader` ends in a skin bar +
        // hairline everywhere else, and the resting screen was the
        // only one whose header bled into the canvas with nothing but
        // a gap. The bar holds the facts (date, verdict, clocks); the
        // Plan rail below stays on the canvas side — the workspace's
        // first verb, not part of the screen's identity. This is the
        // ONE structural line the screen gets — rows, clocks, and
        // rails stay unboxed (PRINCIPLES §2).
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: DS.Spacing.sm) {
                headerTitleRow(scrollProxy: scrollProxy)

                // World clock — one quiet line inside the header block
                // instead of a band of pills between header and canvas
                // (REDESIGN.md R2). An sm gap (the title/subtitle pair
                // keeps its tight 2 pt internally) separates the user's
                // facts from the machine-hint clock line — at xxs the
                // three lines read as one undifferentiated text blob.
                WorldClockInlineLine(settings: settings)
            }
            // Breathing room inside the bar: md above the title (the
            // popover's top edge), sm under the quiet clock line.
            .padding(.top, DS.Spacing.md)
            .padding(.bottom, DS.Spacing.sm)
            .padding(.horizontal, DS.Spacing.contentMargin)
            .frame(maxWidth: .infinity, alignment: .leading)
            .skinBarBackground(skin)

            SkinSeparator()
        }
    }

    /// Date title (palette entry point), filter toggle, and the day-nav
    /// cluster — the header block's top row.
    @ViewBuilder
    private func headerTitleRow(scrollProxy: ScrollViewProxy) -> some View {
        HStack(alignment: .headerTitleCenter) {
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
                            // Pin the row's optical axis to this line's
                            // center — trailing controls align to the
                            // title, not the title+subtitle block.
                            .alignmentGuide(.headerTitleCenter) { $0[VerticalAlignment.center] }
                        Text("\u{2318}K")
                            .font(DS.Typography.machineHint)
                            .foregroundStyle(skin.resolvedTextTertiary)
                    }
                    if !screen.headerSubtitle.isEmpty || reminderService.isUsingCache {
                        HStack(spacing: DS.Spacing.xs) {
                            if !screen.headerSubtitle.isEmpty {
                                Text(screen.headerSubtitle)
                                    .font(DS.Typography.row(skin: skin))
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

    /// REDESIGN.md R3 — the action rail is ONE adaptive verb. The old
    /// four-chip rail (hard «Schedule overflow» / soft suggestion /
    /// ranked calm action / Plan, plus the Backlog entry chip that
    /// duplicated the Unscheduled shelf one band below) collapsed into
    /// a single «Plan» chip whose label carries the forecast; every
    /// planner verb lives inside the palette — the single planner home.
    @ViewBuilder
    private var actionRail: some View {
        if let backlog = optimizerService.backlogService {
            ChipRow {
                planVerbChip(backlog: backlog)
            }
            .background(
                GeometryReader { geo in
                    Color.clear.preference(
                        key: OptimizerBottomKey.self,
                        value: geo.frame(in: .named(menuBarRootCoordinateSpace)).maxY
                    )
                }
            )
            .padding(.horizontal, DS.Spacing.contentMargin)
            // The rail's own chrome (PRINCIPLES §2 — rhythm belongs to
            // the band): one quiet beat between header and canvas —
            // sm on both sides, matching the header block's internal
            // rhythm so the top of the screen reads as an even ladder
            // (title → clocks → Plan) instead of a 4 pt squeeze.
            .padding(.vertical, DS.Spacing.sm)
        }
    }

    /// The planner's front door, state on the label:
    ///   fits        → «Plan»                          (quiet)
    ///   over        → «Plan · 2 h over»               (warning tint)
    ///   afterHours  → «Plan · 2 h queued»             (quiet — parked
    ///                  work is a fact, not an alarm; PRINCIPLES §7)
    @ViewBuilder
    private func planVerbChip(backlog: BacklogService) -> some View {
        let active = BacklogLogic.activeTasks(backlog.tasks)
        let pending = active.reduce(0) { $0 + $1.durationMinutes }
        // UX_AUDIT F10 (decided 2026-07-05): the capacity verdict reads
        // the CLOCK only — working hours, any day. `workingDays` stays
        // an auto-placement rule for the GA; passing it here made a
        // Sunday say «queued» while the timeline offered «Free · ~10½ h».
        // Today's verdict honours today's per-day override — the chip
        // and the timeline must read the same window.
        let forecast = BacklogLogic.capacityForecast(
            pendingMinutes: pending,
            workingHours: optimizerService.workingHours(on: screen.nowTick)
        )

        Group {
            switch forecast {
            case .over(let byMinutes):
                ChipButton(
                    variant: .status(skin.resolvedWarningColor),
                    icon: "wand.and.stars",
                    title: "Plan \u{00B7} \(DS.formatMinutes(byMinutes)) over"
                ) {
                    openPlanner()
                }
            case .afterHours(let queuedMinutes):
                ChipButton(
                    variant: .quiet,
                    icon: "wand.and.stars",
                    title: "Plan \u{00B7} \(DS.formatMinutes(queuedMinutes)) queued"
                ) {
                    openPlanner()
                }
            case .fits:
                ChipButton(
                    variant: .quiet,
                    icon: "wand.and.stars",
                    title: "Plan"
                ) {
                    openPlanner()
                }
            }
        }
        .help("Open the planner — presets, focus blocks, week planning (\u{2318}K)")
        .accessibilityLabel("Open the planner")
    }

    /// One palette-open path for the rail and its future callers.
    private func openPlanner() {
        Haptics.tap()
        withAnimation(DS.Animation.quick) {
            screen.paletteContext = MenuBarPaletteContext()
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
                        .font(DS.Typography.row(skin: skin))
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
                        .font(DS.Typography.row(skin: skin))
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
                    .font(DS.Typography.row(skin: skin))
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

    // MARK: - Quick Add commit
    //
    // The one-line task capture behind the footer's «Quick Add…» menu
    // item / ⇧⌘N (UX_AUDIT.md F8 amendments): QuickAddView parses the
    // trailing duration, this handler commits — «sequential magic»,
    // direct mutation plus an undo toast, no form. ⇧↩ escapes to
    // `NewTaskView` (routed inside `FooterActions`); events go through
    // the New Event form, the footer's primary action.

    /// Captured task → backlog, mirroring `handleCapturedBacklogTask`
    /// (the ⌃⇧⌘Space path) so both capture surfaces behave identically.
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

}
