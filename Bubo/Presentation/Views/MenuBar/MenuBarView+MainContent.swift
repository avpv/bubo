import SwiftUI
import AppKit
import BuboDomain

// MARK: - Main Content (v2)
//
// Popover shell rebuilt around the JTBD-derived anchors:
//   • compact header — date + week-strip nav + filter menu + ⌘K hint
//   • energy ribbon  — 10pt sparkline + current-energy verdict
//   • now-zone       — 0…2 cards by situation (in-meeting, soon,
//                       overflow, free-slot-with-proposal)
//   • event list     — unchanged, still owns drag-drop and slot-picker
//   • footer         — unchanged FooterActions
//
// The pre-redesign chrome (SmartActionsBar, BUBO eyebrow, day-nav
// cluster, SHOW filter pill, world-clock strip by default) is gone.
// World clocks remain available via Settings → World Clock → «Show in
// menu-bar popover» so distributed teams can opt in.

extension MenuBarView {

    // MARK: - NOW Marker (kept — consumed by `dayGroupSection`)

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

    func nowMarkerLabel(_ date: Date) -> String {
        let fmt = DateFormatter()
        fmt.setLocalizedDateFormatFromTemplate("H:mm")
        return fmt.string(from: date)
    }

    // MARK: - Inline status row

    /// Single thin status row — highest-priority issue only. Hidden when
    /// everything is healthy so the surface stays quiet.
    @ViewBuilder
    var inlineStatusRow: some View {
        if !networkMonitor.isConnected {
            StatusBanner(
                icon: "wifi.slash",
                text: "No internet — calendar data may be outdated",
                color: skin.resolvedWarningColor
            )
        } else if reminderService.isUsingCache {
            StatusBanner(
                icon: "arrow.triangle.2.circlepath",
                text: "Showing cached data",
                color: skin.resolvedWarningColor
            )
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

    var mainContent: some View {
        ScrollViewReader { scrollProxy in
            VStack(alignment: .leading, spacing: 0) {

                MenuBarHeaderV2View(
                    focusedDate: focusedDateOrToday,
                    weekDates: weekStripDates,
                    densityFor: { date in dayBusyDensity(for: date) },
                    usedColors: usedColorTags,
                    colorFilter: $colorFilter,
                    freeSlotFilter: $freeSlotFilter,
                    onSelectDate: { date in
                        navigateToDate(date, scroll: scrollProxy)
                    },
                    onOpenPalette: {
                        Haptics.tap()
                        withAnimation(DS.Animation.quick) {
                            paletteContext = MenuBarPaletteContext()
                        }
                    }
                )

                EnergyRibbonView(
                    curve: energyCurveForFocusedDay,
                    workingHours: optimizerService.workingHours,
                    now: nowTick
                )

                if settings.isWorldClockEnabled && settings.showWorldClocksInPopover && !settings.worldClockCityIDs.isEmpty {
                    WorldClockStripView(settings: settings)
                        .fixedSize(horizontal: false, vertical: true)
                }

                inlineStatusRow

                NowZoneView(
                    cards: nowZoneCards,
                    onJoinMeeting: { event in
                        if let url = event.meetingLink {
                            NSWorkspace.shared.open(url)
                        }
                    },
                    onAcceptOverflow: {
                        Task {
                            await runQuickAction(.scheduleBacklog, label: "Scheduled overflow")
                        }
                    },
                    onShowOverflowAlternatives: {
                        Haptics.tap()
                        withAnimation(DS.Animation.quick) {
                            paletteContext = MenuBarPaletteContext()
                        }
                    },
                    onStartFreeSlotTask: {
                        Haptics.tap()
                        navigation = .backlog
                    },
                    onOpenEvent: { event in
                        navigation = .detail(event)
                    }
                )
                .background(
                    // Anchors the command-palette overlay just below
                    // the top chrome. The pre-redesign popover read
                    // this from `SmartActionsBar`; with the bar gone,
                    // the now-zone's bottom edge is the new reference
                    // point. Empty `NowZoneView` still emits a frame
                    // (zero-height), so the publisher always fires.
                    GeometryReader { geo in
                        Color.clear.preference(
                            key: OptimizerBottomKey.self,
                            value: geo.frame(in: .named(menuBarRootCoordinateSpace)).maxY
                        )
                    }
                )

                // Events — fill remaining space so header stays pinned.
                Group {
                    if reminderService.nonDisintegratingEventCount == 0 {
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

                FooterActions(
                    navigation: $navigation,
                    reminderService: reminderService,
                    toastState: toastState,
                    activeSkin: activeSkin,
                    workingHours: optimizerService.workingHoursStart...optimizerService.workingHoursEnd,
                    workingDays: optimizerService.workingDays
                )
            }
        }
    }

    // MARK: - Sub-views and helpers

    /// Cold-start sync panel — quiet `ProgressView` + caption.
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
        .accessibilityLabel(initialSyncTimeoutFired
            ? "Sync is taking longer than usual. Tap to check Calendar settings."
            : "Syncing calendars")
    }

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
            leadingContent: { EmptyView() },
            dayHeader: { day in
                dayGroupHeader(date: day.date, events: day.events)
            },
            daySection: { day in
                dayGroupSection(day)
            }
        )
    }

    // MARK: - Header derivations

    /// Focused day from `focusedDayDate`, falling back to today. Drives
    /// header title and energy curve.
    var focusedDateOrToday: Date {
        focusedDayDate ?? Calendar.current.startOfDay(for: nowTick)
    }

    /// Seven days starting from today — the week-strip horizon. Anchored
    /// on today rather than the focused day so the «today» tick stays at
    /// the leftmost position regardless of navigation.
    var weekStripDates: [Date] {
        let cal = Calendar.current
        let start = cal.startOfDay(for: nowTick)
        return (0..<7).compactMap { cal.date(byAdding: .day, value: $0, to: start) }
    }

    /// Booked fraction (0…1) inside the working-hours window for `date`.
    /// Same denominator as the menu-bar density bar in `App.swift` so the
    /// strip reads identically across the icon and the popover.
    func dayBusyDensity(for date: Date) -> Double {
        let cal = Calendar.current
        let dayStart = cal.startOfDay(for: date)
        guard
            let workStart = cal.date(bySettingHour: optimizerService.workingHoursStart, minute: 0, second: 0, of: dayStart),
            let workEnd = cal.date(bySettingHour: optimizerService.workingHoursEnd, minute: 0, second: 0, of: dayStart),
            workEnd > workStart
        else { return 0 }

        let windowSeconds = workEnd.timeIntervalSince(workStart)
        guard windowSeconds > 0 else { return 0 }

        let booked = reminderService.allEvents.reduce(0.0) { acc, event in
            let start = max(event.startDate, workStart)
            let end = min(event.endDate, workEnd)
            return acc + max(0, end.timeIntervalSince(start))
        }
        return min(1.0, booked / windowSeconds)
    }

    /// Scroll the timeline to `date` and pin it as the focused day.
    func navigateToDate(_ date: Date, scroll: ScrollViewProxy) {
        Haptics.tap()
        focusedDayDate = date
        withAnimation(DS.Animation.smoothSpring) {
            scroll.scrollTo(date, anchor: .top)
        }
    }

    // MARK: - Energy curve

    /// 24-hour predicted energy curve for the focused day. Falls back to
    /// the static default Gaussian centred on the working-hours midpoint
    /// if `EnergyCheckInService` hasn't been wired (defensive — the
    /// optimizer service always carries one in production).
    var energyCurveForFocusedDay: [Double] {
        let date = focusedDateOrToday
        let cal = Calendar.current
        let dow = cal.component(.weekday, from: date)
        let meetingCount = reminderService.allEvents.filter { cal.isDate($0.startDate, inSameDayAs: date) }.count
        let peakHour = (optimizerService.workingHoursStart + optimizerService.workingHoursEnd) / 2
        if let service = optimizerService.energyCheckInService {
            return service.predictedCurve(dayOfWeek: dow, meetingCount: meetingCount, defaultPeakHour: peakHour)
        }
        return (0..<24).map { h in
            let x = Double(h - peakHour)
            return exp(-(x * x) / 18.0)
        }
    }

    // MARK: - Now-zone

    /// Stack of 0…2 cards derived from today's events and backlog.
    var nowZoneCards: [NowZoneCard] {
        let cal = Calendar.current
        let now = nowTick
        let todayEvents = reminderService.allEvents
            .filter { cal.isDateInToday($0.startDate) }
            .filter { !reminderService.disintegratingEventIDs.contains($0.id) }

        let pending = optimizerService.backlogService?.pending ?? []
        let topTitle = pending.first?.title
        let topMinutes = pending.first?.durationMinutes
        let unscheduledMinutes = pending.reduce(0) { $0 + $1.durationMinutes }
        let remainingWorking = remainingWorkingMinutesToday(now: now, cal: cal)

        return NowZoneState.derive(
            now: now,
            todayEvents: todayEvents,
            pendingBacklogTitle: topTitle,
            pendingBacklogMinutes: topMinutes,
            unscheduledMinutes: unscheduledMinutes,
            remainingWorkingMinutes: remainingWorking,
            workingHours: optimizerService.workingHours
        )
    }

    /// Minutes between `now` and the end of today's working window,
    /// clamped to zero outside hours. Used to decide whether the pending
    /// backlog overflows.
    func remainingWorkingMinutesToday(now: Date, cal: Calendar) -> Int {
        guard
            let workEnd = cal.date(
                bySettingHour: optimizerService.workingHoursEnd,
                minute: 0,
                second: 0,
                of: now
            )
        else { return 0 }
        let delta = workEnd.timeIntervalSince(now) / 60
        return max(0, Int(delta))
    }
}
