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
    let onStep: (Int) -> Void  // delta in hours (typically ±1)

    @Environment(\.activeSkin) private var skin
    @State private var dragStartHour: Int? = nil
    @State private var lastAppliedDelta: Int = 0

    var body: some View {
        HStack(spacing: DS.Spacing.sm) {
            Image(systemName: kind.icon)
                .font(.footnote)
                .foregroundStyle(skin.resolvedTextTertiary)
                .frame(width: DS.Size.iconSmall, alignment: .center)
                .accessibilityHidden(true)

            // Hairline divider sits next to the label so the row reads
            // as «boundary indicator» rather than another event.
            Capsule()
                .fill(skin.resolvedTextTertiary.opacity(DS.Opacity.mutedStroke))
                .frame(height: 1)
                .frame(width: 28)

            Text(kind.label)
                .font(DS.Typography.machineHint)
                .foregroundStyle(skin.resolvedTextTertiary)

            Text(timeString)
                .font(DS.Typography.machineHint)
                .foregroundStyle(skin.resolvedTextSecondary)
                .padding(.horizontal, DS.Spacing.xs)
                .padding(.vertical, DS.Spacing.xxs)
                .background(
                    Capsule().fill(skin.resolvedTextTertiary.opacity(0.08))
                )

            Spacer(minLength: DS.Spacing.sm)

            // Step buttons — ↑ decreases (earlier in the day), ↓
            // increases (later). Minimum-weight haptic on each press
            // so the user feels the adjustment.
            stepButton(systemImage: "chevron.up", delta: -1, help: "Earlier")
            stepButton(systemImage: "chevron.down", delta: +1, help: "Later")
        }
        .padding(.horizontal, DS.Spacing.sm)
        .padding(.vertical, DS.Spacing.xxs)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 4, coordinateSpace: .local)
                .onChanged { value in
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
                }
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(kind.label), \(timeString)")
        .accessibilityHint("Drag up or down, or use chevron buttons, to adjust the working-hours boundary")
        .accessibilityAdjustableAction { direction in
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
        Button {
            Haptics.tap()
            onStep(delta)
        } label: {
            Image(systemName: systemImage)
                .font(.caption.weight(.semibold))
                .foregroundStyle(skin.resolvedTextTertiary)
                .frame(width: 18, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }
}
