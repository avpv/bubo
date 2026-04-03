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
                        .font(.caption.weight(isSelected ? .semibold : .regular))
                        .padding(.horizontal, DS.Spacing.sm)
                        .padding(.vertical, DS.Spacing.xs)
                        .foregroundStyle(isSelected ? .white : skin.resolvedTextPrimary)
                        .background(
                            Capsule()
                                .fill(isSelected ? skin.accentColor : skin.accentColor.opacity(0.1))
                        )
                }
                .buttonStyle(.plain)
                .accessibilityLabel(labelProvider(option))
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
        .animation(reduceMotion ? nil : skin.resolvedMicroAnimation, value: selection)
    }
}
