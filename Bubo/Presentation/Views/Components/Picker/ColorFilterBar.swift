import SwiftUI
import BuboDomain

/// «SHOW» row above the timeline: a label, one dot per `EventColorTag`,
/// a tri-state hollow dot for free-slot filtering, and a clear-all `xmark`
/// when anything is active.
///
/// Color- and free-slot filters are mutually exclusive — picking either
/// resets the other. The view only owns the visuals; the source of truth
/// stays on the host as `@State`, plumbed through here as `@Binding`.
struct ColorFilterBar: View {
    @Binding var colorFilter: EventColorTag?
    @Binding var freeSlotFilter: FreeSlotFilter
    @Environment(\.activeSkin) private var skin

    var body: some View {
        let selected = colorFilter
        let anyFilter = selected != nil || freeSlotFilter.isActive
        return HStack(spacing: DS.Spacing.xs) {
            // Prototype's `SHOW` rubric — uppercase-tracked label on the
            // left edge of the dot row, telling the eye what the dots
            // mean before it reaches them. Matches
            // `ui_kits/menubar/index.html` `.bb-show-row > .bb-show-label`.
            Text("SHOW")
                .font(DS.Typography.label(skin: skin))
                .tracking(0.5)
                .textCase(.uppercase)
                .foregroundStyle(skin.resolvedTextTertiary)
                .padding(.trailing, DS.Spacing.xxs)
                .accessibilityHidden(true)

            ForEach(EventColorTag.allCases, id: \.self) { tag in
                ColorDotButton(
                    tag: tag,
                    isActive: selected == tag,
                    isDimmed: anyFilter && selected != tag
                ) {
                    Haptics.tap()
                    withAnimation(skin.resolvedMicroAnimation) {
                        freeSlotFilter = .all
                        colorFilter = (colorFilter == tag) ? nil : tag
                    }
                }
            }

            // Hollow dot cycles through three free-slot filter states.
            // Mutually exclusive with the color filters above so the two
            // modes never fight each other.
            FreeSlotDotButton(
                state: freeSlotFilter,
                isDimmed: anyFilter && !freeSlotFilter.isActive
            ) {
                Haptics.tap()
                withAnimation(skin.resolvedMicroAnimation) {
                    colorFilter = nil
                    freeSlotFilter = freeSlotFilter.next()
                }
            }

            if anyFilter {
                Button {
                    Haptics.tap()
                    withAnimation(skin.resolvedMicroAnimation) {
                        colorFilter = nil
                        freeSlotFilter = .all
                    }
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: DS.Size.iconSmall, weight: skin.resolvedSymbolWeight, design: skin.resolvedFontDesign))
                        .symbolRenderingMode(skin.resolvedSymbolRendering)
                        .foregroundStyle(skin.resolvedTextTertiary)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Clear filter")
                .transition(.scale.combined(with: .opacity))
            }
        }
        .padding(.horizontal, 10)
        .frame(height: DS.Size.colorFilterHeight)
        // `.color-filter` rhythm: 28 px self-hugging pill, fg-1 6 % bg,
        // no border, no platter depth. The pill reads as a quiet
        // affordance inside the popover rather than a card.
        .background(
            Capsule(style: .continuous)
                .fill(skin.resolvedTextPrimary.opacity(DS.Mix.surfaceFilter))
        )
        .fixedSize(horizontal: true, vertical: false)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, DS.Spacing.contentMargin)
        .padding(.vertical, DS.Spacing.xs)
        .animation(DS.Motion.micro, value: colorFilter)
        .animation(DS.Motion.micro, value: freeSlotFilter)
    }
}
