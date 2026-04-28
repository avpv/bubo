import SwiftUI

// MARK: - Peak Energy Hours Picker

/// 24-chip toggle grid for selecting one or more hours of the day that
/// the user considers their peak-productivity windows. Backs a
/// `Set<Int>` of 0…23 hour indices.
///
/// Multi-peak support lets users with split energy patterns
/// (e.g. morning + after-lunch) nudge the planner toward both windows
/// rather than forcing a single Gaussian around one hour. Internally
/// the optimizer treats the set as "closest peak wins", so adding
/// hours widens the high-energy region without penalising the
/// original single-peak behaviour.
///
/// At least one hour must stay selected — dropping to empty would
/// leave the energy-curve objective with no anchor and read as
/// "no peak hours exist". Clicks on a lone-selected chip are no-ops.
struct PeakEnergyHoursPicker: View {
    @Binding var selection: Set<Int>

    @Environment(\.activeSkin) private var skin

    private let columns: [GridItem] = Array(
        repeating: GridItem(.flexible(), spacing: DS.Spacing.xs),
        count: 6
    )

    var body: some View {
        LazyVGrid(columns: columns, spacing: DS.Spacing.xs) {
            ForEach(0..<24, id: \.self) { hour in
                chip(for: hour)
            }
        }
    }

    @ViewBuilder
    private func chip(for hour: Int) -> some View {
        let isOn = selection.contains(hour)

        Button {
            toggle(hour)
        } label: {
            Text("\(hour):00")
                .font(.footnote.weight(isOn ? .semibold : .regular))
                .foregroundStyle(
                    isOn
                        ? skin.resolvedTextPrimary
                        : skin.resolvedTextSecondary
                )
                .padding(.vertical, 6)
                .padding(.horizontal, 10)
                .frame(maxWidth: .infinity)
                .background(
                    Capsule()
                        .fill(
                            isOn
                                ? skin.accentColor.opacity(0.22)
                                : skin.resolvedTextTertiary.opacity(0.10)
                        )
                )
                .overlay(
                    Capsule()
                        .stroke(
                            isOn
                                ? skin.accentColor.opacity(0.55)
                                : skin.resolvedTextTertiary.opacity(0.25),
                            lineWidth: 1
                        )
                )
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(hour):00")
        .accessibilityAddTraits(isOn ? [.isSelected] : [])
    }

    private func toggle(_ hour: Int) {
        if selection.contains(hour) {
            guard selection.count > 1 else { return }
            selection.remove(hour)
        } else {
            selection.insert(hour)
        }
    }
}
