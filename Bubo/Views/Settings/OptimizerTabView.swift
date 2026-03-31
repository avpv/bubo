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
                SettingsPlatter("General") {
                    Toggle("Enable AI Optimizer", isOn: $service.isEnabled)
                        .help("Enable the genetic algorithm schedule optimizer")
                }

                SettingsPlatter("Working Hours") {
                    HStack {
                        Text("Start:")
                        Picker("", selection: $service.workingHoursStart) {
                            ForEach(5...12, id: \.self) { hour in
                                Text("\(hour):00").tag(hour)
                            }
                        }
                        .frame(width: 100)

                        Spacer()

                        Text("End:")
                        Picker("", selection: $service.workingHoursEnd) {
                            ForEach(15...22, id: \.self) { hour in
                                Text("\(hour):00").tag(hour)
                            }
                        }
                        .frame(width: 100)
                    }
                }

                SettingsPlatter("Optimization Priorities") {
                    prioritySlider("Focus Blocks", keyPath: \.focusBlockWeight)
                    prioritySlider("Week Balance", keyPath: \.weekBalanceWeight)
                    prioritySlider("Energy Management", keyPath: \.energyCurveWeight)
                    prioritySlider("Break Placement", keyPath: \.breakWeight)
                    prioritySlider("Context Switching", keyPath: \.contextSwitchWeight)
                    prioritySlider("Buffer Time", keyPath: \.bufferWeight)
                    prioritySlider("Deadlines", keyPath: \.deadlineWeight)
                }

                SettingsPlatter("Energy Model") {
                    HStack {
                        Text("Peak energy hour:")
                        Picker("", selection: Binding(
                            get: { optimizerService.optimizer.preferences.peakEnergyHour },
                            set: { optimizerService.optimizer.preferences.peakEnergyHour = $0; optimizerService.savePreferences() }
                        )) {
                            ForEach(6...14, id: \.self) { hour in
                                Text("\(hour):00").tag(hour)
                            }
                        }
                        .frame(width: 100)
                    }
                }

                SettingsPlatter("Break Rules") {
                    HStack {
                        Text("Max consecutive meetings:")
                        Spacer()
                        Picker("", selection: Binding(
                            get: { optimizerService.optimizer.preferences.maxConsecutiveMeetingMinutes },
                            set: { optimizerService.optimizer.preferences.maxConsecutiveMeetingMinutes = $0; optimizerService.savePreferences() }
                        )) {
                            Text("1 hour").tag(60)
                            Text("1.5 hours").tag(90)
                            Text("2 hours").tag(120)
                            Text("3 hours").tag(180)
                        }
                        .frame(width: 120)
                    }

                    HStack {
                        Text("Lunch window:")
                        Spacer()
                        Picker("", selection: Binding(
                            get: { optimizerService.optimizer.preferences.lunchWindowStart },
                            set: { optimizerService.optimizer.preferences.lunchWindowStart = $0; optimizerService.savePreferences() }
                        )) {
                            ForEach(11...13, id: \.self) { h in
                                Text("\(h):00").tag(h)
                            }
                        }
                        .frame(width: 90)
                        Text("\u{2013}")
                        Picker("", selection: Binding(
                            get: { optimizerService.optimizer.preferences.lunchWindowEnd },
                            set: { optimizerService.optimizer.preferences.lunchWindowEnd = $0; optimizerService.savePreferences() }
                        )) {
                            ForEach(13...15, id: \.self) { h in
                                Text("\(h):00").tag(h)
                            }
                        }
                        .frame(width: 90)
                    }
                }

                SettingsPlatter("Learning") {
                    let feedbackCount = optimizerService.optimizer.preferenceLearner.feedbackHistory.count
                    Text("Feedback collected: \(feedbackCount) action(s)")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Button("Reset Learned Preferences", role: .destructive) {
                        optimizerService.optimizer.preferenceLearner.reset()
                    }
                }
            }
            .padding(20)
        }
    }

    private func prioritySlider(
        _ label: String,
        keyPath: WritableKeyPath<OptimizerPreferences, Double>
    ) -> some View {
        HStack {
            Text(label)
                .font(.subheadline)
                .frame(width: 140, alignment: .leading)

            Slider(
                value: Binding(
                    get: { optimizerService.optimizer.preferences[keyPath: keyPath] },
                    set: {
                        optimizerService.optimizer.preferences[keyPath: keyPath] = $0
                        optimizerService.savePreferences()
                    }
                ),
                in: 0...5,
                step: 0.1
            )

            Text(String(format: "%.1f", optimizerService.optimizer.preferences[keyPath: keyPath]))
                .font(.caption.monospacedDigit())
                .frame(width: 30, alignment: .trailing)
        }
    }
}
