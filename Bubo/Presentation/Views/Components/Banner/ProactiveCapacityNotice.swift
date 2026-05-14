import SwiftUI
import BuboDomain

// MARK: - Proactive Capacity Notice
//
// Main-Job fix #3: when the user's accumulated workload exceeds today's
// working window (forecast `.over` or `.afterHours`), the optimizer
// shouldn't silently accept the overload — it should **push back**.
// This banner is the visible push-back: one line of diagnosis, two or
// three one-tap remedies.
//
// The shape is intentionally close to `TipBanner` — it IS a TipBanner
// shape, with destructive/warning tone, multiple trailing actions, and
// a dismiss affordance. We don't reach for an alert dialog because the
// situation isn't blocking — the user can ignore the push-back and
// keep going. The banner stays in the popover until dismissed or until
// the forecast drops back to `.fits`.
//
// Birman: «делегат, который соглашается на всё, — не делегат, а
// исполнитель приказов».

struct ProactiveCapacityNotice: View {
    /// "47 min over" / "1 h 12 min into after-hours" — host computes
    /// the concrete overload value from `CapacityForecast`.
    let overloadDescription: String
    /// Forecast tone — `.over` uses warning, `.afterHours` uses
    /// destructive. Drives the banner colour.
    let isAfterHours: Bool
    /// "Spread to tomorrow" — the loud primary verb. Routes through
    /// `OptimizerService.executeRequest(.scheduleBacklog)`. nil = hidden.
    var onSpread: (() -> Void)? = nil
    /// "Defer least urgent" — picks the lowest-priority pending task
    /// and snoozes it to next workday. nil = hidden.
    var onDeferLeast: (() -> Void)? = nil
    /// "I'll handle it" — dismiss without action.
    let onDismiss: () -> Void

    @Environment(\.activeSkin) private var skin

    var body: some View {
        let tint = isAfterHours ? skin.resolvedDestructiveColor : skin.resolvedWarningColor
        VStack(alignment: .leading, spacing: DS.Spacing.sm) {
            HStack(alignment: .top, spacing: DS.Spacing.sm) {
                Image(systemName: isAfterHours ? "exclamationmark.octagon.fill" : "exclamationmark.triangle.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(tint)
                    .frame(width: 20, alignment: .center)

                VStack(alignment: .leading, spacing: 2) {
                    Text(headline)
                        .font(.system(size: 12.5, weight: .semibold, design: skin.resolvedFontDesign))
                        .foregroundStyle(skin.resolvedTextPrimary)
                    Text("Want me to handle this for you?")
                        .font(.system(size: 11.5, weight: .regular, design: skin.resolvedFontDesign))
                        .foregroundStyle(skin.resolvedTextSecondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

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
                .help("I'll handle it — dismiss this notice")
                .accessibilityLabel("Dismiss")
            }

            // Action row — primary then secondary. Buttons sit on
            // separate visual lanes (filled vs hollow) so the hierarchy
            // reads without color overlap with the banner tint.
            HStack(spacing: DS.Spacing.sm) {
                if let onSpread {
                    Button {
                        Haptics.impact()
                        onSpread()
                    } label: {
                        HStack(spacing: DS.Spacing.xs) {
                            Image(systemName: "arrow.forward.to.line")
                                .font(.system(size: 10, weight: .semibold))
                            Text("Spread to tomorrow")
                                .font(.system(size: 11.5, weight: .semibold, design: skin.resolvedFontDesign))
                        }
                        .foregroundStyle(DS.contrastingForeground(for: tint))
                        .padding(.horizontal, DS.Spacing.md)
                        .padding(.vertical, DS.Spacing.xs)
                        .background(
                            Capsule(style: .continuous).fill(tint)
                        )
                    }
                    .buttonStyle(.plain)
                    .help("Spread overflow into tomorrow's free time")
                }

                if let onDeferLeast {
                    Button {
                        Haptics.tap()
                        onDeferLeast()
                    } label: {
                        Text("Defer least urgent")
                            .font(.system(size: 11.5, weight: .medium, design: skin.resolvedFontDesign))
                            .foregroundStyle(tint)
                            .padding(.horizontal, DS.Spacing.md)
                            .padding(.vertical, DS.Spacing.xs)
                            .background(
                                Capsule(style: .continuous)
                                    .stroke(tint.opacity(DS.Mix.accentStrong), lineWidth: DS.Border.thin)
                            )
                    }
                    .buttonStyle(.plain)
                    .help("Push the lowest-priority pending task to the next workday")
                }

                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, DS.Spacing.md)
        .padding(.vertical, DS.Spacing.sm)
        .background(
            RoundedRectangle(cornerRadius: DS.Size.radiusMd, style: .continuous)
                .fill(tint.opacity(DS.Mix.accentLight))
        )
        .overlay(
            RoundedRectangle(cornerRadius: DS.Size.radiusMd, style: .continuous)
                .strokeBorder(tint.opacity(DS.Mix.accentStrong), lineWidth: DS.Border.thin)
        )
        .padding(.horizontal, DS.Spacing.contentMargin)
        .padding(.vertical, DS.Spacing.xs)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
        .transition(.move(edge: .top).combined(with: .opacity))
    }

    private var headline: String {
        if isAfterHours {
            return "Today's plan runs into after-hours by \(overloadDescription)."
        }
        return "Today is tight — \(overloadDescription) past your working window."
    }

    private var accessibilityLabel: String {
        "Capacity alert: \(headline)"
    }
}
