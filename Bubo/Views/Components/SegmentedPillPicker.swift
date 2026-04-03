import SwiftUI

/// A horizontal scrollable row of pill-shaped chips for selecting among discrete options.
/// Matches the visual style and animations of `TimeSlotChip`.
struct SegmentedPillPicker<T: Hashable>: View {
    let options: [T]
    @Binding var selection: T
    let labelProvider: (T) -> String

    @Environment(\.activeSkin) private var skin
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            ScrollViewReader { proxy in
                HStack(spacing: DS.Spacing.xs) {
                    ForEach(options, id: \.self) { option in
                        let isSelected = selection == option
                        SegmentedPillChip(
                            label: labelProvider(option),
                            isSelected: isSelected,
                            action: {
                                Haptics.tap()
                                selection = option
                            }
                        )
                        .id(option)
                        .accessibilityLabel(labelProvider(option))
                        .accessibilityAddTraits(isSelected ? .isSelected : [])
                    }
                }
                .padding(.vertical, 2)
                .padding(.horizontal, 2)
                .onAppear {
                    proxy.scrollTo(selection, anchor: .center)
                }
                .onChange(of: selection) {
                    withAnimation(skin.resolvedMicroAnimation) {
                        proxy.scrollTo(selection, anchor: .center)
                    }
                }
            }
        }
        .animation(reduceMotion ? nil : skin.resolvedMicroAnimation, value: selection)
    }
}

// MARK: - Chip

private struct SegmentedPillChip: View {
    let label: String
    let isSelected: Bool
    let action: () -> Void

    @State private var isHovered = false
    @Environment(\.activeSkin) private var skin

    private var chipAccent: Color {
        skin.isClassic ? DS.Colors.accent : skin.accentColor
    }

    /// Fixed minimum width so all chips are uniform.
    private let chipMinWidth: CGFloat = 52

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.system(.body, design: .monospaced, weight: isSelected ? .bold : .regular))
                .foregroundStyle(isSelected ? DS.contrastingForeground(for: chipAccent) : skin.resolvedTextPrimary)
                .frame(minWidth: chipMinWidth)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, DS.Spacing.sm)
        .frame(height: DS.Size.controlHeight)
        .background(
            ZStack {
                if isSelected {
                    Capsule()
                        .fill(
                            LinearGradient(
                                colors: [chipAccent, skin.resolvedSecondaryAccent],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                } else {
                    SkinPlatterBackground(skin: skin)
                        .clipShape(Capsule())
                    if isHovered {
                        Capsule()
                            .fill(chipAccent.opacity(DS.Opacity.lightFill))
                    }
                }
            }
        )
        .overlay(
            Capsule()
                .strokeBorder(
                    isSelected
                        ? DS.contrastingForeground(for: chipAccent).opacity(DS.Opacity.glassBorder)
                        : (isHovered ? chipAccent.opacity(DS.Opacity.strongFill + DS.Opacity.faintBorder) : .clear),
                    lineWidth: DS.Border.thin
                )
        )
        .shadow(
            color: isSelected ? chipAccent.opacity(skin.hoverShadowOpacity * 1.5) : (isHovered ? skin.resolvedHoverShadowColor : .clear),
            radius: isSelected ? skin.hoverShadowRadius * 0.5 : (isHovered ? skin.hoverShadowRadius : 0),
            y: isSelected ? skin.hoverShadowY * 0.5 : (isHovered ? skin.hoverShadowY : 0)
        )
        .scaleEffect(isHovered && !isSelected ? 1.03 : 1.0)
        .animation(skin.resolvedMicroAnimation, value: isHovered)
        .animation(skin.resolvedMicroAnimation, value: isSelected)
        .contentShape(Capsule())
        #if os(macOS)
        .onHover { hovering in
            withAnimation(skin.resolvedMicroAnimation) {
                isHovered = hovering
            }
            if hovering && !isSelected {
                NSCursor.pointingHand.push()
                Haptics.tap()
            } else {
                NSCursor.pop()
            }
        }
        #endif
    }
}
