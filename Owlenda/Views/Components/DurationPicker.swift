import SwiftUI

/// Compact duration picker following the same pattern as `TimeSlotPicker`.
///
/// Shows the current duration as a label with a preset menu (hourglass icon)
/// and ±5 min stepper for fine-tuning — all in a single row.
///
/// Presets are grouped by Quick / Standard / Long and the current value
/// is marked with a bullet indicator.
///
/// ```swift
/// HStack {
///     Text("Duration")
///     Spacer()
///     DurationPicker(minutes: $duration)
/// }
/// ```
struct DurationPicker: View {
    /// Duration in minutes (as `Double` to match existing event model).
    @Binding var minutes: Double

    // MARK: - Preset groups

    private struct PresetGroup: Identifiable {
        let title: LocalizedStringKey
        let id: String
        let values: [Int]
    }

    private static let groups: [PresetGroup] = [
        PresetGroup(title: "Quick",    id: "quick",    values: [15, 30, 45]),
        PresetGroup(title: "Standard", id: "standard", values: [60, 90, 120]),
        PresetGroup(title: "Long",     id: "long",     values: [180, 240, 360, 480]),
    ]

    // MARK: - Stepper step

    /// Adaptive step: ±15 min for durations ≥ 2 h, ±5 min otherwise.
    private var step: Int {
        Int(minutes) >= 120 ? 15 : 5
    }

    // MARK: - Body

    var body: some View {
        HStack(spacing: DS.Spacing.sm) {
            presetMenu

            Text(DS.formatMinutes(Int(minutes)))
                .monospacedDigit()
                .foregroundColor(DS.Colors.textPrimary)
                .contentTransition(.numericText())
                .animation(DS.Animation.microInteraction, value: minutes)

            Stepper(
                "",
                value: Binding(
                    get: { Int(minutes) },
                    set: { minutes = Double($0) }
                ),
                in: 5...480,
                step: step
            )
            .labelsHidden()
            .fixedSize()
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("Duration: \(DS.formatMinutes(Int(minutes)))",
                                 comment: "Accessibility label for duration picker"))
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment:
                minutes = min(480, minutes + Double(step))
            case .decrement:
                minutes = max(5, minutes - Double(step))
            @unknown default:
                break
            }
        }
    }

    // MARK: - Preset menu

    private var presetMenu: some View {
        let current = Int(minutes)

        return Menu {
            ForEach(Self.groups) { group in
                Section(group.title) {
                    ForEach(group.values, id: \.self) { value in
                        Button {
                            withAnimation(DS.Animation.microInteraction) {
                                minutes = Double(value)
                            }
                            Haptics.tap()
                        } label: {
                            if value == current {
                                Label(DS.formatMinutes(value),
                                      systemImage: "smallcircle.filled.circle")
                            } else {
                                Text(DS.formatMinutes(value))
                            }
                        }
                    }
                }
            }
        } label: {
            Image(systemName: "hourglass")
                .foregroundColor(.secondary)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help(String(localized: "Duration presets",
                     comment: "Tooltip for the duration preset menu"))
    }
}
