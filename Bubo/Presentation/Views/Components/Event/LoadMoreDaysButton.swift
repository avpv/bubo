import SwiftUI

/// Quiet «Load more days» footer — extends the timeline horizon by
/// one week per tap. Visually styled as a borderless full-width row
/// so it reads as a continuation of the timeline instead of a primary
/// action competing with `Add event` in the popover footer.
///
/// The cap and the per-tap increment live with the host (`MenuBarView`)
/// because they're tied to the fetch-window math; this view only fires
/// the closure when tapped.
struct LoadMoreDaysButton: View {
    let onLoad: () -> Void
    @Environment(\.activeSkin) private var skin

    var body: some View {
        Button {
            Haptics.tap()
            onLoad()
        } label: {
            HStack(spacing: DS.Spacing.xs) {
                Image(systemName: "chevron.down")
                    .font(.system(size: DS.Size.iconSmall, weight: skin.resolvedSymbolWeight))
                Text("Load more days")
                    .font(.footnote.weight(.regular))
            }
            .foregroundStyle(skin.resolvedTextTertiary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, DS.Spacing.sm)
            .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .help("Show another week of upcoming days")
        .accessibilityLabel("Load more days")
    }
}
