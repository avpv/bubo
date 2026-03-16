import SwiftUI

struct RemindersTabView: View {
    @ObservedObject var settings: ReminderSettings
    @ObservedObject var reminderService: ReminderService
    @ObservedObject var viewModel: SettingsViewModel

    var body: some View {
        Form {
            Section("Reminder Intervals") {
                ForEach($settings.intervals) { $interval in
                    HStack {
                        Toggle(isOn: $interval.isEnabled) {
                            Text("\(interval.displayText) before meeting")
                        }
                        .onChange(of: interval.isEnabled) { _ in save() }

                        Spacer()

                        Button(action: {
                            settings.intervals.removeAll { $0.id == interval.id }
                            save()
                        }) {
                            Image(systemName: "minus.circle.fill")
                                .foregroundColor(.red)
                        }
                        .buttonStyle(.plain)
                    }
                }

                HStack {
                    Stepper("Add: \(viewModel.newIntervalMinutes) min", value: $viewModel.newIntervalMinutes, in: 1...120)

                    Button(action: {
                        settings.intervals.append(ReminderInterval(minutes: viewModel.newIntervalMinutes))
                        save()
                    }) {
                        Image(systemName: "plus.circle.fill")
                            .foregroundColor(.green)
                    }
                    .buttonStyle(.plain)
                }
            }

            Section("Notification Types") {
                Toggle("Full-screen notification", isOn: $settings.showFullScreenAlert)
                    .onChange(of: settings.showFullScreenAlert) { _ in save() }

                Toggle("System notification", isOn: $settings.showSystemNotification)
                    .onChange(of: settings.showSystemNotification) { _ in save() }

                Toggle("Sound notification", isOn: $settings.playSound)
                    .onChange(of: settings.playSound) { _ in save() }
            }

            Section("Do Not Disturb") {
                Toggle("Enable Do Not Disturb", isOn: $settings.doNotDisturbEnabled)
                    .onChange(of: settings.doNotDisturbEnabled) { _ in save() }

                if settings.doNotDisturbEnabled {
                    DatePicker("From", selection: $settings.doNotDisturbFrom, displayedComponents: .hourAndMinute)
                        .onChange(of: settings.doNotDisturbFrom) { _ in save() }

                    DatePicker("To", selection: $settings.doNotDisturbTo, displayedComponents: .hourAndMinute)
                        .onChange(of: settings.doNotDisturbTo) { _ in save() }

                    if settings.isDoNotDisturbActive {
                        Label("Currently active", systemImage: "moon.fill")
                            .foregroundColor(.indigo)
                            .font(.caption)
                    }
                }
            }
        }
        .padding()
    }

    private func save() {
        viewModel.saveSettings(settings, reminderService)
    }
}
