import SwiftUI

struct GeneralTabView: View {
    @ObservedObject var settings: ReminderSettings
    @ObservedObject var reminderService: ReminderService
    @ObservedObject var viewModel: SettingsViewModel

    var body: some View {
        Form {
            Section("Sync") {
                Picker("Sync interval", selection: $settings.syncIntervalMinutes) {
                    Text("1 minute").tag(1)
                    Text("3 minutes").tag(3)
                    Text("5 minutes").tag(5)
                    Text("10 minutes").tag(10)
                    Text("15 minutes").tag(15)
                    Text("30 minutes").tag(30)
                }
                .onChange(of: settings.syncIntervalMinutes) { _ in
                    save()
                    reminderService.startSyncTimer()
                }
            }

            Section {
                Toggle("Launch at login", isOn: $settings.launchAtLogin)
                    .onChange(of: settings.launchAtLogin) { _ in save() }
            }

            Section("Status") {
                if let lastSync = reminderService.lastSyncDate {
                    LabeledContent("Last sync") {
                        Text(lastSync.formatted())
                    }
                }

                LabeledContent("Synced events") {
                    Text("\(reminderService.upcomingEvents.count)")
                }

                LabeledContent("Local events") {
                    Text("\(reminderService.localEvents.count)")
                }

                if reminderService.isUsingCache {
                    Label("Using cached data", systemImage: "internaldrive")
                        .foregroundColor(.orange)
                        .font(.caption)
                }
            }
        }
        .formStyle(.grouped)
    }

    private func save() {
        viewModel.saveSettings(settings, reminderService)
    }
}
