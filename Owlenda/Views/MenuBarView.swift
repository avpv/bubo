import SwiftUI

struct MenuBarView: View {
    @ObservedObject var settings: ReminderSettings
    @ObservedObject var reminderService: ReminderService
    @ObservedObject var networkMonitor: NetworkMonitor

    @State private var navigation: Navigation = .list
    @State private var hasStartedSync = false
    @StateObject private var toastState = ToastState()
    @State private var pendingDeleteEvent: CalendarEvent? = nil
    @State private var showRecurrenceDeleteDialog = false

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
            Group {
                switch navigation {
                case .list:
                    mainContent
                        .transition(.move(edge: .leading).combined(with: .opacity))

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
                    .transition(.move(edge: .trailing).combined(with: .opacity))

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
                    .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
            .animation(DS.Animation.standard, value: navigation)

            ToastOverlay(toastState: toastState)
        }
        // Scope-of-delete dialog for list-level deletes on recurring events
        .confirmationDialog(
            "Delete Recurring Event",
            isPresented: $showRecurrenceDeleteDialog,
            titleVisibility: .visible,
            presenting: pendingDeleteEvent
        ) { event in
            Button("Delete This Event Only") {
                reminderService.excludeOccurrence(occurrenceId: event.id)
                toastState.showSuccess("Occurrence skipped", icon: "trash.fill")
            }
            Button("Delete All Events", role: .destructive) {
                let seriesId = event.seriesId ?? event.id
                reminderService.removeLocalEvent(id: seriesId)
                toastState.showSuccess("All occurrences deleted", icon: "trash.fill")
            }
            Button("Cancel", role: .cancel) { }
        } message: { event in
            Text("\"\(event.title)\" is a recurring event.")
        }
        .onAppear {
            guard !hasStartedSync else { return }
            hasStartedSync = true
            reminderService.setNetworkMonitor(networkMonitor)
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
                title: "Owlenda",
                trailing: AnyView(statusIndicators)
            )

            // Status messages
            if !networkMonitor.isConnected {
                StatusBanner(
                    icon: "wifi.slash",
                    text: "No connection. Showing cached data",
                    color: .orange
                )
            } else if reminderService.isUsingCache {
                StatusBanner(
                    icon: "arrow.triangle.2.circlepath",
                    text: "Showing cached data",
                    color: .yellow
                )
            }

            if !AppleCalendarService.hasAccess {
                CalendarAccessBanner()
            } else if let error = reminderService.syncError, networkMonitor.isConnected {
                StatusBanner(icon: "exclamationmark.triangle.fill", text: error, color: .orange)
            }

            // Events
            if reminderService.eventsByDay.isEmpty {
                emptyState
            } else {
                eventList
            }

            Divider()

            // Footer
            if let lastSync = reminderService.lastSyncDate {
                Text(lastSync, style: .relative)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.top, DS.Spacing.xs)
                    .padding(.bottom, -DS.Spacing.xs)
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
                    .foregroundColor(.red)
                    .font(.system(size: DS.Size.iconSmall))
                    .help("No internet connection")
                    .accessibilityLabel("No internet connection")
            }

            if settings.isDoNotDisturbActive {
                Image(systemName: "moon.fill")
                    .foregroundColor(.indigo)
                    .font(.system(size: DS.Size.iconSmall))
                    .help("Do Not Disturb")
                    .accessibilityLabel("Do Not Disturb is active")
            }

            if reminderService.isSyncing {
                ProgressView()
                    .scaleEffect(0.5)
                    .frame(width: DS.Size.syncIndicatorSize, height: DS.Size.syncIndicatorSize)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: DS.EmptyState.spacing) {
            Image(systemName: "calendar.badge.checkmark")
                .font(.system(size: DS.EmptyState.iconSize))
                .foregroundStyle(.secondary)
                .symbolRenderingMode(.hierarchical)
            Text("No upcoming meetings")
                .font(.subheadline)
                .fontWeight(.medium)
                .foregroundColor(.secondary)
            Text("Your schedule is clear")
                .font(.caption)
                .foregroundStyle(.tertiary)
            Button {
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
    }

    private var eventList: some View {
        List {
            ForEach(reminderService.eventsByDay, id: \.date) { dayGroup in
                Section {
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
                } header: {
                    DaySectionHeader(date: dayGroup.date, count: dayGroup.events.count)
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .frame(maxHeight: DS.Popover.listMaxHeight)
    }

    private var footerActions: some View {
        HStack(spacing: DS.Spacing.sm) {
            Button(action: {
                navigation = .addEvent()
            }) {
                Label("Add", systemImage: "plus")
            }
            .help("Add a new event (⌘N)")
            .keyboardShortcut("n", modifiers: .command)

            Button(action: {
                reminderService.syncNow()
                toastState.showInfo("Syncing calendars…", icon: "arrow.clockwise")
            }) {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .disabled(!networkMonitor.isConnected)
            .help("Sync calendars now (⌘R)")
            .keyboardShortcut("r", modifiers: .command)

            Spacer()

            OpenSettingsButton()
                .keyboardShortcut(",", modifiers: .command)
                .help("Open settings (⌘,)")

            Button(action: { NSApplication.shared.terminate(nil) }) {
                Label("Quit", systemImage: "power")
            }
            .help("Quit Owlenda (⌘Q)")
            .keyboardShortcut("q", modifiers: .command)
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, DS.Spacing.lg)
        .padding(.vertical, DS.Spacing.md)
        .background(.bar)
    }
}

// MARK: - Settings Button

private struct OpenSettingsButton: View {
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Button {
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

    var body: some View {
        Button {
            NSApp.keyWindow?.close()
            openSettings()
            NSApp.activate()
        } label: {
            HStack(spacing: DS.Spacing.sm) {
                Image(systemName: "calendar.badge.exclamationmark")
                    .font(.caption)
                    .symbolRenderingMode(.hierarchical)
                Text("Calendar access not granted. Click to open Settings.")
                    .font(.caption)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption2)
            }
            .foregroundColor(.orange)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, DS.Spacing.lg)
            .padding(.vertical, DS.Spacing.sm)
            .background(Color.orange.opacity(0.08))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Calendar access not granted. Open settings to grant access.")
        .transition(.move(edge: .top).combined(with: .opacity))
    }
}
