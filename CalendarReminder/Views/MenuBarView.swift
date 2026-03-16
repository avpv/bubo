import SwiftUI

struct MenuBarView: View {
    @ObservedObject var settings: ReminderSettings
    @ObservedObject var reminderService: ReminderService
    @ObservedObject var networkMonitor: NetworkMonitor

    @State private var showingAddEvent = false
    @State private var editingEvent: CalendarEvent? = nil
    @State private var hasStartedSync = false

    var body: some View {
        Group {
            if showingAddEvent {
                AddEventView(
                    reminderService: reminderService,
                    isPresented: $showingAddEvent,
                    editingEvent: editingEvent
                )
            } else {
                mainContent
            }
        }
        .onAppear {
            guard !hasStartedSync else { return }
            hasStartedSync = true
            reminderService.setNetworkMonitor(networkMonitor)
            reminderService.updateSettings(settings)
            reminderService.startSync()
        }
    }

    private var mainContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                OwlIcon(size: 18)
                Text("Reminder")
                    .font(.headline)
                Spacer()

                if !networkMonitor.isConnected {
                    Image(systemName: "wifi.slash")
                        .foregroundColor(.red)
                        .help("No internet connection")
                }

                if settings.isDoNotDisturbActive {
                    Image(systemName: "moon.fill")
                        .foregroundColor(.indigo)
                        .help("Do Not Disturb")
                }

                if reminderService.isSyncing {
                    ProgressView()
                        .scaleEffect(0.6)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider()

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

            if let error = reminderService.syncError, networkMonitor.isConnected {
                StatusBanner(icon: "exclamationmark.triangle.fill", text: error, color: .orange)
            }

            if let lastSync = reminderService.lastSyncDate {
                Text("Updated: \(lastSync.formatted(date: .omitted, time: .shortened))")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.top, 2)
            }

            // Events
            if reminderService.eventsByDay.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "calendar")
                        .font(.largeTitle)
                        .foregroundColor(.secondary)
                    Text("No upcoming meetings")
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 20)
            } else {
                List {
                    ForEach(reminderService.eventsByDay, id: \.date) { dayGroup in
                        Section {
                            ForEach(dayGroup.events) { event in
                                EventRowView(
                                    event: event,
                                    reminderService: reminderService,
                                    onEdit: { event in
                                        editingEvent = event
                                        showingAddEvent = true
                                    },
                                    onDelete: { event in
                                        reminderService.removeLocalEvent(id: event.id)
                                    }
                                )
                            }
                        } header: {
                            DaySectionHeader(date: dayGroup.date, count: dayGroup.events.count)
                        }
                    }
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
                .frame(maxHeight: 360)
            }

            Divider()

            // Actions
            HStack(spacing: 8) {
                Button(action: {
                    editingEvent = nil
                    showingAddEvent = true
                }) {
                    Label("Add", systemImage: "plus")
                }

                Button(action: { reminderService.syncNow() }) {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .disabled(!networkMonitor.isConnected)

                Spacer()

                if #available(macOS 14.0, *) {
                    SettingsLink {
                        Label("Settings", systemImage: "gear")
                    }
                } else {
                    Button(action: {
                        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
                    }) {
                        Label("Settings", systemImage: "gear")
                    }
                }

                Button(action: { NSApplication.shared.terminate(nil) }) {
                    Label("Quit", systemImage: "power")
                }
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .frame(width: 340)
    }
}
