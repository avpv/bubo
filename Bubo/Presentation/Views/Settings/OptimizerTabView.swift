import SwiftUI
import BuboDomain

// MARK: - Optimizer Settings Tab

/// Native grouped Form — same Settings.app vocabulary as `GeneralTabView`.
/// `DelegationContractView` and `OptimizerInsightsView` draw their own
/// grouped surfaces, so they sit on clear row backgrounds instead of
/// being boxed a second time (PRINCIPLES §2 — no boxes-in-boxes).
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

        Form {
            // Main-Job fix #1 — delegation contract surfaces the
            // explicit "what I do / what I never do" promise so
            // "доверить машине" has something to evaluate.
            Section {
                DelegationContractView()
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
            }

            // Main-Job fix #2 — visible track record from
            // `IntentLearner`. Trust grows from visible history.
            Section {
                OptimizerInsightsView()
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
            }

            Section {
                Picker("Start", selection: $service.workingHoursStart) {
                    ForEach(0...23, id: \.self) { hour in
                        Text("\(hour):00").tag(hour)
                    }
                }
                Picker("End", selection: $service.workingHoursEnd) {
                    ForEach(0...23, id: \.self) { hour in
                        Text("\(hour):00").tag(hour)
                    }
                }
                VStack(alignment: .leading, spacing: DS.Spacing.xs) {
                    Text("Working days")
                    WorkingDaysPicker(selection: $service.workingDays)
                }
            } header: {
                Text("Working Hours")
            } footer: {
                Text("The default for every day — planning surfaces, today's plan, and the capacity ring on the Tasks list all read this window. Dragging a boundary handle on the timeline adjusts that one day only; this default stays.")
            }

            Section {
                Picker("Default duration", selection: $service.defaultTaskDurationMinutes) {
                    ForEach(defaultDurationChoices, id: \.self) { minutes in
                        Text(DS.formatMinutes(minutes)).tag(minutes)
                    }
                }
            } header: {
                Text("New Tasks")
            } footer: {
                Text("Used when a task is added without a duration suffix (e.g. \u{201C}write report 30m\u{201D}).")
            }

            Section {
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
                        .frame(minWidth: 90)
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
                        .frame(minWidth: 90)
                    }
                }
            } header: {
                Text("Your Day")
            }

            Section {
                LabeledContent("Feedback collected") {
                    Text("\(optimizerService.optimizer.preferenceLearner.feedbackHistory.count) action(s)")
                        .monospacedDigit()
                }

                Button("Reset Learned Preferences", role: .destructive) {
                    optimizerService.optimizer.preferenceLearner.reset()
                }
            } header: {
                Text("Learning")
            }
        }
        .formStyle(.grouped)
    }
}
