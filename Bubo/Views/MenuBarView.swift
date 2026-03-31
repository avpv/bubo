import SwiftUI

struct MenuBarView: View {
    @Environment(\.activeSkin) private var skin
    var settings: ReminderSettings
    var reminderService: ReminderService
    var networkMonitor: NetworkMonitor
    var optimizerService: OptimizerService

    @State private var navigation: Navigation = .list
    @State private var hasStartedSync = false
    @State private var toastState = ToastState()
    @State private var scrollPositionID: String?
    @State private var colorFilter: EventColorTag? = nil

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Enum-based navigation state machine replaces fragile boolean flags.
    enum Navigation: Equatable {
        case list
        case detail(CalendarEvent)
        case addEvent(editing: CalendarEvent? = nil)
        case timer(CalendarEvent)
        case optimizer

        var isTimer: Bool {
            if case .timer = self { return true }
            return false
        }

        var isOptimizer: Bool {
            if case .optimizer = self { return true }
            return false
        }

        static func == (lhs: Navigation, rhs: Navigation) -> Bool {
            switch (lhs, rhs) {
            case (.list, .list): return true
            case (.detail(let a), .detail(let b)): return a.id == b.id
            case (.addEvent(let a), .addEvent(let b)): return a?.id == b?.id
            case (.timer(let a), .timer(let b)): return a.id == b.id
            case (.optimizer, .optimizer): return true
            default: return false
            }
        }
    }

    private var activeSkin: SkinDefinition { settings.selectedSkin }

    var body: some View {
        ZStack {
            AppBackgroundLayer(
                skin: activeSkin,
                wallpaper: settings.selectedWallpaper,
                customPhotoPath: settings.customBackgroundPhotoPath,
                customPhotoOpacity: settings.customBackgroundPhotoOpacity,
                customPhotoBlur: settings.customBackgroundPhotoBlur,
                skinImageOverride: settings.skinImageOverrides[activeSkin.id]
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
                            reminderService.removeLocalEvent(id: event.id)
                            navigation = .list
                            toastState.showSuccess("Event deleted", icon: "trash.fill")
                        },
                        onDeleteSeries: { event in
                            let seriesId = event.seriesId ?? event.id
                            reminderService.removeLocalEvent(id: seriesId)
                            navigation = .list
                            toastState.showSuccess("All occurrences deleted", icon: "trash.fill")
                        },
                        onDeleteOccurrence: { event in
                            reminderService.excludeOccurrence(occurrenceId: event.id)
                            navigation = .list
                            toastState.showSuccess("Occurrence skipped", icon: "trash.fill")
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
                        onBack: { navigation = .detail(event) }
                    )
                    .transition(
                        reduceMotion ? .opacity : .asymmetric(
                            insertion: .move(edge: .trailing).combined(with: .opacity),
                            removal: .move(edge: .trailing).combined(with: .opacity).combined(with: .scale(scale: 0.98))
                        )
                    )

                case .addEvent(let editing):
                    AddEventView(
                        reminderService: reminderService,
                        editingEvent: editing,
                        onDismiss: { navigation = .list },
                        onSave: { isEdit in
                            navigation = .list
                            toastState.showSuccess(isEdit ? "Event updated" : "Event added")
                        }
                    )
                    .transition(
                        reduceMotion ? .opacity : .asymmetric(
                            insertion: .move(edge: .trailing).combined(with: .opacity),
                            removal: .move(edge: .trailing).combined(with: .opacity).combined(with: .scale(scale: 0.98))
                        )
                    )

                case .optimizer:
                    OptimizerView(
                        optimizerService: optimizerService,
                        reminderService: reminderService,
                        onBack: { navigation = .list }
                    )
                    .transition(
                        reduceMotion ? .opacity : .asymmetric(
                            insertion: .move(edge: .trailing).combined(with: .opacity),
                            removal: .move(edge: .trailing).combined(with: .opacity).combined(with: .scale(scale: 0.98))
                        )
                    )
                }
            }
            .animation(
                reduceMotion ? DS.Animation.quick : DS.Animation.smoothSpring,
                value: navigation
            )

            ToastOverlay(toastState: toastState)
        }
        .skinTinted(activeSkin)
        .skinTypography(activeSkin)
        .environment(\.activeSkin, activeSkin)
        .frame(width: DS.Popover.width, height: navigation.isTimer ? DS.Popover.timerHeight : DS.Popover.height)
        .onAppear {
            guard !hasStartedSync else { return }
            hasStartedSync = true
            reminderService.updateSettings(settings)
            reminderService.startSync()
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
        reminderService.removeLocalEvent(id: event.id)
        toastState.showSuccess("Event deleted", icon: "trash.fill")
    }

    // MARK: - Main Content

    private var mainContent: some View {
        ScrollViewReader { scrollProxy in
        VStack(alignment: .leading, spacing: 0) {
            PopoverHeader(
                title: "Bubo",
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

            // Status messages
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
            }

            if settings.isCalendarSyncEnabled {
                if !AppleCalendarService.hasAccess {
                    CalendarAccessBanner()
                        .frame(maxWidth: .infinity, alignment: .center)
                } else if let error = reminderService.syncError, networkMonitor.isConnected {
                    StatusBanner(icon: "exclamationmark.triangle.fill", text: error, color: skin.resolvedWarningColor)
                        .frame(maxWidth: .infinity, alignment: .center)
                }
            }

            // Color filter — only show when there are multiple distinct colors to filter by
            if usedColorTags.count > 1 {
                colorFilterBar
            }

            // Events
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
            .animation(DS.Animation.smoothSpring, value: reminderService.nonDisintegratingEventCount == 0)

            SkinSeparator()

            if let lastSync = reminderService.lastSyncDate {
                HStack(spacing: DS.Spacing.xs) {
                    Text("Updated")
                    Text(lastSync, style: .relative)
                    Text("ago")
                }
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, DS.Spacing.xs)
            }

            footerActions
        }
        } // ScrollViewReader
    }

    // MARK: - Subviews

    private var statusIndicators: some View {
        HStack(spacing: DS.Spacing.sm) {
            if !networkMonitor.isConnected {
                Image(systemName: "wifi.slash")
                    .foregroundStyle(DS.Colors.error)
                    .font(.system(size: DS.Size.iconSmall))
                    .symbolEffect(.pulse, options: .repeating.speed(0.5))
                    .help("No internet connection")
                    .accessibilityLabel("No internet connection")
                    .transition(.scale.combined(with: .opacity))
            }

            if reminderService.isSyncing {
                ProgressView()
                    .scaleEffect(0.5)
                    .frame(width: DS.Size.syncIndicatorSize, height: DS.Size.syncIndicatorSize)
                    .transition(.scale.combined(with: .opacity))
            }
        }
        .animation(skin.resolvedMicroAnimation, value: networkMonitor.isConnected)
        .animation(skin.resolvedMicroAnimation, value: reminderService.isSyncing)
    }

    private var emptyState: some View {
        VStack(spacing: DS.EmptyState.spacing) {
            Image(systemName: "calendar.badge.checkmark")
                .font(.system(size: DS.EmptyState.iconSize))
                .foregroundStyle(DS.Colors.accent, skin.resolvedTextSecondary)
                .symbolEffect(.pulse, options: .repeating.speed(0.2))
            Text("No upcoming meetings")
                .font(.subheadline)
                .fontWeight(.medium)
                .foregroundStyle(skin.resolvedTextSecondary)
            Text("Your schedule is clear")
                .font(.caption)
                .foregroundStyle(skin.resolvedTextTertiary)
            Button {
                Haptics.tap()
                navigation = .addEvent()
            } label: {
                Label("Add Event", systemImage: "plus")
                    .font(.caption)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.vertical, DS.Spacing.xxl)
        .transition(.opacity.combined(with: .scale(scale: 0.95)))
    }

    private var usedColorTags: [EventColorTag] {
        let allEvents = reminderService.eventsByDay.flatMap(\.events)
        let usedTags = Set(allEvents.compactMap(\.colorTag))
        return EventColorTag.allCases.filter { usedTags.contains($0) }
    }

    private var colorFilterBar: some View {
        HStack(spacing: DS.Spacing.xs) {
            ForEach(usedColorTags, id: \.self) { tag in
                Button {
                    Haptics.tap()
                    withAnimation(skin.resolvedMicroAnimation) {
                        colorFilter = colorFilter == tag ? nil : tag
                    }
                } label: {
                    Circle()
                        .fill(tag.color)
                        .frame(width: 24, height: 24)
                        .opacity(colorFilter == nil || colorFilter == tag ? 1.0 : 0.3)
                        .scaleEffect(colorFilter == tag ? 1.1 : 1.0)
                        .overlay(
                            Circle()
                                .stroke(Color.white, lineWidth: colorFilter == tag ? 1.5 : 0)
                        )
                        .shadow(
                            color: colorFilter == tag ? tag.color.opacity(0.5) : .clear,
                            radius: colorFilter == tag ? 3 : 0
                        )
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Filter by \(tag.rawValue)")
                .accessibilityAddTraits(colorFilter == tag ? .isSelected : [])
            }

            if colorFilter != nil {
                Button {
                    Haptics.tap()
                    withAnimation(skin.resolvedMicroAnimation) {
                        colorFilter = nil
                    }
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(skin.resolvedTextTertiary)
                }
                .buttonStyle(.borderless)
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
        ScrollView {
            LazyVStack(alignment: .leading, spacing: DS.Spacing.md) {
                ForEach(filteredEventsByDay, id: \.date) { dayGroup in
                    let visibleCount = visibleEventCount(for: dayGroup.events)

                    DaySectionHeader(date: dayGroup.date, count: visibleCount)
                        .padding(.horizontal, DS.Spacing.sm)
                        .padding(.top, dayGroup.date == reminderService.eventsByDay.first?.date ? 0 : DS.Spacing.sm)

                    ForEach(dayGroup.events) { event in
                        EventRowView(
                            event: event,
                            reminderService: reminderService,
                            onEdit: { event in resolveEdit(event) },
                            onDelete: { event in handleDelete(event) },
                            onDeleteOccurrence: { event in
                                reminderService.excludeOccurrence(occurrenceId: event.id)
                                toastState.showSuccess("Occurrence skipped", icon: "trash.fill")
                            },
                            onDeleteSeries: { event in
                                let seriesId = event.seriesId ?? event.id
                                reminderService.removeLocalEvent(id: seriesId)
                                toastState.showSuccess("All occurrences deleted", icon: "trash.fill")
                            },
                            onTap: { event in
                                navigation = .detail(event)
                            }
                        )
                    }
                }
            }
            .padding(.horizontal, DS.Spacing.md)
            .padding(.top, DS.Spacing.md)
            .padding(.bottom, DS.Spacing.xl)
            .scrollTargetLayout()
            .id("eventListTop")
            .animation(DS.Animation.smoothSpring, value: reminderService.disintegratingEventIDs)
        }
        .scrollPosition(id: $scrollPositionID)
        .scrollContentBackground(.hidden)
    }

    private var footerActions: some View {
        HStack {
            Button(action: {
                Haptics.tap()
                navigation = .addEvent()
            }) {
                Label("Add", systemImage: "plus")
            }
            .buttonStyle(.action(role: .primary, size: .regular))
            .help("Add a new event (\u{2318}N)")
            .keyboardShortcut("n", modifiers: .command)

            Spacer()

            HStack(spacing: DS.Spacing.md) {
                Button(action: {
                    Haptics.tap()
                    navigation = .optimizer
                }) {
                    Image(systemName: "wand.and.stars")
                }
                .help("Optimize (\u{2318}O)")
                .keyboardShortcut("o", modifiers: .command)

                Button(action: {
                    Haptics.tap()
                    reminderService.syncNow()
                    toastState.showInfo("Refreshing calendars…", icon: "arrow.clockwise")
                }) {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Refresh (\u{2318}R)")
                .keyboardShortcut("r", modifiers: .command)

                OpenSettingsButton(iconOnly: true)
                    .keyboardShortcut(",", modifiers: .command)
                    .help("Settings (\u{2318},)")

                Button(action: { NSApplication.shared.terminate(nil) }) {
                    Image(systemName: "power")
                }
                .help("Quit (\u{2318}Q)")
                .keyboardShortcut("q", modifiers: .command)
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
