import SwiftUI

struct MenuBarView: View {
    @ObservedObject var settings: ReminderSettings
    @ObservedObject var reminderService: ReminderService
    @ObservedObject var networkMonitor: NetworkMonitor

    @State private var showingAddEvent = false
    @State private var hasStartedSync = false

    var body: some View {
        Group {
            if showingAddEvent {
                AddEventView(reminderService: reminderService, isPresented: $showingAddEvent)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            } else {
                mainContent
                    .transition(.move(edge: .leading).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: showingAddEvent)
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
            HStack(spacing: 8) {
                OwlIcon(size: 18)

                Text("Reminder")
                    .font(.system(.headline, design: .rounded))

                Spacer()

                HStack(spacing: 6) {
                    if !networkMonitor.isConnected {
                        Image(systemName: "wifi.slash")
                            .font(.caption)
                            .foregroundColor(.red)
                            .help("No internet connection")
                    }

                    if settings.isDoNotDisturbActive {
                        Image(systemName: "moon.fill")
                            .font(.caption)
                            .foregroundColor(.indigo)
                            .help("Do Not Disturb")
                    }

                    if reminderService.isSyncing {
                        ProgressView()
                            .scaleEffect(0.5)
                            .frame(width: 14, height: 14)
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 8)

            // Status banners
            VStack(spacing: 4) {
                if !networkMonitor.isConnected {
                    StatusBanner(
                        icon: "wifi.slash",
                        text: "No connection — showing cached data",
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
            }

            if let lastSync = reminderService.lastSyncDate {
                Text("Updated \(lastSync.formatted(date: .omitted, time: .shortened))")
                    .font(.system(size: 10, design: .rounded))
                    .foregroundColor(.tertiary)
                    .padding(.horizontal, 12)
                    .padding(.top, 2)
                    .padding(.bottom, 4)
            }

            Divider()
                .padding(.horizontal, 8)

            // Events
            if reminderService.eventsByDay.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(reminderService.eventsByDay, id: \.date) { dayGroup in
                            DaySectionView(
                                date: dayGroup.date,
                                events: dayGroup.events,
                                reminderService: reminderService
                            )
                        }
                    }
                    .padding(.vertical, 6)
                }
                .frame(maxHeight: 360)
            }

            Divider()
                .padding(.horizontal, 8)

            // Toolbar
            toolbar
        }
        .frame(width: 340)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "calendar.badge.checkmark")
                .font(.system(size: 32))
                .foregroundStyle(.secondary.opacity(0.6))
                .symbolRenderingMode(.hierarchical)

            Text("All clear!")
                .font(.system(.subheadline, design: .rounded).weight(.semibold))
                .foregroundColor(.secondary)

            Text("No upcoming meetings")
                .font(.caption)
                .foregroundColor(.tertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
    }

    private var toolbar: some View {
        HStack(spacing: 0) {
            ToolbarButton(icon: "plus.circle.fill", label: "Add") {
                showingAddEvent = true
            }

            ToolbarButton(icon: "arrow.clockwise", label: "Refresh") {
                reminderService.syncNow()
            }
            .disabled(!networkMonitor.isConnected)
            .opacity(networkMonitor.isConnected ? 1 : 0.4)

            Spacer()

            if #available(macOS 14.0, *) {
                SettingsLink {
                    ToolbarLabel(icon: "gear", label: "Settings")
                }
                .buttonStyle(.plain)
            } else {
                ToolbarButton(icon: "gear", label: "Settings") {
                    NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
                }
            }

            ToolbarButton(icon: "power", label: "Quit") {
                NSApplication.shared.terminate(nil)
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
    }
}

// MARK: - Toolbar Components

private struct ToolbarButton: View {
    let icon: String
    let label: String
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            ToolbarLabel(icon: icon, label: label)
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isHovered ? Color.primary.opacity(0.06) : .clear)
        )
    }
}

private struct ToolbarLabel: View {
    let icon: String
    let label: String

    var body: some View {
        VStack(spacing: 1) {
            Image(systemName: icon)
                .font(.system(size: 13))
                .symbolRenderingMode(.hierarchical)
            Text(label)
                .font(.system(size: 9, design: .rounded))
        }
        .foregroundColor(.secondary)
        .frame(width: 44, height: 36)
    }
}
