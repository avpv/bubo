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
        VStack(alignment: .leading, spacing: 0) {
            // Apple-philosophy «one entry point». The standalone
            // «Optimize schedule» command bar was a chrome strip
            // duplicating an affordance that already lives on a
            // hotkey (⌘K) and was about to be cloned into the title
            // block too. Three entry points for the same verb. Now:
            // ⌘K continues to work, and the eyebrow+title block
            // itself is tappable to open the palette — the title is
            // the entry point, no separate bar above it.

            // Date / day title first — the popover leads with «what day
            // am I looking at», then the slim actions row beneath it. The
            // block is tappable to open the command palette
            // (Spotlight-style); the ⌘K hotkey continues to work.
            HStack(alignment: .firstTextBaseline) {
                Button {
                    Haptics.tap()
                    withAnimation(DS.Animation.quick) {
                        paletteContext = MenuBarPaletteContext()
                    }
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(alignment: .firstTextBaseline, spacing: DS.Spacing.xs) {
                            Text(headerTitle)
                                .font(DS.Typography.headline(skin: skin))
                                .foregroundStyle(skin.resolvedTextPrimary)
                            Text("\u{2318}K")
                                .font(DS.Typography.machineHint)
                                .foregroundStyle(skin.resolvedTextTertiary)
                        }
                        if !headerSubtitle.isEmpty || reminderService.isUsingCache {
                            HStack(spacing: DS.Spacing.xs) {
                                if !headerSubtitle.isEmpty {
                                    Text(headerSubtitle)
                                        .font(.subheadline)
                                        .foregroundStyle(skin.resolvedTextSecondary)
                                }
                                // Cached-data state demoted from a full-width
                                // warning banner to a quiet glyph: the data is
                                // still usable, and a banner-sized alarm for a
                                // routine offline read pushed the timeline a
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
                .accessibilityLabel("\(headerTitle). Open command palette.")

                Spacer(minLength: 0)
                if filteredEventsByDay.count > 1 {
                    dayNavCluster(scroll: scrollProxy)
                }
            }
            .padding(.horizontal, DS.Spacing.contentMargin)
            .padding(.bottom, DS.Spacing.sm)

            // Slim actions row — now beneath the day title, so the date
            // leads the panel and the optimizer verbs follow.
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

            // Single inline status row — already conditional, hidden
            // when everything is healthy. No chrome cost at rest.
            inlineStatusRow

            // World Clock — always visible (per design intent). The view
            // has its own internal guard, so it renders nothing when the
            // user has the strip disabled or no cities chosen; no empty bar.
            WorldClockStripView(settings: settings)
                .fixedSize(horizontal: false, vertical: true)

            // Filter bar — always visible (per design intent). Carries the
            // colour filters AND the free-slot picker, a primary affordance
            // for «find me a free window today», so it stays pinned even on
            // empty days rather than appearing only once events exist.
            ColorFilterBar(colorFilter: $colorFilter, freeSlotFilter: $freeSlotFilter)

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
