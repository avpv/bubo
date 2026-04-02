import SwiftUI

/// A horizontal row of pill-shaped buttons for selecting among discrete options.
struct SegmentedPillPicker<T: Hashable>: View {
    let options: [T]
    @Binding var selection: T
    let labelProvider: (T) -> String

    @Environment(\.activeSkin) private var skin

    var body: some View {
        HStack(spacing: DS.Spacing.xs) {
            ForEach(options, id: \.self) { option in
                Button {
                    selection = option
                } label: {
                    Text(labelProvider(option))
                        .font(.caption.weight(selection == option ? .semibold : .regular))
                        .padding(.horizontal, DS.Spacing.sm)
                        .padding(.vertical, DS.Spacing.xs)
                        .foregroundStyle(selection == option ? .white : skin.resolvedTextPrimary)
                        .background(
                            Capsule()
                                .fill(selection == option ? skin.accentColor : skin.accentColor.opacity(0.1))
                        )
                }
                .buttonStyle(.plain)
            }
        }
    }
}
