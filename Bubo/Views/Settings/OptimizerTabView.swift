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
                    VStack(alignment: .leading, spacing: DS.Spacing.sm) {
                        Grid(alignment: .leading, verticalSpacing: DS.Spacing.md) {
                            GridRow {
                                Text("Start:")
                                    .gridColumnAlignment(.leading)
                                Picker("Working hours start", selection: $service.workingHoursStart) {
                                    ForEach(0...23, id: \.self) { hour in
                                        Text("\(hour):00").tag(hour)
                                    }
                                }
                                .labelsHidden()
                                .frame(width: 100)
                                .gridColumnAlignment(.trailing)
                            }
                            GridRow {
                                Text("End:")
                                Picker("Working hours end", selection: $service.workingHoursEnd) {
                                    ForEach(0...23, id: \.self) { hour in
                                        Text("\(hour):00").tag(hour)
                                    }
                                }
                                .labelsHidden()
                                .frame(width: 100)
                            }
                        }
                        Text("The Tasks capacity ring compares your pending workload to the minutes left before the end of the working day.")
                            .font(.caption)
                            .foregroundStyle(skin.resolvedTextSecondary)
                    }
                }

                SettingsPlatter("Your Day") {
                    VStack(spacing: DS.Spacing.lg) {
                        HStack {
                            VStack(alignment: .leading, spacing: DS.Spacing.xxs) {
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
                                ForEach(0...23, id: \.self) { hour in
                                    Text("\(hour):00").tag(hour)
                                }
                            }
                            .labelsHidden()
                            .frame(width: 100)
                        }

                        Divider()
                            .opacity(0.3)

                        HStack {
                            VStack(alignment: .leading, spacing: DS.Spacing.xxs) {
                                Text("Lunch window")
                                Text("Keep this time free for lunch")
                                    .font(.caption)
                                    .foregroundStyle(skin.resolvedTextSecondary)
                            }
                            Spacer()
                            HStack(spacing: DS.Spacing.sm) {
                                Picker("Lunch window start", selection: Binding(
                                    get: { optimizerService.optimizer.preferences.lunchWindowStart },
                                    set: { optimizerService.optimizer.preferences.lunchWindowStart = $0; optimizerService.savePreferences() }
                                )) {
                                    ForEach(0...23, id: \.self) { h in
                                        Text("\(h):00").tag(h)
                                    }
                                }
                                .labelsHidden()
                                .frame(width: 90)
                                Text("\u{2013}")
                                    .foregroundStyle(skin.resolvedTextSecondary)
                                Picker("Lunch window end", selection: Binding(
                                    get: { optimizerService.optimizer.preferences.lunchWindowEnd },
                                    set: { optimizerService.optimizer.preferences.lunchWindowEnd = $0; optimizerService.savePreferences() }
                                )) {
                                    ForEach(0...23, id: \.self) { h in
                                        Text("\(h):00").tag(h)
                                    }
                                }
                                .labelsHidden()
                                .frame(width: 90)
                            }
                        }
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

            }
            .padding(DS.Spacing.xl)
        }
    }
}
