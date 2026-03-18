import ServiceManagement
import SwiftUI

struct GeneralTabView: View {
    @Environment(ReminderSettings.self) var settings
    @Environment(ReminderService.self) var reminderService
    @State private var loginItemError: String?

    private var launchAtLoginBinding: Binding<Bool> {
        Binding(
            get: { settings.launchAtLogin },
            set: { newValue in
                do {
                    if newValue {
                        try SMAppService.mainApp.register()
                    } else {
                        try SMAppService.mainApp.unregister()
                    }
                    settings.launchAtLogin = newValue
                } catch {
                    loginItemError = error.localizedDescription
                }
            }
        )
    }

    var body: some View {
        @Bindable var settings = settings

        ScrollView {
            VStack(spacing: DS.Spacing.lg) {
            SettingsPlatter("Refresh") {
                Picker("Refresh interval", selection: $settings.syncIntervalMinutes) {
                    Text("1 minute").tag(1)
                    Text("3 minutes").tag(3)
                    Text("5 minutes").tag(5)
                    Text("10 minutes").tag(10)
                    Text("15 minutes").tag(15)
                    Text("30 minutes").tag(30)
                }
            }

            SettingsPlatter("Startup") {
                Toggle("Launch at login", isOn: launchAtLoginBinding)
            }

            SettingsPlatter("Status") {
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

            SettingsPlatter {
                HStack {
                    Spacer()
                    Text("Bubo \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0")")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Spacer()
                }
            }
            }
            .padding(20)
        }
        .onAppear {
            settings.launchAtLogin = SMAppService.mainApp.status == .enabled
        }
        .alert("Cannot change login item", isPresented: .init(
            get: { loginItemError != nil },
            set: { if !$0 { loginItemError = nil } }
        )) {
            Button("OK") { loginItemError = nil }
        } message: {
            Text(loginItemError ?? "")
        }
    }
}
