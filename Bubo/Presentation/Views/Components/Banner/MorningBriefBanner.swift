import SwiftUI

// MARK: - Morning Brief Banner
//
// E1 ("Снять с себя должность главного диспетчера") — the visible
// proof that the optimizer worked while the user was away. Persistent
// (not a toast), shown once per calendar day the first time the
// popover opens with fresh overnight work to report. Dismissable.
//
// The banner reads three pieces of state from `@AppStorage` written by
// `MenuBarView.runAutoDeferIfNeeded`:
//
//   • `BuboMorningBriefDay` — ISO day key the brief was generated for.
//     Matches against `MenuBarView.dayKey(for:)` so a brief from
//     yesterday vanishes silently when the day rolls.
//   • `BuboMorningBriefDeferred` — number of overdue tasks moved
//     forward by AutoDefer. Drives the headline copy.
//   • `BuboMorningBriefDismissedDay` — last ISO day the user
//     dismissed the banner. Mirrors the End-of-Day banner gate so the
//     same `@AppStorage` discipline is used.
//
// Birman: "machine sweats so the human doesn't have to" — the brief is
// the receipt. Without it, the work is invisible.

struct MorningBriefBanner: View {
    let deferredCount: Int
    /// Free-form "what else happened overnight" string. Optional —
    /// when nil, the banner shows only the deferral count. Hosts can
    /// fill this in once additional overnight signals (shadow-proposal
    /// refresh, locked-event drift, energy curve updates) are wired
    /// in. Keeps the banner future-proof without forcing every
    /// signal to land at the same time.
    var detail: String? = nil
    let onDismiss: () -> Void
    /// Optional "Show what changed" affordance — opens the backlog
    /// so the user can see the carried-forward tasks. nil = button
    /// hidden, banner shows headline + dismiss only.
    var onShowDetails: (() -> Void)? = nil

    @Environment(\.activeSkin) private var skin

    var body: some View {
        HStack(alignment: .top, spacing: DS.Spacing.sm) {
            Image(systemName: "sparkles")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(skin.accentColor)
                .frame(width: 20, alignment: .center)

            VStack(alignment: .leading, spacing: 1) {
                Text(headline)
                    .font(.system(size: 12.5, weight: .semibold, design: skin.resolvedFontDesign))
                    .foregroundStyle(skin.resolvedTextPrimary)
                    .lineLimit(1)
                if let detail {
                    Text(detail)
                        .font(.system(size: 11.5, weight: .regular, design: skin.resolvedFontDesign))
                        .foregroundStyle(skin.resolvedTextTertiary)
                        .lineLimit(2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if let onShowDetails {
                Button {
                    Haptics.tap()
                    onShowDetails()
                } label: {
                    Text("Review")
                        .font(.system(size: 11.5, weight: .semibold, design: skin.resolvedFontDesign))
                        .foregroundStyle(skin.accentColor)
                        .padding(.horizontal, DS.Spacing.sm)
                        .padding(.vertical, DS.Spacing.xxs)
                        .background(
                            Capsule().fill(skin.accentColor.opacity(DS.Mix.accentLight))
                        )
                }
                .buttonStyle(.plain)
                .help("Open the backlog to see what carried forward")
            }

            Button {
                Haptics.tap()
                onDismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(skin.resolvedTextTertiary)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Dismiss")
            .accessibilityLabel("Dismiss morning brief")
        }
        .padding(.horizontal, DS.Spacing.md)
        .padding(.vertical, DS.Spacing.sm)
        .background(
            RoundedRectangle(cornerRadius: DS.Size.radiusMd, style: .continuous)
                .fill(skin.accentColor.opacity(DS.Mix.accentLight))
        )
        .overlay(
            RoundedRectangle(cornerRadius: DS.Size.radiusMd, style: .continuous)
                .strokeBorder(skin.accentColor.opacity(DS.Mix.accentStrong), lineWidth: DS.Border.thin)
        )
        .padding(.horizontal, DS.Spacing.contentMargin)
        .padding(.vertical, DS.Spacing.xs)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
        .transition(.move(edge: .top).combined(with: .opacity))
    }

    private var headline: String {
        if deferredCount == 0 {
            return "Plan refreshed overnight"
        }
        if deferredCount == 1 {
            return "Moved 1 task to today"
        }
        return "Moved \(deferredCount) tasks to today"
    }

    private var accessibilityLabel: String {
        if let detail {
            return "\(headline). \(detail)"
        }
        return headline
    }
}
