import SwiftUI

struct GeneralTabView: View {
    @ObservedObject var settings: ReminderSettings
    @ObservedObject var reminderService: ReminderService
    @ObservedObject var viewModel: SettingsViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // Sync settings
                SettingsCard(icon: "arrow.triangle.2.circlepath", title: "Sync", description: "How often to check for new events") {
                    Picker("Sync interval", selection: $settings.syncIntervalMinutes) {
                        Text("1 minute").tag(1)
                        Text("3 minutes").tag(3)
                        Text("5 minutes").tag(5)
                        Text("10 minutes").tag(10)
                        Text("15 minutes").tag(15)
                        Text("30 minutes").tag(30)
                    }
                    .font(.system(.subheadline, design: .rounded))
                    .onChange(of: settings.syncIntervalMinutes) { _ in
                        save()
                        reminderService.startSyncTimer()
                    }
                }

                // Launch at login
                SettingsCard(icon: "power", title: "Startup", description: "Launch behavior") {
                    Toggle(isOn: $settings.launchAtLogin) {
                        Text("Launch at login")
                            .font(.system(.subheadline, design: .rounded))
                    }
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .onChange(of: settings.launchAtLogin) { _ in save() }
                }

                // Status
                SettingsCard(icon: "chart.bar.fill", title: "Status", description: "Current sync information") {
                    VStack(spacing: 8) {
                        if let lastSync = reminderService.lastSyncDate {
                            StatusRow(label: "Last sync", value: lastSync.formatted())
                        }
                        StatusRow(label: "Synced events", value: "\(reminderService.upcomingEvents.count)")
                        StatusRow(label: "Local events", value: "\(reminderService.localEvents.count)")

                        if reminderService.isUsingCache {
                            HStack(spacing: 4) {
                                Image(systemName: "internaldrive.fill")
                                    .font(.caption2)
                                Text("Using cached data")
                                    .font(.system(.caption, design: .rounded))
                            }
                            .foregroundColor(.orange)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(
                                Capsule()
                                    .fill(Color.orange.opacity(0.1))
                            )
                        }
                    }
                }
            }
            .padding(20)
        }
    }

    private func save() {
        viewModel.saveSettings(settings, reminderService)
    }
}

private struct StatusRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack {
            Text(label)
                .font(.system(.subheadline, design: .rounded))
                .foregroundColor(.secondary)
            Spacer()
            Text(value)
                .font(.system(.subheadline, design: .rounded).weight(.medium))
        }
    }
}
