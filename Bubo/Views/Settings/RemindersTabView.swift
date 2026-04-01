import SwiftUI

struct RemindersTabView: View {
    @Environment(ReminderSettings.self) var settings
    @Environment(SettingsViewModel.self) var viewModel

    var body: some View {
        @Bindable var settings = settings
        @Bindable var viewModel = viewModel

        ScrollView {
            VStack(spacing: DS.Spacing.lg) {
            SettingsPlatter("Reminder Intervals") {
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
                        .accessibilityLabel("Delete \(interval.displayText) reminder")
                        .help("Delete reminder")
                    }
                }

                Grid(alignment: .leading, horizontalSpacing: DS.Spacing.sm) {
                    GridRow {
                        Text("Add: \(viewModel.newIntervalMinutes) min")
                            .frame(minWidth: 100, alignment: .leading)
                            .monospacedDigit()
                        
                        Stepper("Reminder interval minutes", value: $viewModel.newIntervalMinutes, in: 1...120)
                            .labelsHidden()

                        Button("Add") {
                            settings.intervals.append(ReminderInterval(minutes: viewModel.newIntervalMinutes))
                        }
                    }
                }
            }

            SettingsPlatter("Notification Types") {
                Toggle("Full-screen notification", isOn: $settings.showFullScreenAlert)
                Toggle("System notification", isOn: $settings.showSystemNotification)
                Text("At least one notification type should be enabled to receive meeting alerts.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.top, DS.Spacing.xs)
            }

            }
            .padding(DS.Spacing.xl)
        }
    }
}
