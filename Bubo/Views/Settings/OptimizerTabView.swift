import SwiftUI

// MARK: - Optimizer Settings Tab

struct OptimizerTabView: View {
    @Environment(ReminderSettings.self) var settings
    @Environment(OptimizerService.self) var optimizerService
    @Environment(\.activeSkin) private var skin

    /// Canonical steps for the default-duration picker. Four round values
    /// that cover the common task shapes — quick hit, half-hour, hour,
    /// focus block — without overwhelming the picker.
    private let defaultDurationChoices: [Int] = [15, 30, 60, 90]

    var body: some View {
        @Bindable var service = optimizerService

        ScrollView {
            VStack(spacing: DS.Spacing.lg) {

                SettingsPlatter("Working Hours") {
                    VStack(alignment: .leading, spacing: DS.Spacing.md) {
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

                        VStack(alignment: .leading, spacing: DS.Spacing.xs) {
                            Text("Working days")
                                .font(.subheadline)
                            WorkingDaysPicker(selection: $service.workingDays)
                        }

                        Text("Applies to every planning surface — calendar reflow, today's plan, and the weekly backlog roll-up. The capacity ring on the Tasks list uses the same window to compare pending workload against remaining minutes.")
                            .font(.footnote)
                            .foregroundStyle(skin.resolvedTextSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                SettingsPlatter("New Tasks") {
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: DS.Spacing.xxs) {
                            Text("Default duration")
                            Text("Used when a task is added without a duration suffix (e.g. “write report 30m”).")
                                .font(.footnote)
                                .foregroundStyle(skin.resolvedTextSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer()
                        Picker("Default task duration", selection: $service.defaultTaskDurationMinutes) {
                            ForEach(defaultDurationChoices, id: \.self) { minutes in
                                Text(DS.formatMinutes(minutes)).tag(minutes)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 120)
                    }
                }

                SettingsPlatter("Your Day") {
                    VStack(spacing: DS.Spacing.lg) {
                        VStack(alignment: .leading, spacing: DS.Spacing.sm) {
                            VStack(alignment: .leading, spacing: DS.Spacing.xxs) {
                                Text("Peak energy hours")
                                Text("When you're most productive — pick one or more")
                                    .font(.footnote)
                                    .foregroundStyle(skin.resolvedTextSecondary)
                            }
                            PeakEnergyHoursPicker(
                                selection: Binding(
                                    get: { optimizerService.optimizer.preferences.peakEnergyHours },
                                    set: { newSet in
                                        optimizerService.optimizer.preferences.peakEnergyHours = newSet
                                        optimizerService.savePreferences()
                                    }
                                )
                            )
                        }

                        Divider()
                            .opacity(DS.Opacity.softAccent)

                        HStack {
                            VStack(alignment: .leading, spacing: DS.Spacing.xxs) {
                                Text("Lunch window")
                                Text("Keep this time free for lunch")
                                    .font(.footnote)
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
                        .font(.footnote)
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
