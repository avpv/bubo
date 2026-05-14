import SwiftUI

// MARK: - StatPill
//
// Small icon + label pill for surfacing a single statistic. Used in:
// - Backlog inbox-zero empty state: «✓ 5 done today», «🔥 3-day streak»
// - Pomodoro mini-window foot: «🔥 2 done today», «☕ break in 18 m»
// - Settings General → keyboard shortcuts grid: «⌘B Backlog»
//   (uses KbdRow instead — StatPill is for SF Symbol + text)
//
// Distinct from `ChipButton` because it's read-only — there's no
// action attached. Distinct from `Badge` because it carries a
// label alongside the symbol, not just a count.

/// One read-only statistic chip. Renders as: SF Symbol + label,
/// inside a pill with subtle skin-aware background. Pass `tint`
/// to override the symbol colour (e.g. green check, orange flame).
struct StatPill: View {
    let icon: String
    let label: String
    let tint: Color?

    @Environment(\.activeSkin) private var skin

    init(icon: String, label: String, tint: Color? = nil) {
        self.icon = icon
        self.label = label
        self.tint = tint
    }

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(tint ?? skin.accentColor)
            Text(label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(skin.resolvedTextSecondary)
        }
        .padding(.horizontal, DS.Spacing.sm)
        .padding(.vertical, 4)
        .background(
            Capsule(style: .continuous)
                .fill(skin.resolvedTextPrimary.opacity(DS.Opacity.subtleFill + 0.02))
        )
        .overlay(
            Capsule(style: .continuous)
                .strokeBorder(
                    skin.resolvedTextPrimary.opacity(DS.Opacity.faintBorder),
                    lineWidth: 0.5
                )
        )
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Preview

#if DEBUG
#Preview("StatPill · variants") {
    VStack(alignment: .leading, spacing: DS.Spacing.lg) {
        // Backlog inbox-zero
        VStack(alignment: .leading, spacing: DS.Spacing.xs) {
            Text("Inbox zero — nice work").font(.headline)
            HStack(spacing: DS.Spacing.xs) {
                StatPill(icon: "checkmark.circle.fill", label: "5 done today", tint: .green)
                StatPill(icon: "flame.fill", label: "3-day streak", tint: .orange)
            }
        }

        // Pomodoro foot
        VStack(alignment: .leading, spacing: DS.Spacing.xs) {
            Text("Pomodoro mini foot").font(.headline)
            HStack(spacing: DS.Spacing.md) {
                StatPill(icon: "flame.fill", label: "2 done today", tint: .orange)
                StatPill(icon: "cup.and.saucer.fill", label: "break in 18 m", tint: .blue)
            }
        }

        // Default tint (accent)
        VStack(alignment: .leading, spacing: DS.Spacing.xs) {
            Text("Default tint = skin accent").font(.headline)
            HStack(spacing: DS.Spacing.xs) {
                StatPill(icon: "sparkles", label: "AI ready")
                StatPill(icon: "calendar.badge.clock", label: "Next in 12 min")
            }
        }
    }
    .padding()
    .frame(width: 360)
}
#endif
