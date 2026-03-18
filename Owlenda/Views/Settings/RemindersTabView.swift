import SwiftUI

struct RemindersTabView: View {
    @Environment(ReminderSettings.self) var settings
    @Environment(SettingsViewModel.self) var viewModel

    var body: some View {
        @Bindable var settings = settings
        @Bindable var viewModel = viewModel

        Form {
            Section("Reminder Intervals") {
                ForEach($settings.intervals) { $interval in
                    HStack {
                        Toggle(isOn: $interval.isEnabled) {
                            Text("\(interval.displayText) before meeting")
                        }

                        Spacer()

                        Button(role: .destructive) {
                            settings.intervals.removeAll { $0.id == interval.id }
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                    }
                }

                HStack {
                    Stepper("Add: \(viewModel.newIntervalMinutes) min", value: $viewModel.newIntervalMinutes, in: 1...120)

                    Button("Add") {
                        settings.intervals.append(ReminderInterval(minutes: viewModel.newIntervalMinutes))
                    }
                }
            }

            Section {
                Toggle("Full-screen notification", isOn: $settings.showFullScreenAlert)
                Toggle("System notification", isOn: $settings.showSystemNotification)
            } header: {
                Text("Notification Types")
            } footer: {
                Text("At least one notification type should be enabled to receive meeting alerts.")
                    .foregroundColor(.secondary)
            }

            Section("Do Not Disturb") {
                Toggle("Enable Do Not Disturb", isOn: $settings.doNotDisturbEnabled)

                if settings.doNotDisturbEnabled {
                    DatePicker("From", selection: $settings.doNotDisturbFrom, displayedComponents: .hourAndMinute)
                    DatePicker("To", selection: $settings.doNotDisturbTo, displayedComponents: .hourAndMinute)

                    if settings.isDoNotDisturbActive {
                        Label("Currently active", systemImage: "moon.fill")
                            .foregroundColor(.indigo)
                            .font(.caption)
                    }
                }
            }
        }
        .padding(20)
    }
}
