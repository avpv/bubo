import SwiftUI

/// End-of-workday «3 unfinished · roll to tomorrow?» nudge. Lives at
/// the top of the timeline next to (or in place of) the
/// `EnergyCheckInBanner`. Surfaces only when the user opens Bubo
/// after working hours and there's at least one task scheduled for
/// today that isn't done yet.
///
/// Birman: «not a notification, not a modal, but a quiet strip with one
/// action». One tap rolls every today-incomplete task back to
/// pending, with a unified undo toast that restores the original
/// schedule.
struct RollForwardBanner: View {
    @Environment(\.activeSkin) private var skin
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// How many tasks would be rolled (drives the headline copy).
    let unfinishedCount: Int
    /// Roll today's incomplete tasks to backlog. Host runs the
    /// optimizer separately if it wants tomorrow auto-scheduled.
    let onRoll: () -> Void
    /// Hide the banner without rolling — host stores a per-day
    /// dismissed flag so it doesn't re-appear later the same evening.
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: DS.Spacing.sm) {
            Image(systemName: "moon.stars.fill")
                .font(.footnote)
                .foregroundStyle(skin.accentColor)
                .symbolRenderingMode(.hierarchical)
                .accessibilityHidden(true)

            Text(headlineCopy)
                .font(.footnote)
                .foregroundStyle(skin.resolvedTextPrimary)
                .lineLimit(1)

            Spacer(minLength: DS.Spacing.xs)

            Button {
                Haptics.tap()
                onRoll()
            } label: {
                Text("Roll forward")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(skin.accentColor)
                    .padding(.horizontal, DS.Spacing.sm)
                    .padding(.vertical, DS.Spacing.xxs)
                    .background(
                        Capsule().fill(skin.accentColor.opacity(DS.Opacity.subtleFill))
                    )
                    .overlay(
                        Capsule().strokeBorder(
                            skin.accentColor.opacity(DS.Opacity.softAccent),
                            lineWidth: DS.Border.thin
                        )
                    )
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Roll \(unfinishedCount) unfinished task\(unfinishedCount == 1 ? "" : "s") forward to tomorrow")

            Button {
                Haptics.tap()
                onDismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(skin.resolvedTextTertiary)
                    .symbolRenderingMode(.hierarchical)
                    .frame(width: 16, height: 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .frame(width: DS.Size.controlHeight, height: DS.Size.controlHeight)
            .accessibilityLabel("Dismiss roll-forward prompt")
        }
        .padding(.horizontal, DS.Spacing.md)
        .padding(.vertical, DS.Spacing.xs)
        .background(
            RoundedRectangle(cornerRadius: DS.Size.cornerRadius, style: .continuous)
                .fill(skin.accentColor.opacity(DS.Opacity.lightFill))
        )
        .overlay(
            RoundedRectangle(cornerRadius: DS.Size.cornerRadius, style: .continuous)
                .strokeBorder(skin.accentColor.opacity(DS.Opacity.subtleBorder), lineWidth: DS.Border.thin)
        )
        .padding(.horizontal, DS.Spacing.sm)
        .padding(.top, DS.Spacing.xs)
        .transition(reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity))
    }

    private var headlineCopy: String {
        switch unfinishedCount {
        case 1:  return "1 task unfinished today"
        default: return "\(unfinishedCount) tasks unfinished today"
        }
    }
}
