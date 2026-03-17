import SwiftUI

/// Compact duration picker following the same pattern as `TimeSlotPicker`.
///
/// Shows a preset menu (hourglass icon) and an editable stepper — a text
/// field with +/− arrows that also accepts typed input like `90`, `1h30m`,
/// `1.5h`, or `1:30`. Best of both worlds: click to nudge, type to jump.
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

    @State private var text = ""
    @State private var isEditing = false
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

            // Editable stepper: TextField + Stepper side-by-side.
            // TextField for typing, Stepper arrows for nudging.
            HStack(spacing: 0) {
                TextField("Duration", text: $text)
                    .textFieldStyle(.plain)
                    .labelsHidden()
                    .frame(width: 80)
                    .multilineTextAlignment(.center)
                    .monospacedDigit()
                    .focused($isFocused)
                    .onSubmit { commitEdit() }
                    .onChange(of: isFocused) { _, focused in
                        if focused {
                            isEditing = true
                        } else {
                            commitEdit()
                        }
                    }
                    .onChange(of: minutes) { _, newValue in
                        if !isEditing {
                            text = DS.formatMinutes(Int(newValue))
                        }
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
            .padding(.leading, DS.Spacing.sm)
            .background(
                RoundedRectangle(cornerRadius: DS.Size.cornerRadius - 1)
                    .fill(DS.Colors.surfaceSecondary)
            )
            .overlay(
                RoundedRectangle(cornerRadius: DS.Size.cornerRadius - 1)
                    .strokeBorder(DS.Colors.border, lineWidth: 0.5)
            )
            .help(String(localized: "Type duration: 90, 1h30m, 1.5h, or 1:30",
                         comment: "Tooltip for the duration field"))
        }
        .onAppear {
            text = DS.formatMinutes(Int(minutes))
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

    // MARK: - Commit

    private func commitEdit() {
        isEditing = false
        if let parsed = Self.parseDuration(text) {
            let clamped = max(5, min(480, parsed))
            withAnimation(DS.Animation.microInteraction) {
                minutes = Double(clamped)
            }
        }
        text = DS.formatMinutes(Int(minutes))
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
                    text = DS.formatMinutes(value)
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

    // MARK: - Smart Duration Parser

    /// Parses flexible human duration input into total minutes.
    ///
    /// Supported formats:
    /// - Plain number: `"90"` → 90 min
    /// - Hours + minutes: `"1h30m"`, `"1h 30m"`, `"1h30"` → 90 min
    /// - Hours only: `"2h"` → 120 min
    /// - Minutes only: `"45m"`, `"45 min"` → 45 min
    /// - Decimal hours: `"1.5h"` → 90 min
    /// - Colon notation: `"1:30"` → 90 min
    /// - Formatted output: `"1 h 30 min"` → 90 min (round-trip)
    static func parseDuration(_ input: String) -> Int? {
        let s = input.trimmingCharacters(in: .whitespaces).lowercased()
        guard !s.isEmpty else { return nil }

        // "1:30" colon notation
        if s.contains(":") {
            let parts = s.split(separator: ":")
            guard parts.count == 2,
                  let h = Int(parts[0]),
                  let m = Int(parts[1]),
                  h >= 0, m >= 0, m < 60 else { return nil }
            let total = h * 60 + m
            return total > 0 ? total : nil
        }

        // "1h30m", "1h 30m", "1h30", "2h", "1.5h", "1 h 30 min"
        let hPattern = #/(\d+(?:\.\d+)?)\s*h/#
        let mPattern = #/(\d+)\s*m/#

        if let hMatch = s.firstMatch(of: hPattern) {
            let hours = Double(hMatch.1)!
            var total = Int(hours * 60)
            if let mMatch = s.firstMatch(of: mPattern) {
                total += Int(mMatch.1)!
            } else {
                // "1h30" — digits after 'h' without 'm'
                let afterH = #/h\s*(\d+)$/#
                if let trailing = s.firstMatch(of: afterH) {
                    total += Int(trailing.1)!
                }
            }
            return total > 0 ? total : nil
        }

        // "45m", "45 min", "45min"
        if let mMatch = s.firstMatch(of: mPattern) {
            let total = Int(mMatch.1)!
            return total > 0 ? total : nil
        }

        // Plain number → minutes
        if let n = Int(s), n > 0 {
            return n
        }

        return nil
    }
}
