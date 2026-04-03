import SwiftUI

/// Compact duration picker with a preset menu and a stepper.
///
/// The label is clickable — tap it to type duration in minutes.
/// Press Enter or click away to confirm.
///
/// ```swift
/// HStack {
///     Text("Duration")
///     Spacer()
///     DurationPicker(minutes: $duration)
/// }
/// ```
struct DurationPicker: View {
    @Environment(\.activeSkin) private var skin
    /// Duration in minutes (as `Double` to match existing event model).
    @Binding var minutes: Double

    @State private var isEditing = false
    @State private var text = ""
    @FocusState private var isFocused: Bool

    // MARK: - Presets

    private static let presets: [Int] = [
        15, 30, 45, 60, 90, 120, 180, 240, 360, 480,
    ]

    private let step = 5

    // MARK: - Body

    var body: some View {
        HStack(spacing: DS.Spacing.sm) {
            presetMenu

            HStack(spacing: 0) {
                if isEditing {
                    TextField("Duration", text: $text)
                        .textFieldStyle(.plain)
                        .labelsHidden()
                        .frame(width: DS.Size.numberInputWidth)
                        .multilineTextAlignment(.center)
                        .monospacedDigit()
                        .focused($isFocused)
                        .onSubmit { commitEdit() }
                        .onChange(of: isFocused) { _, focused in
                            if !focused { commitEdit() }
                        }
                } else {
                    Text(DS.formatMinutes(Int(minutes)))
                        .monospacedDigit()
                        .frame(width: DS.Size.numberInputWidth)
                        .multilineTextAlignment(.center)
                        .onTapGesture { startEditing() }
                }

                Stepper(
                    "",
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
                .labelsHidden()
                .fixedSize()
            }
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

    // MARK: - Editing

    private func startEditing() {
        text = "\(Int(minutes))"
        isEditing = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            isFocused = true
        }
    }

    private func commitEdit() {
        isEditing = false
        if let value = Int(text.trimmingCharacters(in: .whitespaces)), value > 0 {
            let clamped = max(5, min(480, value))
            withAnimation(skin.resolvedMicroAnimation) {
                minutes = Double(clamped)
            }
        }
    }

    // MARK: - Preset menu

    private var presetMenu: some View {
        let current = Int(minutes)

        return Menu {
            ForEach(Self.presets, id: \.self) { value in
                Button {
                    withAnimation(skin.resolvedMicroAnimation) {
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
                .foregroundStyle(skin.resolvedTextSecondary)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help(String(localized: "Duration presets",
                     comment: "Tooltip for the duration preset menu"))
        .accessibilityLabel("Duration presets")
    }
}
