import SwiftUI

// MARK: - Working Hours Boundary Row

/// Thin horizontal divider that surfaces a working-hours boundary
/// (`workingHours.lowerBound` or `.upperBound`) as a draggable surface
/// inside the timeline. Sits at the head and tail of today's day
/// section so the boundary rule reads as a visible object — Birman:
/// «rules are objects on the screen».
///
/// The row is interactive in two ways:
///
/// - **Step buttons** (▲ / ▼) on the trailing edge nudge the boundary
///   by ±1 hour. Cheaper than a slider for the common adjustment.
/// - **Vertical drag** on the row itself adjusts by ±1 hour per ~24 pt
///   of motion (clamped to 0…23 with the start < end invariant the
///   `OptimizerService.workingHoursStart` / `End` setters already
///   enforce). The drag updates the bound continuously so the user
///   sees the schedule reshape in real time.
///
/// The `kind` enum distinguishes start vs end so copy and bounds are
/// asymmetric: «Working hours start» / «Working hours end», with
/// dragging-up = earlier-hour at start (decrement) but later-hour at
/// end (increment). Mirrors how a user would think of the two
/// handles: «pull the start up to start earlier», «pull the end
/// down to end earlier».
struct WorkingHoursBoundaryRow: View {

    enum Kind {
        case start
        case end

        var label: String {
            switch self {
            case .start: "Working hours start"
            case .end:   "Working hours end"
            }
        }

        var icon: String {
            switch self {
            case .start: "sunrise"
            case .end:   "sunset"
            }
        }
    }

    let kind: Kind
    let hour: Int
    /// When `false`, the row drops its step chevrons and short-circuits
    /// the drag gesture — used on non-today day sections where the
    /// boundary is informational only. Defaults to `true` so the
    /// today-only call sites keep their interactive behaviour.
    var isInteractive: Bool = true
    let onStep: (Int) -> Void  // delta in hours (typically ±1)

    @Environment(\.activeSkin) private var skin
    @State private var dragStartHour: Int? = nil
    @State private var lastAppliedDelta: Int = 0
    /// Reveals the ±-hour step buttons on hover. At rest the row reads
    /// as a quiet bookend (icon · hairline · label · time); the chevrons
    /// would otherwise compete with the NOW marker and the day-section
    /// header for the eye's attention. Drag-to-adjust on the row itself
    /// is unchanged, so the affordance is still keyboard- and
    /// accessibility-accessible without the buttons being visible at
    /// rest. Mirrors the same pattern as `BacklogTaskRow.controls`.
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: DS.Spacing.xs) {
            Image(systemName: kind.icon)
                .font(.system(size: 11, weight: skin.resolvedSymbolWeight, design: skin.resolvedFontDesign))
                .foregroundStyle(skin.resolvedTextTertiary)
                .opacity(0.55)
                .frame(width: DS.Size.iconSmall, alignment: .center)
                .accessibilityHidden(true)

            // Straight 18 pt hairline — matches the prototype `.wh-line .wh-rule`
            // (1 pt high, 18 pt wide) instead of a 28 pt capsule. The
            // straight rule reads as a measuring tick, not as a pill.
            Rectangle()
                .fill(skin.resolvedTextPrimary.opacity(DS.Fg.dividerOpacity * 0.7))
                .frame(width: 18, height: 1)

            Text(kind.label)
                .font(.system(size: 11, weight: .regular, design: skin.resolvedFontDesign))
                .foregroundStyle(skin.resolvedTextTertiary)
                .opacity(0.85)

            // Prototype `.wh-time`: fg-2 (secondary) bold, mono-tabular.
            // Dimmed one notch from `resolvedTextSecondary` to
            // `resolvedTextTertiary` so the bookend doesn't compete with
            // event rows or the NOW marker — these are reference ticks,
            // not row content.
            Text(timeString)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(skin.resolvedTextTertiary)
                .monospacedDigit()

            Spacer(minLength: DS.Spacing.sm)

            // Step buttons — ↑ decreases (earlier in the day), ↓
            // increases (later). Minimum-weight haptic on each press
            // so the user feels the adjustment. Hover-revealed so the
            // bookend stays calm at rest; drag-to-adjust on the row
            // itself still works for users who never hover.
            if isInteractive {
                HStack(spacing: 0) {
                    stepButton(systemImage: "chevron.up", delta: -1, help: "Earlier")
                    stepButton(systemImage: "chevron.down", delta: +1, help: "Later")
                }
                .opacity(isHovered ? 1 : 0)
                .accessibilityHidden(!isHovered)
            }
        }
        .padding(.horizontal, DS.Spacing.sm)
        .padding(.vertical, DS.Spacing.xxs)
        .contentShape(Rectangle())
        .onHover { hovering in
            isHovered = hovering
        }
        .gesture(
            DragGesture(minimumDistance: 4, coordinateSpace: .local)
                .onChanged { value in
                    guard isInteractive else { return }
                    if dragStartHour == nil {
                        dragStartHour = hour
                        lastAppliedDelta = 0
                    }
                    // Negative dy = drag up = earlier hour.
                    let stepPx: CGFloat = 24
                    let delta = Int((-value.translation.height / stepPx).rounded())
                    let stepDelta = delta - lastAppliedDelta
                    if stepDelta != 0 {
                        Haptics.tap()
                        onStep(stepDelta)
                        lastAppliedDelta = delta
                    }
                }
                .onEnded { _ in
                    dragStartHour = nil
                    lastAppliedDelta = 0
                },
            including: isInteractive ? .all : .none
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(kind.label), \(timeString)")
        .accessibilityHint(
            isInteractive
                ? "Drag up or down, or use chevron buttons, to adjust the working-hours boundary"
                : ""
        )
        .accessibilityAdjustableAction { direction in
            guard isInteractive else { return }
            switch direction {
            case .increment: onStep(+1)
            case .decrement: onStep(-1)
            @unknown default: break
            }
        }
    }

    private var timeString: String {
        // Locale-aware HH:00 string. The settings model uses integer
        // hours, so the minute component is always 00 — we still
        // route through DateFormatter so 12-hour locales render
        // «9:00 AM» / «6:00 PM» rather than «09:00 / 18:00» in
        // contexts where the user's preference says otherwise.
        var components = DateComponents()
        components.hour = hour
        components.minute = 0
        let date = Calendar.current.date(from: components) ?? Date()
        let f = DateFormatter()
        f.timeStyle = .short
        f.dateStyle = .none
        return f.string(from: date)
    }

    @ViewBuilder
    private func stepButton(systemImage: String, delta: Int, help: String) -> some View {
        // Prototype `.wh-step`: 22×22 px hit-area with a small radius so
        // a hover highlight reads as a button, not a tap-anywhere zone.
        Button {
            Haptics.tap()
            onStep(delta)
        } label: {
            Image(systemName: systemImage)
                .font(.caption.weight(.semibold))
                .foregroundStyle(skin.resolvedTextTertiary)
                .frame(width: 22, height: 22)
                .contentShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }
}
