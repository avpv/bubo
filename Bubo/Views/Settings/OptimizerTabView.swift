import SwiftUI

// MARK: - Optimizer Settings Tab

struct OptimizerTabView: View {
    @Environment(ReminderSettings.self) var settings
    @Environment(OptimizerService.self) var optimizerService
    @Environment(\.activeSkin) private var skin

    var body: some View {
        @Bindable var service = optimizerService

        ScrollView {
            VStack(spacing: DS.Spacing.lg) {

                SettingsPlatter("Working Hours") {
                    HStack {
                        Text("Start:")
                        Picker("Working hours start", selection: $service.workingHoursStart) {
                            ForEach(5...12, id: \.self) { hour in
                                Text("\(hour):00").tag(hour)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 100)

                        Spacer()

                        Text("End:")
                        Picker("Working hours end", selection: $service.workingHoursEnd) {
                            ForEach(15...22, id: \.self) { hour in
                                Text("\(hour):00").tag(hour)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 100)
                    }
                }

                SettingsPlatter("Your Day") {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Peak energy hour")
                            Text("When you're most productive")
                                .font(.caption)
                                .foregroundStyle(skin.resolvedTextSecondary)
                        }
                        Spacer()
                        Picker("Peak energy hour", selection: Binding(
                            get: { optimizerService.optimizer.preferences.peakEnergyHour },
                            set: { optimizerService.optimizer.preferences.peakEnergyHour = $0; optimizerService.savePreferences() }
                        )) {
                            ForEach(6...14, id: \.self) { hour in
                                Text("\(hour):00").tag(hour)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 100)
                    }

                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Lunch window")
                            Text("Keep this time free for lunch")
                                .font(.caption)
                                .foregroundStyle(skin.resolvedTextSecondary)
                        }
                        Spacer()
                        Picker("Lunch window start", selection: Binding(
                            get: { optimizerService.optimizer.preferences.lunchWindowStart },
                            set: { optimizerService.optimizer.preferences.lunchWindowStart = $0; optimizerService.savePreferences() }
                        )) {
                            ForEach(11...13, id: \.self) { h in
                                Text("\(h):00").tag(h)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 90)
                        Text("\u{2013}")
                        Picker("Lunch window end", selection: Binding(
                            get: { optimizerService.optimizer.preferences.lunchWindowEnd },
                            set: { optimizerService.optimizer.preferences.lunchWindowEnd = $0; optimizerService.savePreferences() }
                        )) {
                            ForEach(13...15, id: \.self) { h in
                                Text("\(h):00").tag(h)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 90)
                    }
                }

                SettingsPlatter("Learning") {
                    let feedbackCount = optimizerService.optimizer.preferenceLearner.feedbackHistory.count
                    Text("Feedback collected: \(feedbackCount) action(s)")
                        .font(.caption)
                        .foregroundStyle(skin.resolvedTextSecondary)

                    Button("Reset Learned Preferences", role: .destructive) {
                        optimizerService.optimizer.preferenceLearner.reset()
                    }
                }

                SettingsPlatter("Autopilot") {
                    Toggle(isOn: Binding(
                        get: { optimizerService.recipeMonitor?.autopilotEnabled ?? false },
                        set: { optimizerService.recipeMonitor?.autopilotEnabled = $0 }
                    )) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Auto-adjust schedule")
                            Text("Automatically reoptimize when events change")
                                .font(.caption)
                                .foregroundStyle(skin.resolvedTextSecondary)
                        }
                    }
                }
            }
            .padding(DS.Spacing.xl)
        }
    }
}
