import SwiftUI

struct MenuBarView: View {
    var settings: ReminderSettings
    var reminderService: ReminderService
    var networkMonitor: NetworkMonitor

    @State private var navigation: Navigation = .list
    @State private var hasStartedSync = false
    @State private var toastState = ToastState()
    @State private var pendingDeleteEvent: CalendarEvent? = nil
    @State private var showRecurrenceDeleteDialog = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Enum-based navigation state machine replaces fragile boolean flags.
    enum Navigation: Equatable {
        case list
        case detail(CalendarEvent)
        case addEvent(editing: CalendarEvent? = nil)

        static func == (lhs: Navigation, rhs: Navigation) -> Bool {
            switch (lhs, rhs) {
            case (.list, .list): return true
            case (.detail(let a), .detail(let b)): return a.id == b.id
            case (.addEvent(let a), .addEvent(let b)): return a?.id == b?.id
            default: return false
            }
        }
    }

    var body: some View {
        ZStack {
            AppBackgroundLayer(style: settings.backgroundStyle)

            Group {
                switch navigation {
                case .list:
                    mainContent
                        .transition(
                            reduceMotion ? .opacity : .asymmetric(
                                insertion: .move(edge: .leading).combined(with: .opacity),
                                removal: .move(edge: .leading).combined(with: .opacity).combined(with: .scale(scale: 0.98))
                            )
                        )

                case .detail(let event):
                    EventDetailView(
                        event: event,
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
                        }
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
                }
            }
            .animation(
                reduceMotion ? DS.Animation.quick : DS.Animation.smoothSpring,
                value: navigation
            )

            ToastOverlay(toastState: toastState)
        }
        // Scope-of-delete dialog for list-level deletes on recurring events
        .alert(
            "Delete Recurring Event",
            isPresented: $showRecurrenceDeleteDialog,
            presenting: pendingDeleteEvent
        ) { event in
            Button("Delete This Event Only") {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    reminderService.excludeOccurrence(occurrenceId: event.id)
                    toastState.showSuccess("Occurrence skipped", icon: "trash.fill")
                }
            }
            Button("Delete All Events") {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    let seriesId = event.seriesId ?? event.id
                    reminderService.removeLocalEvent(id: seriesId)
                    toastState.showSuccess("All occurrences deleted", icon: "trash.fill")
                }
            }
            Button("Cancel", role: .cancel) { }
        } message: { event in
            Text("\"\(event.title)\" is a recurring event.")
        }
        .onAppear {
            guard !hasStartedSync else { return }
            hasStartedSync = true
            reminderService.updateSettings(settings)
            reminderService.startSync()
        }
    }

    // MARK: - Helpers

    private func resolveEdit(_ event: CalendarEvent) {
        if let seriesEvent = reminderService.seriesEvent(for: event) {
            navigation = .addEvent(editing: seriesEvent)
        } else {
            navigation = .addEvent(editing: event)
        }
    }

    private func handleDelete(_ event: CalendarEvent) {
        if event.isRecurring {
            pendingDeleteEvent = event
            showRecurrenceDeleteDialog = true
        } else {
            reminderService.removeLocalEvent(id: event.id)
            toastState.showSuccess("Event deleted", icon: "trash.fill")
        }
    }

    // MARK: - Main Content

    private var mainContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            PopoverHeader(
                title: "Bubo",
                trailing: AnyView(statusIndicators)
            )

            // Status messages
            if !networkMonitor.isConnected {
                StatusBanner(
                    icon: "wifi.slash",
                    text: "No internet — calendar data may be outdated",
                    color: .orange
                )
            } else if reminderService.isUsingCache {
                StatusBanner(
                    icon: "arrow.triangle.2.circlepath",
                    text: "Showing cached data",
                    color: .yellow
                )
                .frame(maxWidth: .infinity, alignment: .center)
            }

            if settings.isCalendarSyncEnabled {
                if !AppleCalendarService.hasAccess {
                    CalendarAccessBanner()
                        .frame(maxWidth: .infinity, alignment: .center)
                } else if let error = reminderService.syncError, networkMonitor.isConnected {
                    StatusBanner(icon: "exclamationmark.triangle.fill", text: error, color: .orange)
                        .frame(maxWidth: .infinity, alignment: .center)
                }
            }

            // Events
            if reminderService.eventsByDay.isEmpty {
                emptyState
            } else {
                eventList
            }

            Divider()

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
        .frame(width: DS.Popover.width)
    }

    // MARK: - Subviews

    private var statusIndicators: some View {
        HStack(spacing: DS.Spacing.sm) {
            if !networkMonitor.isConnected {
                Image(systemName: "wifi.slash")
                    .foregroundColor(DS.Colors.error)
                    .font(.system(size: DS.Size.iconSmall))
                    .symbolEffect(.pulse, options: .repeating.speed(0.5))
                    .help("No internet connection")
                    .accessibilityLabel("No internet connection")
                    .transition(.scale.combined(with: .opacity))
            }

            if settings.isDoNotDisturbActive {
                Image(systemName: "moon.fill")
                    .foregroundColor(.indigo)
                    .font(.system(size: DS.Size.iconSmall))
                    .help("Do Not Disturb")
                    .accessibilityLabel("Do Not Disturb is active")
                    .transition(.scale.combined(with: .opacity))
            }

            if reminderService.isSyncing {
                ProgressView()
                    .scaleEffect(0.5)
                    .frame(width: DS.Size.syncIndicatorSize, height: DS.Size.syncIndicatorSize)
                    .transition(.scale.combined(with: .opacity))
            }
        }
        .animation(DS.Animation.microInteraction, value: networkMonitor.isConnected)
        .animation(DS.Animation.microInteraction, value: settings.isDoNotDisturbActive)
        .animation(DS.Animation.microInteraction, value: reminderService.isSyncing)
    }

    private var emptyState: some View {
        VStack(spacing: DS.EmptyState.spacing) {
            Image(systemName: "calendar.badge.checkmark")
                .font(.system(size: DS.EmptyState.iconSize))
                .foregroundStyle(DS.Colors.accent, DS.Colors.textSecondary)
                .symbolEffect(.pulse, options: .repeating.speed(0.2))
            Text("No upcoming meetings")
                .font(.subheadline)
                .fontWeight(.medium)
                .foregroundColor(DS.Colors.textSecondary)
            Text("Your schedule is clear")
                .font(.caption)
                .foregroundStyle(DS.Colors.textTertiary)
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
        .frame(maxWidth: .infinity)
        .padding(.vertical, DS.Spacing.xxl)
        .transition(.opacity.combined(with: .scale(scale: 0.95)))
    }

    private var eventList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: DS.Spacing.lg) {
                ForEach(reminderService.eventsByDay, id: \.date) { dayGroup in
                    Section {
                        VStack(spacing: DS.Spacing.md) {
                            ForEach(dayGroup.events) { event in
                                EventRowView(
                                    event: event,
                                    reminderService: reminderService,
                                    onEdit: { event in resolveEdit(event) },
                                    onDelete: { event in handleDelete(event) },
                                    onTap: { event in
                                        navigation = .detail(event)
                                    }
                                )
                            }
                        }
                    } header: {
                        DaySectionHeader(date: dayGroup.date, count: dayGroup.events.count)
                            .padding(.horizontal, DS.Spacing.sm)
                    }
                }
            }
            .padding(.horizontal, DS.Spacing.md)
            .padding(.top, DS.Spacing.md)
            .padding(.bottom, DS.Spacing.xl)
        }
        .scrollContentBackground(.hidden)
        .frame(maxHeight: DS.Popover.listMaxHeight)
    }

    private var footerActions: some View {
        HStack(spacing: DS.Spacing.sm) {
            Button(action: {
                Haptics.tap()
                navigation = .addEvent()
            }) {
                Label("Add", systemImage: "plus")
            }
            .buttonStyle(.action(role: .primary, size: .regular))
            .help("Add a new event (\u{2318}N)")
            .keyboardShortcut("n", modifiers: .command)

            Button(action: {
                Haptics.tap()
                reminderService.syncNow()
                toastState.showInfo("Refreshing calendars…", icon: "arrow.clockwise")
            }) {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .help("Refresh calendars (\u{2318}R)")
            .keyboardShortcut("r", modifiers: .command)

            Spacer()

            OpenSettingsButton()
                .keyboardShortcut(",", modifiers: .command)
                .help("Open settings (\u{2318},)")

            Button(action: { NSApplication.shared.terminate(nil) }) {
                Label("Quit", systemImage: "power")
            }
            .help("Quit Bubo (\u{2318}Q)")
            .keyboardShortcut("q", modifiers: .command)
        }
        .buttonStyle(.borderless)
        .font(.system(size: 13, weight: .medium))
        .padding(.horizontal, DS.Spacing.lg)
        .frame(height: DS.Size.actionFooterHeight)
        .background(DS.Materials.headerBar)
    }
}

// MARK: - Settings Button

private struct OpenSettingsButton: View {
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Button {
            Haptics.tap()
            NSApp.keyWindow?.close()
            openSettings()
            NSApp.activate()
        } label: {
            Label("Settings", systemImage: "gear")
        }
    }
}

private struct CalendarAccessBanner: View {
    @Environment(\.openSettings) private var openSettings
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button {
            Haptics.tap()
            NSApp.keyWindow?.close()
            openSettings()
            NSApp.activate()
        } label: {
            HStack(spacing: DS.Spacing.sm) {
                Image(systemName: "calendar.badge.exclamationmark")
                    .foregroundColor(DS.Colors.warning)
                    .font(.caption)
                    .symbolRenderingMode(.hierarchical)
                Text("Calendar access not granted. Click to open Settings.")
                    .font(.caption)
                    .foregroundColor(DS.Colors.textPrimary)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption2)
                    .foregroundColor(DS.Colors.textTertiary)
            }
            .padding(.horizontal, DS.Spacing.lg)
            .padding(.vertical, DS.Spacing.md)
            .adaptiveBadgeFill(DS.Colors.warning)
            .clipShape(Capsule())
            .shadow(color: DS.Shadows.ambientColor, radius: DS.Shadows.ambientRadius, y: DS.Shadows.ambientY)
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
