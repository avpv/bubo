import SwiftUI
import AppKit

// MARK: - Main Content
//
// The `.list` destination's content: PopoverHeader + status banners +
// World Clock strip + EOD banner + filter bar + SmartActions bar +
// NowNextLine + separator + LazyVStack timeline (or empty / syncing /
// no-match states) + FooterActions. Also the small siblings used by
// the header (day-nav cluster, NOW marker) and the parallax / sync
// gating helpers consumed by `body`.

extension MenuBarView {

    // MARK: - NOW Marker

    /// Inline «NOW · 10:48» rule, dropped into today's interleaved
    /// timeline so the past/future boundary reads at a glance —
    /// matches the prototype's `.now-line`.
    @ViewBuilder
    func nowMarkerRow(_ stamp: Date) -> some View {
        HStack(spacing: DS.Spacing.xs) {
            Rectangle()
                .fill(skin.resolvedDestructiveColor.opacity(DS.Opacity.strongFill * 2))
                .frame(height: 1)
            Text("NOW \u{00B7} \(nowMarkerLabel(stamp))")
                .font(.caption2.weight(.semibold).monospacedDigit())
                .foregroundStyle(skin.resolvedDestructiveColor)
                .tracking(0.5)
                .fixedSize()
            Rectangle()
                .fill(skin.resolvedDestructiveColor.opacity(DS.Opacity.strongFill * 2))
                .frame(height: 1)
        }
        .padding(.horizontal, DS.Spacing.xs)
        .padding(.vertical, DS.Spacing.xxs)
        .accessibilityLabel("Now \(nowMarkerLabel(stamp))")
    }

    /// Locale-aware `H:mm` for the NOW marker — same formatter style
    /// as `NowNextLine.timeLabel(_:)` so the two surfaces stay in sync.
    func nowMarkerLabel(_ date: Date) -> String {
        let fmt = DateFormatter()
        fmt.setLocalizedDateFormatFromTemplate("H:mm")
        return fmt.string(from: date)
    }

    // MARK: - Day-nav cluster

    /// Three-button day-nav cluster (`← Today →`) for the popover
    /// header trailing area. Taps scroll the list to the requested
    /// day's section.
    @ViewBuilder
    func dayNavCluster(scroll: ScrollViewProxy) -> some View {
        let days = filteredEventsByDay
        let idx = focusedDayIndex
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
                    .opacity(focusedDayIsToday ? 0.4 : 1.0)
            }
            .buttonStyle(.borderless)
            .disabled(focusedDayIsToday)
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

    // MARK: - Main Content

    var mainContent: some View {
        ScrollViewReader { scrollProxy in
        VStack(alignment: .leading, spacing: 0) {
            PopoverHeader(
                title: headerTitle,
                subtitle: headerSubtitle,
                trailing: AnyView(
                    HStack(spacing: DS.Spacing.sm) {
                        StatusIndicators(networkMonitor: networkMonitor, reminderService: reminderService)

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

                        // Day-nav cluster — only worth showing when the
                        // timeline spans more than today.
                        if filteredEventsByDay.count > 1 {
                            dayNavCluster(scroll: scrollProxy)
                        }
                    }
                )
            )

            // Status messages — show at most one banner to avoid stacking.
            if !networkMonitor.isConnected {
                StatusBanner(
                    icon: "wifi.slash",
                    text: "No internet — calendar data may be outdated",
                    color: skin.resolvedWarningColor
                )
            } else if !permissionBannerSpecs.isEmpty {
                PermissionBannersCarousel(specs: permissionBannerSpecs)
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

            // Main-Job fix #6 — "rules are objects on the screen".
            // The strip lists every active optimizer rule (working
            // hours, working days, peak energy, locked / excluded
            // counts, capacity forecast) so the user can audit what
            // the machine knows at a glance. Tap on a chip routes to
            // the appropriate Settings pane.
            OptimizerRulesStrip(
                workingHours: optimizerService.workingHoursStart...optimizerService.workingHoursEnd,
                workingDays: optimizerService.workingDays,
                peakEnergyHours: optimizerService.optimizer.preferences.peakEnergyHours,
                lockedCount: optimizerService.lockedEventIds.count,
                excludedCount: optimizerService.excludedEventIds.count,
                capacityForecast: optimizerRulesCapacityForecast,
                onEdit: { _ in
                    // Route to Settings > Optimizer; per-anchor deep
                    // links can be added once the Settings navigation
                    // exposes section anchors.
                    openSettings()
                }
            )
            .fixedSize(horizontal: false, vertical: true)

            // E1: morning brief — surfaces what the optimizer did
            // overnight (deferral count + plan refresh) the first time
            // the popover opens on a new calendar day. The banner
            // makes invisible background work visible — closing the
            // "Bubo doesn't feel like a delegated employee" gap.
            if shouldShowMorningBriefBanner {
                MorningBriefBanner(
                    deferredCount: morningBriefDeferred,
                    detail: morningBriefDeferred > 0
                        ? "Overdue tasks carried forward into today's plan."
                        : "Your plan stayed fresh through the night.",
                    onDismiss: { dismissMorningBriefForToday() },
                    onShowDetails: morningBriefDeferred > 0
                        ? { navigation = .backlog }
                        : nil
                )
            }

            // J10: end-of-day carry-forward prompt. Visible only after
            // working hours have closed for today with unfinished tasks.
            if shouldShowEndOfDayBanner {
                EndOfDayBanner(
                    unfinishedCount: eodUnfinishedCount,
                    onCarry: { carryUnfinishedToTomorrow() },
                    onDismiss: { dismissEndOfDayBannerForToday() }
                )
                .padding(.horizontal, DS.Spacing.contentMargin)
                .padding(.vertical, DS.Spacing.xs)
            }

            // Filter bar — show whenever the timeline has anything to filter.
            if reminderService.nonDisintegratingEventCount > 0 {
                ColorFilterBar(colorFilter: $colorFilter, freeSlotFilter: $freeSlotFilter)
            }

            // SmartActions bar — the only optimizer entry point on the
            // main screen. Re-publishes `OptimizerBottomKey` from the
            // bar's bottom edge so the command palette popover anchors
            // right below it.
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
                            paletteContext = MenuBarPaletteContext()
                        }
                    },
                    onSwitchScenario: { index in
                        optimizerService.switchToAppliedScenario(
                            at: index,
                            to: reminderService
                        )
                    },
                    onLockTodaysEvents: {
                        let cal = Calendar.current
                        let todaysIds = reminderService.allEvents
                            .filter { cal.isDateInToday($0.startDate) }
                            .map(\.id)
                        let preCount = optimizerService.lockedEventIds.count
                        for id in todaysIds {
                            if !optimizerService.isLocked(eventId: id) {
                                optimizerService.toggleLock(eventId: id)
                            }
                        }
                        let added = optimizerService.lockedEventIds.count - preCount
                        if added > 0 {
                            toastState.showSuccess(
                                added == 1 ? "Locked 1\u{00A0}event" : "Locked \(added)\u{00A0}events",
                                icon: "lock.fill"
                            ) {
                                for id in todaysIds {
                                    if optimizerService.isLocked(eventId: id) {
                                        optimizerService.toggleLock(eventId: id)
                                    }
                                }
                            }
                        } else {
                            toastState.showInfo("Today's events are already locked", icon: "lock.fill")
                        }
                    },
                    onEnterFullscreen: {
                        navigation = .backlog
                    },
                    onUndoableAction: { message, undo in
                        toastState.showSuccess(
                            message,
                            icon: "arrow.uturn.backward",
                            onUndo: undo
                        )
                    },
                    quickCapturePresented: $showingQuickCapture
                )
                .background(
                    GeometryReader { geo in
                        Color.clear.preference(
                            key: OptimizerBottomKey.self,
                            value: geo.frame(in: .named(menuBarRootCoordinateSpace)).maxY
                        )
                    }
                )
                .padding(.horizontal, DS.Spacing.contentMargin)
                .padding(.top, DS.Spacing.sm)
            }

            // J-Triage status line — one-glance answer to «what now /
            // what's next / how many overdue». Auto-hides when there's
            // nothing to surface so the calm screen stays calm.
            let nowNext = NowNextLine(
                events: todaysEventsForNowNext,
                now: nowTick,
                overdueCount: optimizerService.backlogService?.overdue.count ?? 0,
                onOpenBacklog: { navigation = .backlog }
            )
            if nowNext.hasContent {
                nowNext.padding(.top, DS.Spacing.xs)
            }

            // Thin separator between controls cluster and timeline.
            SkinSeparator()
                .padding(.horizontal, DS.Spacing.contentMargin)
                .padding(.top, DS.Spacing.sm)

            // Events — fill remaining space so header stays pinned.
            // Timeline is intentionally NOT wrapped in a platter card.
            Group {
                if reminderService.nonDisintegratingEventCount == 0 {
                    // Cold start: brief «Syncing calendars…» panel while
                    // the first sync is running, otherwise the empty state.
                    if showSyncingState {
                        syncingState
                    } else {
                        EmptyState(
                            pendingTaskCount: pendingTaskCount,
                            subtitle: emptyStateSubtitle,
                            showCalendarSettingsLink: calendarHasAccess && settings.isCalendarSyncEnabled,
                            onAddEvent: { navigation = .addEvent() },
                            onAdjustCalendars: {
                                SettingsViewModel.pendingPane = .calendars
                                openSettings()
                                NSApp.activate()
                            }
                        )
                    }
                } else if filteredEventsByDay.isEmpty {
                    VStack(spacing: DS.Spacing.sm) {
                        Text(emptyFilteredStateMessage)
                            .font(.subheadline)
                            .foregroundStyle(skin.resolvedTextSecondary)
                        Button("Clear filter") {
                            colorFilter = nil
                            freeSlotFilter = .all
                        }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    eventList
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .animation(DS.Animation.smoothSpring, value: reminderService.nonDisintegratingEventCount == 0)

            SkinSeparator()
            FooterActions(
                navigation: $navigation,
                reminderService: reminderService,
                toastState: toastState,
                activeSkin: activeSkin,
                workingHours: optimizerService.workingHoursStart...optimizerService.workingHoursEnd,
                workingDays: optimizerService.workingDays
            )
        }
        } // ScrollViewReader
    }

    /// Cold-start sync panel — quiet `ProgressView` + caption. After
    /// 3 s without data the caption escalates to a long-running
    /// hint with a link to the system Calendars settings.
    @ViewBuilder
    var syncingState: some View {
        VStack(spacing: DS.Spacing.md) {
            ProgressView()
                .controlSize(.regular)
            if initialSyncTimeoutFired {
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
                            .font(.footnote.weight(.medium))
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
        .accessibilityLabel(initialSyncTimeoutFired
            ? "Sync is taking longer than usual. Tap to check Calendar settings."
            : "Syncing calendars")
    }

    /// Parallax fraction applied to `listScrollY` before it reaches the
    /// wallpaper. 0.15 was tuned by hand. Returns 0 when Reduce Motion
    /// is on or when not on the list view.
    var parallaxOffset: CGFloat {
        guard navigation == .list, !reduceMotion else { return 0 }
        let raw = listScrollY * 0.15
        return max(-40, min(40, raw))
    }

    var eventList: some View {
        EventList(
            scrollPositionID: $scrollPositionID,
            listScrollY: $listScrollY,
            days: timelineDays(),
            extraDaysShown: extraDaysShown,
            extraDaysCap: Self.extraDaysCap,
            onLoadMoreDays: {
                withAnimation(DS.Animation.smoothSpring) {
                    extraDaysShown = min(Self.extraDaysCap, extraDaysShown + 7)
                }
            },
            disintegratingEventIDs: reminderService.disintegratingEventIDs,
            leadingContent: {
                // Energy check-in banner — wellness prompt; surfaces only
                // when a check-in is due so the calm timeline isn't
                // constantly capturing attention.
                if optimizerService.energyCheckInService?.pendingCheckIn == true {
                    EnergyCheckInBanner(
                        onRecord: { level in
                            withAnimation(DS.Animation.quick) {
                                optimizerService.energyCheckInService?.record(
                                    energyLevel: level,
                                    from: reminderService
                                )
                            }
                        },
                        onDismiss: {
                            withAnimation(DS.Animation.quick) {
                                optimizerService.energyCheckInService?.dismissCheckIn()
                            }
                        }
                    )
                }

                // End-of-workday roll-forward nudge.
                if shouldShowRollForward {
                    RollForwardBanner(
                        unfinishedCount: unfinishedTodayCount,
                        onRoll: {
                            performRollForward()
                        },
                        onDismiss: {
                            withAnimation(DS.Animation.quick) {
                                rollForwardDismissedDay = Calendar.current.startOfDay(for: nowTick)
                            }
                        }
                    )
                }
            },
            dayHeader: { day in
                dayGroupHeader(date: day.date, events: day.events)
            },
            daySection: { day in
                dayGroupSection(day)
            }
        )
    }

    // MARK: - Rules-strip helpers
    //
    // Computed inputs for `OptimizerRulesStrip`. Kept here (not on
    // SmartActionsBar) so the strip can render independently of the
    // backlog smart-actions surface, even when the backlog is empty.

    var optimizerRulesPendingMinutes: Int {
        guard let backlog = optimizerService.backlogService else { return 0 }
        return backlog.pending.reduce(0) { $0 + $1.durationMinutes }
    }

    var optimizerRulesCapacityForecast: BacklogLogic.CapacityForecast {
        BacklogLogic.capacityForecast(
            pendingMinutes: optimizerRulesPendingMinutes,
            workingHours: optimizerService.workingHours,
            workingDays: optimizerService.workingDays
        )
    }
}
