import SwiftUI

// MARK: - Working Hours Bookend
//
// Mirrors the prototype's `.wh-line` — a sunrise/sunset bookend that
// frames a day's timeline. Layout (from `docs/refactor/prototype-spec.md`
// "Today Popover · Dimensions"):
//
//   [sunrise icon] [18 px rule] [label] [mono time chip] [spacer] [step ±]
//
// • icon: 13 px, `--fg-3` opacity ≈ 0.7
// • rule: 18 px × 1 px hairline at `--fg-4` (≈ 12 % primary)
// • label: 500 11.5/1 rounded, `--fg-3`
// • time: mono 11.5/1 weight-medium, `--fg-1`, inline next to label
// • step: 22 × 22 round button, hover → accent 12 % bg + accent text
//
// Used to mark the boundaries of a day's working window inside the
// menu-bar timeline. Tap on the time chip opens the time-edit picker;
// the step buttons nudge the boundary in ±15 min increments.

enum WorkingHoursEdge {
    case start
    case end

    /// SF Symbol matching the prototype's sunrise/sunset glyphs.
    var symbol: String {
        switch self {
        case .start: return "sunrise"
        case .end: return "sunset"
        }
    }

    var label: String {
        switch self {
        case .start: return "Start"
        case .end: return "End"
        }
    }
}

struct WorkingHoursLine: View {
    let edge: WorkingHoursEdge
    let timeText: String
    /// Optional ±15 min nudge handler. When `nil`, the step affordances
    /// are hidden — useful for read-only previews in settings.
    var onNudge: ((Int) -> Void)? = nil
    /// Tap on the time chip — opens the boundary picker.
    var onEditTime: (() -> Void)? = nil

    @Environment(\.activeSkin) private var skin

    var body: some View {
        HStack(spacing: DS.Spacing.xs) {
            Image(systemName: edge.symbol)
                .font(.system(size: 13, weight: skin.resolvedSymbolWeight))
                .foregroundStyle(skin.resolvedTextTertiary)
                .opacity(0.7)
                .accessibilityHidden(true)

            Rectangle()
                .fill(skin.resolvedTextPrimary.opacity(DS.Fg.dividerOpacity))
                .frame(width: 18, height: 1)

            Text(edge.label)
                .font(.system(size: 11.5, weight: .medium, design: skin.resolvedFontDesign))
                .foregroundStyle(skin.resolvedTextTertiary)

            Button(action: { onEditTime?() }) {
                Text(timeText)
                    .font(.system(size: 11.5, weight: .medium, design: .monospaced))
                    .foregroundStyle(skin.resolvedTextPrimary)
            }
            .buttonStyle(.plain)
            .disabled(onEditTime == nil)

            Spacer(minLength: 0)

            if let onNudge {
                stepButton(direction: -1, action: { onNudge(-15) })
                stepButton(direction: +1, action: { onNudge(+15) })
            }
        }
        .padding(.horizontal, DS.Spacing.xs)
        .padding(.vertical, 0)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(edge.label) of working hours, \(timeText)")
    }

    @ViewBuilder
    private func stepButton(direction: Int, action: @escaping () -> Void) -> some View {
        WorkingHoursStep(direction: direction, action: action)
    }
}

private struct WorkingHoursStep: View {
    let direction: Int
    let action: () -> Void

    @Environment(\.activeSkin) private var skin
    @State private var isHovered = false
    @State private var isPressed = false

    var body: some View {
        Button(action: {
            Haptics.tap()
            action()
        }) {
            Image(systemName: direction < 0 ? "minus" : "plus")
                .font(.system(size: 10, weight: .semibold))
                .frame(width: 22, height: 22)
                .foregroundStyle(isHovered ? skin.accentColor : skin.resolvedTextTertiary)
                .background(
                    Circle().fill(skin.accentColor.opacity(isHovered ? DS.Mix.accentPressed : 0))
                )
                .contentShape(Circle())
                .scaleEffect(isPressed ? DS.Physics.pressedIconScale : 1.0)
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(DS.Motion.micro) { isHovered = hovering }
        }
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in isPressed = true }
                .onEnded { _ in isPressed = false }
        )
        .accessibilityLabel(direction < 0 ? "Nudge earlier" : "Nudge later")
    }
}
