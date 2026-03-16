import SwiftUI

struct MenuBarView: View {
    @ObservedObject var settings: ReminderSettings
    @ObservedObject var reminderService: ReminderService
    @ObservedObject var networkMonitor: NetworkMonitor

    @State private var showingAddEvent = false
    @State private var hasStartedSync = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Header
            HStack {
                Image(systemName: "calendar.badge.clock")
                    .foregroundColor(.blue)
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
            .padding(.horizontal)
            .padding(.top, 8)

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
                    .padding(.horizontal)
            }

            // Events grouped by day
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
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(reminderService.eventsByDay, id: \.date) { dayGroup in
                            DaySectionView(
                                date: dayGroup.date,
                                events: dayGroup.events,
                                reminderService: reminderService
                            )
                        }
                    }
                }
                .frame(maxHeight: 350)
            }

            Divider()

            // Actions
            HStack(spacing: 12) {
                Button(action: { showingAddEvent = true }) {
                    Label("Add", systemImage: "plus.circle")
                }
                .buttonStyle(.plain)

                Button(action: { reminderService.syncNow() }) {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.plain)
                .disabled(!networkMonitor.isConnected)

                Spacer()

                SettingsLink {
                    Label("Settings", systemImage: "gear")
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal)

            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
            .padding(.horizontal)
            .padding(.bottom, 8)
        }
        .frame(width: 340)
        .sheet(isPresented: $showingAddEvent) {
            AddEventView(reminderService: reminderService, isPresented: $showingAddEvent)
        }
        .onAppear {
            guard !hasStartedSync else { return }
            hasStartedSync = true
            reminderService.setNetworkMonitor(networkMonitor)
            reminderService.updateSettings(settings)
            reminderService.startSync()
        }
    }
}
