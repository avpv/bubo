import SwiftUI

// MARK: - Ghost Event Row
//
// A translucent "phantom" block rendered in-line with real events while the
// user is typing a new task in the backlog. It answers the question "where
// would this task land?" in the exact spot the real event would appear —
// Birman's "sequential magic": show the result before the action.
//
// The ghost is pure visual: it has no hover state, no buttons, no drop
// handling. It exists only while `BacklogInteractionCoordinator.ghostSlot`
// is non-nil for the day it's rendered under.

struct GhostEventRow: View {
    @Environment(\.activeSkin) private var skin
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let start: Date
    let end: Date
    let title: String

    /// Slow breathing so the ghost reads as "pending" rather than "placed".
    @State private var pulse: Bool = false

    private var formattedRange: String {
        let fmt = DateFormatter()
        fmt.setLocalizedDateFormatFromTemplate("H:mm")
        return "\(fmt.string(from: start))–\(fmt.string(from: end))"
    }

    private var durationMinutes: Int {
        max(0, Int(end.timeIntervalSince(start) / 60))
    }

    private var durationLabel: String {
        // PRINCIPLES §3: use the shared `DS.formatMinutes` helper so
        // every duration string in the app reads with the same
        // non-breaking spaces between number and unit («3 h 15 min»
        // never breaks mid-quantity).
        DS.formatMinutes(durationMinutes)
    }

    var body: some View {
        HStack(alignment: .center, spacing: 0) {
            // Ghost accent bar — dashed outline echoes the style used by
            // free-slot rows but filled with accent so the eye can tell
            // this is *a thing that would exist*, not just an empty gap.
            // Level 4 (final): no leading offset — matches EventRowView's
            // urgency bar and FreeSlotRow's dashed guide so all three row
            // types share one vertical anchor column inside the platter.
            RoundedRectangle(cornerRadius: DS.Size.previewMicroRadius, style: .continuous)
                .fill(skin.accentColor.opacity(pulse ? 0.6 : 0.35))
                .frame(width: DS.Size.accentBarWidth, height: DS.Size.accentBarHeight)
                .padding(.trailing, DS.Spacing.md)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: DS.Spacing.xs) {
                    Image(systemName: "sparkles")
                        .font(.footnote)
                        .foregroundStyle(skin.accentColor.opacity(DS.Opacity.nearOpaque))
                    Text(title)
                        .font(.body.weight(.regular))
                        .foregroundStyle(skin.resolvedTextPrimary.opacity(DS.Opacity.loudOverlay))
                        .lineLimit(1)
                    Text("ghost")
                        .font(.footnote.weight(.semibold))
                        .tracking(0.5)
                        .padding(.horizontal, DS.Spacing.xs)
                        .padding(.vertical, DS.Spacing.hairline)
                        .background(
                            Capsule().fill(skin.accentColor.opacity(DS.Opacity.mediumFill))
                        )
                        .foregroundStyle(skin.accentColor)
                }

                Text("\(formattedRange)  ·  \(durationLabel)")
                    .font(.footnote.monospacedDigit())
                    .foregroundStyle(skin.resolvedTextTertiary)
            }

            Spacer(minLength: DS.Spacing.md)
        }
        .frame(minHeight: DS.Size.eventRowMinHeight)
        .padding(.vertical, DS.Spacing.xxs)
        .padding(.horizontal, DS.Spacing.sm)
        // Level 4 (final): flat row inside the timeline platter card —
        // same visual framework as EventRowView and FreeSlotRow. The
        // "ephemeral preview" feel comes from the pulsing fill +
        // semitransparent text + the explicit "ghost" badge, not from
        // a rounded pill border. The dashed rectangle border is kept
        // (now flat) because it's the single strongest signal "this
        // event doesn't exist yet", and it only shows during drag.
        .background(
            Rectangle()
                .fill(skin.accentColor.opacity(pulse ? 0.09 : 0.04))
        )
        .overlay(
            Rectangle()
                .strokeBorder(
                    skin.accentColor.opacity(pulse ? DS.Opacity.half : DS.Opacity.mutedStroke),
                    style: StrokeStyle(lineWidth: DS.Border.standard, dash: [4, 3])
                )
        )
        .contentShape(Rectangle())
        .allowsHitTesting(false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Preview: \(title) \(formattedRange)"))
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(DS.Animation.pulse().repeatForever(autoreverses: true)) {
                pulse.toggle()
            }
        }
    }
}
