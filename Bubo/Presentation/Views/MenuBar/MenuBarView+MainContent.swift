import SwiftUI
import AppKit
import BuboDomain

// MARK: - Main Content
//
// The `.list` destination's content: PopoverHeader + inline suggestion +
// World Clock strip + filter bar + SmartActions bar + LazyVStack timeline
// (or empty / syncing / no-match states) + FooterActions.

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

    /// Locale-aware `H:mm` for the NOW marker.
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

    // MARK: - Inline status row

    /// Single thin status row — highest-priority issue only.
    /// Replaces the stack of mutually-exclusive `StatusBanner`s and the
    /// `PermissionBannersCarousel`. Hidden when everything is healthy.
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

    // MARK: - Focus summary

    /// Compact at-a-glance row that reduces scanning cost before entering
    /// the timeline. Surfaces only three numbers users check most often:
    /// today events, pending tasks, and free slots today.
    @ViewBuilder
    var focusSummaryRow: some View {
        let todayEvents = reminderService.events.filter { Calendar.current.isDateInToday($0.startDate) }.count
        let todayFreeSlots = filteredEventsByDay
            .first(where: { Calendar.current.isDateInToday($0.date) })?
            .slots.count ?? 0

        HStack(spacing: DS.Spacing.xs) {
            summaryPill(icon: "calendar", text: "Today: \(todayEvents)")
            summaryPill(icon: "checklist", text: "Tasks: \(pendingTaskCount)")
            summaryPill(icon: "circle.grid.2x2", text: "Free slots: \(todayFreeSlots)")
            Spacer(minLength: 0)
        }
        .padding(.horizontal, DS.Spacing.contentMargin)
        .padding(.bottom, DS.Spacing.xs)
    }

    @ViewBuilder
    private func summaryPill(icon: String, text: String) -> some View {
        HStack(spacing: DS.Spacing.xxs) {
            Image(systemName: icon)
                .font(.caption.weight(.semibold))
            Text(text)
                .font(.caption.weight(.medium))
                .monospacedDigit()
        }
        .foregroundStyle(skin.resolvedTextSecondary)
        .padding(.horizontal, DS.Spacing.xs)
        .padding(.vertical, DS.Spacing.hairline)
        .background(skin.resolvedHoverFill, in: Capsule())
    }

    // MARK: - Main Content

    var mainContent: some View {
        ScrollViewReader { scrollProxy in
        VStack(alignment: .leading, spacing: 0) {
            // Optimizer Command Bar (Command-First UI)
            Button {
                Haptics.tap()
                withAnimation(DS.Animation.quick) {
                    paletteContext = MenuBarPaletteContext()
                }
            } label: {
                HStack(spacing: DS.Spacing.sm) {
                    Image(systemName: "sparkles")
                        .foregroundStyle(skin.accentColor)
                        .font(.system(size: 16, weight: .medium))
                    
                    Text("Optimize schedule")
                        .font(DS.Typography.body(skin: skin))
                        .foregroundStyle(skin.resolvedTextSecondary)
                    
                    Spacer()
                    
                    Text("\u{2318}K")
                        .font(DS.Typography.machineHint)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(skin.resolvedButtonMaterial, in: RoundedRectangle(cornerRadius: 4))
                        .foregroundStyle(skin.resolvedTextTertiary)
                }
                .padding(.horizontal, DS.Spacing.md)
                .padding(.vertical, DS.Spacing.sm)
                .background(skin.resolvedButtonMaterial, in: RoundedRectangle(cornerRadius: DS.Size.cornerRadius))
                .overlay(
                    RoundedRectangle(cornerRadius: DS.Size.cornerRadius)
                        .strokeBorder(skin.resolvedTextPrimary.opacity(DS.Opacity.subtleBorder), lineWidth: DS.Border.thin)
                )
            }
            .buttonStyle(.plain)
            .padding(.horizontal, DS.Spacing.contentMargin)
            .padding(.top, DS.Spacing.md)
            .padding(.bottom, DS.Spacing.xs)

            // SmartActions bar immediately follows the command bar
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
                .padding(.bottom, DS.Spacing.sm)
            }

            // Date Header & Navigation
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(headerTitle)
                        .font(.headline)
                        .foregroundStyle(skin.resolvedTextPrimary)
                    if !headerSubtitle.isEmpty {
                        Text(headerSubtitle)
                            .font(.subheadline)
                            .foregroundStyle(skin.resolvedTextSecondary)
                    }
                }
                Spacer()
                if filteredEventsByDay.count > 1 {
                    dayNavCluster(scroll: scrollProxy)
                }
            }
            .padding(.horizontal, DS.Spacing.contentMargin)
            .padding(.bottom, DS.Spacing.sm)

            // Single inline status row — shows the highest-priority issue
            inlineStatusRow

            // Focus summary reduces top-of-screen visual noise by exposing
            // critical daily counters before the full timeline.
            focusSummaryRow

            // World Clock — only show when user has cities configured
            if !settings.worldClockCityIDs.isEmpty {
                WorldClockStripView(settings: settings)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // Filter bar — show whenever the timeline has anything to filter.
            if reminderService.nonDisintegratingEventCount > 0 {
                ColorFilterBar(colorFilter: $colorFilter, freeSlotFilter: $freeSlotFilter)
            }

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
            leadingContent: { EmptyView() },
            dayHeader: { day in
                dayGroupHeader(date: day.date, events: day.events)
            },
            daySection: { day in
                dayGroupSection(day)
            }
        )
    }

}
