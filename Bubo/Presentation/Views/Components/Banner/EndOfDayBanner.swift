import SwiftUI

// MARK: - End-of-Day Carry-Forward Banner (J10)
//
// Quiet end-of-day prompt that surfaces once the user opens the
// menu-bar popover after their working window has closed and there
// are still unfinished pending tasks. One-tap moves them all to
// tomorrow; the same dismiss button suppresses the banner for the
// rest of the day. The actual carry-forward work is delegated to
// the host (MenuBarView), which owns the BacklogService and the
// undo-toast pipe.
//
// Birman: «don't try to guess» — we don't move tasks automatically
// just because 18:00 has arrived. The user themselves presses «Carry»
// and sees the result with the ability to undo.

struct EndOfDayBanner: View {
    @Environment(\.activeSkin) private var skin

    let unfinishedCount: Int
    let onCarry: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: DS.Spacing.sm) {
            Image(systemName: "moon.zzz.fill")
                .font(.footnote)
                .foregroundStyle(skin.resolvedTextSecondary)
                .symbolRenderingMode(.hierarchical)
                .accessibilityHidden(true)

            // Single sentence — verb up front so the affordance reads at
            // a glance, count second so the cost of acting is visible.
            Text("End of day")
                .font(.footnote.weight(.medium))
                .foregroundStyle(skin.resolvedTextPrimary)
                .lineLimit(1)

            Text("\u{00B7} \(unfinishedCount) unfinished")
                .font(DS.Typography.machineHint)
                .foregroundStyle(skin.resolvedTextTertiary)
                .lineLimit(1)

            Spacer(minLength: DS.Spacing.xs)

            Button {
                Haptics.tap()
                onCarry()
            } label: {
                Text("Carry to tomorrow")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(skin.accentColor)
                    .padding(.horizontal, DS.Spacing.md)
                    .padding(.vertical, DS.Spacing.xxs)
                    .background(
                        Capsule().fill(skin.accentColor.opacity(DS.Opacity.lightFill))
                    )
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Carry \(unfinishedCount) unfinished tasks to tomorrow")

            Button {
                Haptics.tap()
                onDismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(skin.resolvedTextTertiary)
                    .frame(width: DS.Size.controlHeight, height: DS.Size.controlHeight)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss end-of-day reminder")
        }
        .padding(.horizontal, DS.Spacing.md)
        .frame(height: DS.Size.controlHeight)
        .skinPlatter(skin)
        .skinPlatterDepth(skin)
    }
}
