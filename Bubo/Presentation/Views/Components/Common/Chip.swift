import SwiftUI

// MARK: - Chip Primitive
//
// One canonical horizontal control for every pill-shaped item in the
// popover: ranked SmartAction, More, capacity badge, Backlog entry,
// time-slot picker, hour picker, working-day picker.
//
// Before this primitive each call-site reinvented the same Capsule
// background + Capsule stroke + HStack(icon, text), each with its own
// padding, its own (or missing) `lineLimit(1)`, its own height. The
// result was a row of pills where every chip had a slightly different
// rhythm and where any chip could collapse vertically the moment a
// neighbour grew (the «vertical More» bug).
//
// Birman: один типографический ритм + одна форма + одна высота. The
// shape is always Capsule, the height is always `DS.Size.chipHeight`,
// the text is always single-line + truncated. Variants only change
// fill/stroke intensity.

/// Visual role for a chip within a row.
enum ChipVariant {
    /// Emphasised — quiet neutral fill + primary text. Use for the
    /// primary suggested actions (top-N ranked SmartActions chips).
    /// Native rule: emphasis comes from fill weight, not colour — accent
    /// stays reserved for the primary CTA and selection.
    case prominent

    /// Quietest — barely-tinted neutral fill + secondary text. Use for
    /// service / overflow chips (More, Backlog, capacity badge).
    case quiet

    /// On-state for picker cells (working day enabled, peak hour on,
    /// active time slot). Same fill intensity as `.prominent` but
    /// reads semantically as «selected», not «suggested».
    case selected

    /// Off-state companion to `.selected` for picker cells. Outline
    /// only, no fill. Reads as «available, not chosen».
    case unselected

    /// Status chip — coloured fill driven by the supplied tint
    /// (urgency, success, warning). Falls back to skin accent when
    /// no tint is provided.
    case status(Color)
}

/// Visual size for a chip. `regular` is the canonical 24 pt; `compact`
/// shrinks to 20 pt for dense pickers.
enum ChipSize {
    case regular
    case compact

    var height: CGFloat {
        switch self {
        case .regular: return DS.Size.chipHeight
        case .compact: return DS.Size.chipHeightCompact
        }
    }
}

/// A single chip — capsule-shaped, fixed-height, single-line text,
/// non-shrinking under horizontal pressure.
///
/// Use either the `title:` initialiser (icon + title + optional
/// trailing badge) or the `label:` initialiser (any custom view) when
/// the chip needs richer content.
struct ChipButton<Label: View>: View {
    let variant: ChipVariant
    let size: ChipSize
    /// When `true`, the chip stretches to fill its container's horizontal
    /// extent (used inside grids of equal-width chips — picker rows). When
    /// `false`, the chip hugs its content and refuses to compress (the
    /// default for toolbar chip rows where overflow scrolls).
    let fillsAvailableWidth: Bool
    let action: () -> Void
    @ViewBuilder let label: () -> Label

    @Environment(\.activeSkin) private var skin

    init(
        variant: ChipVariant,
        size: ChipSize = .regular,
        fillsAvailableWidth: Bool = false,
        action: @escaping () -> Void,
        @ViewBuilder label: @escaping () -> Label
    ) {
        self.variant = variant
        self.size = size
        self.fillsAvailableWidth = fillsAvailableWidth
        self.action = action
        self.label = label
    }

    var body: some View {
        Button(action: action) {
            label()
                .font(.footnote.weight(.regular))
                .lineLimit(1)
                .truncationMode(.tail)
                .modifier(ChipWidthModifier(fillsAvailableWidth: fillsAvailableWidth))
                .foregroundStyle(foreground)
                .padding(.horizontal, DS.Spacing.pillHorizontal)
                .frame(height: size.height)
                .frame(maxWidth: fillsAvailableWidth ? .infinity : nil)
                .background(Capsule().fill(fillColor))
                .overlay(
                    Capsule().strokeBorder(strokeColor, lineWidth: DS.Border.thin)
                )
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Variant resolution

    private var fillColor: Color {
        switch variant {
        case .prominent:
            // Native rule: suggested actions are emphasised by a quiet
            // neutral fill, not by colour. Accent is reserved for the
            // primary CTA and for selection.
            return skin.resolvedTextPrimary.opacity(DS.Opacity.lightFill)
        case .selected:
            return skin.accentColor.opacity(DS.Opacity.selectedChipFill)
        case .quiet, .unselected:
            return skin.resolvedTextPrimary.opacity(DS.Opacity.subtleFill)
        case .status(let tint):
            return tint.opacity(DS.Opacity.selectedChipFill)
        }
    }

    private var strokeColor: Color {
        switch variant {
        case .prominent, .quiet:
            // `borderIdle` (0.18), not `faintBorder` (0.10) — a 0.10
            // hairline vanishes over any wallpaper, which is why chips
            // read as washed-out (DESIGN_REVIEW R7). Same floor the
            // «+ Add task…» field already uses to stay visible.
            return skin.resolvedTextPrimary.opacity(DS.Opacity.borderIdle)
        case .selected:
            return skin.accentColor.opacity(DS.Opacity.softAccent)
        case .unselected:
            return skin.resolvedTextTertiary.opacity(DS.Opacity.mutedStroke)
        case .status(let tint):
            return tint.opacity(DS.Opacity.softAccent)
        }
    }

    private var foreground: Color {
        switch variant {
        case .prominent:
            return skin.resolvedTextPrimary
        case .selected:
            return skin.accentColor
        case .quiet:
            return skin.resolvedTextSecondary
        case .unselected:
            return skin.resolvedTextSecondary
        case .status(let tint):
            return tint
        }
    }
}

// MARK: - Convenience initialiser for the icon + title + badge case

extension ChipButton where Label == ChipDefaultLabel {
    /// Standard chip — optional SF Symbol, title, optional trailing
    /// numeric badge. Covers the SmartActions ranked-chip / More / capacity
    /// badge / Backlog entry shape.
    init(
        variant: ChipVariant,
        size: ChipSize = .regular,
        fillsAvailableWidth: Bool = false,
        icon: String? = nil,
        title: String,
        trailingBadge: String? = nil,
        action: @escaping () -> Void
    ) {
        self.init(
            variant: variant,
            size: size,
            fillsAvailableWidth: fillsAvailableWidth,
            action: action
        ) {
            ChipDefaultLabel(icon: icon, title: title, trailingBadge: trailingBadge)
        }
    }
}

/// Tiny helper that toggles `fixedSize(horizontal:)` on the label
/// without fighting the layout when `fillsAvailableWidth` is true.
private struct ChipWidthModifier: ViewModifier {
    let fillsAvailableWidth: Bool
    func body(content: Content) -> some View {
        if fillsAvailableWidth {
            content
        } else {
            content.fixedSize(horizontal: true, vertical: false)
        }
    }
}

/// Internal label for the convenience initialiser. Lives outside the
/// generic so SwiftUI doesn't have to specialise on the closure type
/// at every call-site.
struct ChipDefaultLabel: View {
    let icon: String?
    let title: String
    let trailingBadge: String?

    @Environment(\.activeSkin) private var skin

    var body: some View {
        HStack(spacing: DS.Spacing.xxs) {
            if let icon {
                Image(systemName: icon).font(.footnote)
            }
            Text(title)
            if let trailingBadge {
                Text(trailingBadge)
                    .font(.footnote.monospacedDigit())
                    .foregroundStyle(skin.resolvedTextTertiary)
            }
        }
    }
}

// MARK: - Chip Row Container
//
// Wraps a row of chips in a `FlowLayout` so they never crush each
// other and never bleed past the surface edge. Without this container
// an `HStack` will compress chips when siblings claim space; an
// unclipped `ScrollView` solves the compression but lets the row
// overflow and overlap neighbouring views (the failure mode visible
// in the menu-bar smart-actions row). `FlowLayout` keeps each chip
// at its natural width and wraps to the next line when the row runs
// out of horizontal room — the prototype behaviour from
// `ui_kits/menubar/index.html` (.bb-chip-row uses flex-wrap).

struct ChipRow<Content: View>: View {
    /// Optional outer horizontal padding. Defaults to `DS.Spacing.sm`
    /// so the first/last chip aren't flush against the surface edge.
    var horizontalPadding: CGFloat = DS.Spacing.sm

    @ViewBuilder let content: () -> Content

    var body: some View {
        FlowLayout(spacing: DS.Spacing.xs) {
            content()
        }
        // Pin the rail to the leading edge. FlowLayout reports its
        // content width, so without this a short rail (one chip) floats
        // to wherever the host container aligns it — a centred VStack
        // produced a lone chip hovering mid-popover in the backlog.
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, horizontalPadding)
        .padding(.vertical, DS.Spacing.xxs)
    }
}
