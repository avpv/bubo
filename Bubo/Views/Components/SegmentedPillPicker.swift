import SwiftUI

/// A horizontal row of pill-shaped buttons for selecting among discrete options.
struct SegmentedPillPicker<T: Hashable>: View {
    let options: [T]
    @Binding var selection: T
    let labelProvider: (T) -> String

    @Environment(\.activeSkin) private var skin
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: DS.Spacing.xs) {
            ForEach(options, id: \.self) { option in
                let isSelected = selection == option
                Button {
                    Haptics.tap()
                    selection = option
                } label: {
                    Text(labelProvider(option))
                        .font(.caption)
                }
                .buttonStyle(.action(role: isSelected ? .primary : .secondary, size: .compact))
                .accessibilityLabel(labelProvider(option))
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
        .animation(reduceMotion ? nil : skin.resolvedMicroAnimation, value: selection)
    }
}
