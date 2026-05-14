import SwiftUI

// MARK: - Toggle Switch
//
// Prototype `.toggle` (in `docs/refactor/prototype-spec.md` §9 —
// Settings rows): a 28 × 16 pt pill with a 12 pt thumb, sliding
// `+14 px` between off and on. On-state fill = `system-green` (the
// prototype's `--on`); off-state fill = `fg-1` 14 %.
//
// SwiftUI's native `Toggle` style would import the system switch with
// the user's appearance tint — the prototype's switch is its own
// shape, narrower than the system control, and the green is hard-
// wired so the affordance reads the same on every skin (system,
// coffee, midnight, paper). The `.toggle` voice is "ON when green",
// not "ON when accent".
//
// Use this view in Settings rows and any inline boolean affordance.
// Wrap the binding in a Button via `.contentShape(.rect)` so the
// whole row is tappable.

struct ToggleSwitch: View {
    @Binding var isOn: Bool
    /// Optional override for the on-state fill. Defaults to the
    /// skin's resolved success colour so the affordance carries the
    /// prototype's `--on = system-green` semantic.
    var onFill: Color? = nil

    @Environment(\.activeSkin) private var skin
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let trackWidth: CGFloat = 28
    private let trackHeight: CGFloat = 16
    private let thumbDiameter: CGFloat = 12
    private let thumbInset: CGFloat = 2

    var body: some View {
        let fillOn = onFill ?? skin.resolvedSuccessColor
        let fillOff = skin.resolvedTextPrimary.opacity(DS.Mix.surfaceSeparator)
        Button {
            Haptics.tap()
            isOn.toggle()
        } label: {
            ZStack(alignment: isOn ? .trailing : .leading) {
                Capsule().fill(isOn ? fillOn : fillOff)
                Circle()
                    .fill(.white)
                    .shadow(color: .black.opacity(0.15), radius: 1, y: 0.5)
                    .frame(width: thumbDiameter, height: thumbDiameter)
                    .padding(.horizontal, thumbInset)
            }
            .frame(width: trackWidth, height: trackHeight)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .animation(reduceMotion ? nil : DS.Motion.micro, value: isOn)
        .accessibilityElement()
        .accessibilityAddTraits(.isButton)
        .accessibilityValue(isOn ? "On" : "Off")
        .accessibilityAction { isOn.toggle() }
    }
}
