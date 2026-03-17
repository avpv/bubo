import SwiftUI

struct GeneralTabView: View {
    @Environment(ReminderSettings.self) var settings
    @Environment(ReminderService.self) var reminderService

    var body: some View {
        @Bindable var settings = settings

        Form {
            Section("Refresh") {
                Picker("Refresh interval", selection: $settings.syncIntervalMinutes) {
                    Text("1 minute").tag(1)
                    Text("3 minutes").tag(3)
                    Text("5 minutes").tag(5)
                    Text("10 minutes").tag(10)
                    Text("15 minutes").tag(15)
                    Text("30 minutes").tag(30)
                }
            }

            Section("Startup") {
                Toggle("Launch at login", isOn: $settings.launchAtLogin)
            }

            Section("Status") {
                if let lastSync = reminderService.lastSyncDate {
                    LabeledContent("Last refresh") {
                        Text(lastSync.formatted())
                    }
                }

                LabeledContent("Calendar events") {
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

            Section {
                HStack {
                    Spacer()
                    Text("Owlenda \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0")")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Spacer()
                }
            }
        }
        .formStyle(.grouped)
    }
}
