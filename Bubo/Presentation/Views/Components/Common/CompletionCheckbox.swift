import SwiftUI

// MARK: - Completion Checkbox
//
// Single primitive for every "mark task / subtask complete" affordance
// in the popover (prototype `.cb` and `.checkbox`). Cross-cutting
// guidance #5 from `docs/refactor/prototype-spec.md` makes this a
// hard product rule:
//
//   The checkbox is reserved for "complete".
//
// Selection (in the backlog's multi-select mode) does NOT fill the
// checkbox — it tints the row background. Two affordances, two
// meanings, no overlap. New call sites that want a "row selected"
// indicator should NOT reuse this view.
//
// Visuals follow the prototype:
//   • 17 × 17 pt circle, 1.5 px border in `fg-3`
//   • on-state: `system-green` fill, white check glyph
//   • hover: border lifts to `accent`
//   • micro-animation on toggle (DS.Motion.micro)

struct CompletionCheckbox: View {
    @Binding var isDone: Bool
    /// Optional override of the on-state fill. Defaults to the active
    /// skin's resolvedSuccessColor (green). The destructive ramp is
    /// not allowed here — completion is never destructive.
    var onFill: Color? = nil

    @Environment(\.activeSkin) private var skin
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovered = false

    private let diameter: CGFloat = 17

    var body: some View {
        let fill = onFill ?? skin.resolvedSuccessColor
        Button {
            Haptics.tap()
            isDone.toggle()
        } label: {
            ZStack {
                Circle()
                    .fill(isDone ? fill : Color.clear)
                Circle()
                    .strokeBorder(
                        isDone
                            ? fill
                            : (isHovered ? skin.accentColor : skin.resolvedTextTertiary),
                        lineWidth: 1.5
                    )
                if isDone {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(DS.contrastingForeground(for: fill))
                }
            }
            .frame(width: diameter, height: diameter)
            .contentShape(Circle())
        }
        .buttonStyle(.iconPress)
        .onHover { hovering in
            withAnimation(reduceMotion ? nil : DS.Motion.micro) { isHovered = hovering }
        }
        .animation(reduceMotion ? nil : DS.Motion.micro, value: isDone)
        .accessibilityLabel(isDone ? "Mark not done" : "Mark done")
        .accessibilityAddTraits(isDone ? .isSelected : [])
    }
}
