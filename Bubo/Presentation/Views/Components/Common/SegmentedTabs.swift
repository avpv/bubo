import SwiftUI

// MARK: - Segmented Tabs
//
// Generic segmented tab strip used by:
//
//   • Settings popover (prototype `.settings-tabs` —
//     `prototype-spec.md` §9): "Calendars / Reminders / AI / Apple
//     Reminders / Appearance / About". Active tab fills with `fg-1`
//     6 %, accent stripe underneath.
//   • Backlog scope seg (`.seg` in §2): "📥 All (2) / ✓ Scheduled (1)
//     / ○ Completed (0)". Active = filled, inactive = quiet.
//
// One generic primitive with a `tabs:` array of (icon?, label,
// badge?) entries plus a `selection` binding. Visual variant
// (`pageTabs` for the underlined settings strip vs `inlineSeg` for
// the backlog scope chips) swaps fill / stroke / underline without
// changing the API.

enum SegmentedTabsStyle {
    /// Page-level tabs with an accent underline on the active item.
    /// Matches `.settings-tabs`.
    case pageTabs
    /// Inline scope chips that fill on select. Matches `.seg` and
    /// any "All / Scheduled / Completed" row.
    case inlineSeg
}

struct SegmentedTab: Identifiable, Hashable {
    let id: String
    /// SF Symbol or literal glyph; nil = no leading icon.
    var systemImage: String? = nil
    var glyph: String? = nil
    let label: String
    /// Optional trailing count badge.
    var badge: Int? = nil
}

struct SegmentedTabs: View {
    let tabs: [SegmentedTab]
    @Binding var selection: String
    var style: SegmentedTabsStyle = .inlineSeg

    @Environment(\.activeSkin) private var skin

    var body: some View {
        HStack(spacing: style == .pageTabs ? 2 : DS.Spacing.xs) {
            ForEach(tabs) { tab in
                tabView(tab)
            }
        }
    }

    @ViewBuilder
    private func tabView(_ tab: SegmentedTab) -> some View {
        let isActive = tab.id == selection
        Button {
            Haptics.tap()
            selection = tab.id
        } label: {
            HStack(spacing: DS.Spacing.xs) {
                if let glyph = tab.glyph {
                    Text(glyph)
                        .font(.system(size: 11))
                } else if let systemImage = tab.systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: 11, weight: skin.resolvedSymbolWeight))
                }
                Text(tab.label)
                    .font(.system(size: 12, weight: .medium, design: skin.resolvedFontDesign))
                if let badge = tab.badge {
                    Text("\(badge)")
                        .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                        .opacity(isActive ? 0.85 : 0.55)
                }
            }
            .foregroundStyle(isActive ? skin.resolvedTextPrimary : skin.resolvedTextSecondary)
            .padding(.horizontal, style == .pageTabs ? DS.Spacing.sm : DS.Spacing.md)
            .padding(.vertical, style == .pageTabs ? DS.Spacing.xs : 5)
            .background(backgroundView(isActive: isActive))
            .overlay(alignment: .bottom) {
                if style == .pageTabs, isActive {
                    // 2 pt accent underline — the prototype's
                    // `.settings-tab[data-active]::after` indicator.
                    Rectangle()
                        .fill(skin.accentColor)
                        .frame(height: 2)
                        .padding(.horizontal, DS.Spacing.sm)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(tab.label)
        .accessibilityAddTraits(isActive ? [.isButton, .isSelected] : .isButton)
    }

    @ViewBuilder
    private func backgroundView(isActive: Bool) -> some View {
        switch style {
        case .pageTabs:
            // Subtle fg-1 6 % fill on the active page tab, transparent
            // when inactive. The accent underline carries the active
            // signal — fill is the second channel.
            RoundedRectangle(cornerRadius: DS.Size.radiusSm, style: .continuous)
                .fill(skin.resolvedTextPrimary.opacity(isActive ? DS.Mix.surfaceFilter : 0))
        case .inlineSeg:
            Capsule(style: .continuous)
                .fill(isActive ? skin.accentColor.opacity(DS.Mix.accentLight) : .clear)
                .overlay(
                    Capsule(style: .continuous)
                        .strokeBorder(
                            isActive
                                ? skin.accentColor.opacity(DS.Mix.accentStrong)
                                : skin.resolvedTextPrimary.opacity(DS.Mix.surfaceDivider),
                            lineWidth: DS.Border.thin
                        )
                )
        }
    }
}
