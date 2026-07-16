import SwiftUI
import BuboDomain

/// Native grouped Form — same Settings.app vocabulary as `GeneralTabView`
/// (see its doc comment for the rationale). Replaces the custom
/// `SettingsPlatter` cards in a `ScrollView { VStack }` (DESIGN_REVIEW /
/// HIG_COMPLIANCE: full-width bordered cards stop communicating grouping;
/// hierarchy comes from native sections, not boxes-in-boxes).
struct RemindersTabView: View {
    @Environment(ReminderSettings.self) var settings
    @Environment(SettingsViewModel.self) var viewModel
    @Environment(\.activeSkin) private var skin

    var body: some View {
        @Bindable var settings = settings
        @Bindable var viewModel = viewModel

        Form {
            Section {
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

                HStack(spacing: DS.Spacing.sm) {
                    Text("Add: \(viewModel.newIntervalMinutes)\u{00A0}min")
                        .frame(minWidth: 100, alignment: .leading)
                        .monospacedDigit()

                    Stepper("Reminder interval minutes", value: $viewModel.newIntervalMinutes, in: 1...120)
                        .labelsHidden()

                    Spacer()

                    Button("Add Reminder") {
                        settings.intervals.append(ReminderInterval(minutes: viewModel.newIntervalMinutes))
                    }
                    .keyboardShortcut(.defaultAction)
                }
            } header: {
                Text("Reminder Intervals")
            }

            Section {
                Toggle("Full-screen notification", isOn: $settings.showFullScreenAlert)
                Toggle("System notification", isOn: $settings.showSystemNotification)
            } header: {
                Text("Notification Types")
            } footer: {
                Text("At least one notification type should be enabled to receive meeting alerts.")
            }
        }
        .formStyle(.grouped)
    }
}
