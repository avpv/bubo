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
        if durationMinutes < 60 {
            return "\(durationMinutes) min"
        }
        let h = durationMinutes / 60
        let m = durationMinutes % 60
        return m == 0 ? "\(h) h" : "\(h) h \(m) min"
    }

    var body: some View {
        HStack(alignment: .center, spacing: 0) {
            // Ghost accent bar — dashed outline echoes the style used by
            // free-slot rows but filled with accent so the eye can tell
            // this is *a thing that would exist*, not just an empty gap.
            RoundedRectangle(cornerRadius: 1, style: .continuous)
                .fill(skin.accentColor.opacity(pulse ? 0.6 : 0.35))
                .frame(width: DS.Size.accentBarWidth, height: DS.Size.accentBarHeight)
                .padding(.trailing, DS.Spacing.md)
                .padding(.leading, 2)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: DS.Spacing.xs) {
                    Image(systemName: "sparkles")
                        .font(.caption2)
                        .foregroundStyle(skin.accentColor.opacity(0.9))
                    Text(title)
                        .font(.callout.weight(.medium))
                        .foregroundStyle(skin.resolvedTextPrimary.opacity(0.85))
                        .lineLimit(1)
                    Text("ghost")
                        .font(.caption2.weight(.semibold))
                        .tracking(0.5)
                        .padding(.horizontal, DS.Spacing.xs)
                        .padding(.vertical, 1)
                        .background(
                            Capsule().fill(skin.accentColor.opacity(0.12))
                        )
                        .foregroundStyle(skin.accentColor)
                }

                Text("\(formattedRange)  ·  \(durationLabel)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(skin.resolvedTextTertiary)
            }

            Spacer(minLength: DS.Spacing.md)
        }
        .frame(minHeight: DS.Size.eventRowMinHeight)
        .padding(.vertical, DS.Spacing.xxs)
        .padding(.horizontal, DS.Spacing.sm)
        .background(
            RoundedRectangle(cornerRadius: DS.Size.cornerRadius, style: .continuous)
                .fill(skin.accentColor.opacity(pulse ? 0.09 : 0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: DS.Size.cornerRadius, style: .continuous)
                .strokeBorder(
                    skin.accentColor.opacity(pulse ? 0.55 : 0.28),
                    style: StrokeStyle(lineWidth: 1, dash: [4, 3])
                )
        )
        .contentShape(Rectangle())
        .allowsHitTesting(false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Preview: \(title) \(formattedRange)"))
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) {
                pulse.toggle()
            }
        }
    }
}
