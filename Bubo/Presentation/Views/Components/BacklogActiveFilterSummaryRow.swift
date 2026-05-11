import SwiftUI

/// Compact pill row mirroring the active filters when the meta-band is
/// collapsed. Each pill carries an inline `xmark` so a single tap removes
/// that filter; a trailing «Clear» button drops them all at once. The
/// row doesn't replicate the full chip set — it summarises only what is
/// currently engaged, so the chrome cost stays proportional to the
/// filter state.
///
/// All four filter sources (urgent toggle, smart, project, colour) cross
/// over as `@Binding` so per-pill clears stay local. The «Clear» button
/// fires `onClearAll`; the host owns the multi-write so a single
/// animation block can wrap the whole reset.
struct BacklogActiveFilterSummaryRow: View {
    @Binding var urgentOnlyFilter: Bool
    @Binding var smartFilter: BacklogLogic.SmartFilter?
    @Binding var projectFilter: String?
    @Binding var colorFilter: EventColorTag?
    let onClearAll: () -> Void

    @Environment(\.activeSkin) private var skin
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: DS.Spacing.xs) {
                if urgentOnlyFilter {
                    pill(label: "Urgent", icon: "exclamationmark.triangle") {
                        urgentOnlyFilter = false
                    }
                }
                if let smart = smartFilter {
                    pill(label: smart.label, icon: smart.systemImage) {
                        smartFilter = nil
                    }
                }
                if let project = projectFilter {
                    pill(label: project, icon: "folder") {
                        projectFilter = nil
                    }
                }
                if let color = colorFilter {
                    pill(
                        label: color.rawValue.capitalized,
                        icon: "circle.fill",
                        iconTint: color.color
                    ) {
                        colorFilter = nil
                    }
                }
                Button {
                    Haptics.tap()
                    withAnimation(DS.Animation.motionAware(DS.Animation.quick, reduceMotion: reduceMotion)) {
                        onClearAll()
                    }
                } label: {
                    Text("Clear")
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(skin.accentColor)
                        .padding(.horizontal, DS.Spacing.xs)
                        .padding(.vertical, DS.Spacing.xxs)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Clear all active filters")
                .accessibilityLabel("Clear all filters")
            }
            .padding(.horizontal, DS.Spacing.sm)
            .padding(.vertical, DS.Spacing.xxs)
        }
    }

    @ViewBuilder
    private func pill(
        label: String,
        icon: String,
        iconTint: Color? = nil,
        onClear: @escaping () -> Void
    ) -> some View {
        Button {
            Haptics.tap()
            withAnimation(DS.Animation.motionAware(DS.Animation.quick, reduceMotion: reduceMotion)) {
                onClear()
            }
        } label: {
            HStack(spacing: DS.Spacing.xxs) {
                Image(systemName: icon)
                    .font(.caption2)
                    .foregroundStyle(iconTint ?? skin.accentColor)
                Text(label)
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(skin.accentColor)
                Image(systemName: "xmark")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(skin.accentColor.opacity(DS.Opacity.softAccent))
            }
            .padding(.horizontal, DS.Spacing.sm)
            .padding(.vertical, DS.Spacing.xxs)
            .background(
                Capsule().fill(skin.accentColor.opacity(DS.Opacity.lightFill))
            )
            .overlay(
                Capsule().strokeBorder(
                    skin.accentColor.opacity(DS.Opacity.softAccent),
                    lineWidth: DS.Border.thin
                )
            )
        }
        .buttonStyle(.plain)
        .help("Remove \(label) filter")
        .accessibilityLabel("\(label) filter active — tap to remove")
    }
}
