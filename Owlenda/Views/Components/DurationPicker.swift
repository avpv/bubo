import SwiftUI

/// Compact duration picker with a preset menu and a stepper.
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

    // MARK: - Presets

    private static let presets: [Int] = [
        15, 30, 45, 60, 90, 120, 180, 240, 360, 480,
    ]

    private let step = 5

    // MARK: - Body

    var body: some View {
        HStack(spacing: DS.Spacing.sm) {
            presetMenu

            Stepper(
                DS.formatMinutes(Int(minutes)),
                value: Binding(
                    get: { Int(minutes) },
                    set: { newValue in
                        let clamped = max(5, min(480, newValue))
                        minutes = Double(clamped)
                    }
                ),
                in: 5...480,
                step: step
            )
            .monospacedDigit()
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
            ForEach(Self.presets, id: \.self) { value in
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
