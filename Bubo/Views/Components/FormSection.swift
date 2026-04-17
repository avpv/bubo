import SwiftUI

// MARK: - Inset Grouped Form Primitives
//
// Apple Reminders-style inset grouped lists. HIG: every form control lives in
// a rounded card; section titles are quiet subheads above the card; rows
// share one rhythm of radii, insets, and chevrons.
//
// Birman: one typographic voice for section labels (reuses
// `sectionHeaderStyle()`), one rhythm of radii (12 cards / 8 inline / 20
// pills), разделители только внутри одной группы, не между.
//
// Spacing convention inside forms:
//   • `DS.Spacing.sm` between a section's header label and its card.
//   • `DS.Spacing.lg` between two adjacent sections.
//   • `DS.Spacing.md` between a section and its footnote.

/// A single inset-grouped-list section: an optional uppercase header,
/// a platter card, and an optional footnote below the card.
///
/// ```swift
/// FormSection(header: "Date & Time", footnote: "Alarms activate even in Focus mode.") {
///     FormRow(icon: "calendar", iconTint: .red, title: "Date", trailing: { Text("Today") })
///     FormDivider()
///     FormRow(icon: "clock", iconTint: .blue, title: "Time", trailing: { Text("18:00") })
/// }
/// ```
struct FormSection<Content: View>: View {
    private let header: String?
    private let footnote: String?
    private let content: () -> Content

    @Environment(\.activeSkin) private var skin

    init(
        header: String? = nil,
        footnote: String? = nil,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.header = header
        self.footnote = footnote
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.sm) {
            if let header {
                SectionLabel(text: header)
                    .padding(.horizontal, DS.Spacing.xs)
            }

            VStack(spacing: 0) {
                content()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .skinPlatter(skin)
            .skinPlatterDepth(skin)

            if let footnote {
                Text(footnote)
                    .font(.caption2)
                    .foregroundStyle(skin.resolvedTextTertiary)
                    .padding(.horizontal, DS.Spacing.xs)
                    .padding(.top, DS.Spacing.xxs)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// MARK: - Form Row

/// A single row inside a `FormSection`. Matches the Reminders row anatomy:
///   • leading colored-tile icon (HIG: tinted glyph on rounded-square fill),
///   • title (+ optional subtitle),
///   • optional trailing value view,
///   • optional chevron (for navigable rows).
struct FormRow<Trailing: View>: View {
    private let icon: String?
    private let iconTint: Color?
    private let title: String
    private let subtitle: String?
    private let isNavigable: Bool
    private let action: (() -> Void)?
    private let trailing: () -> Trailing

    @Environment(\.activeSkin) private var skin
    @State private var isHovered = false

    init(
        icon: String? = nil,
        iconTint: Color? = nil,
        title: String,
        subtitle: String? = nil,
        isNavigable: Bool = false,
        action: (() -> Void)? = nil,
        @ViewBuilder trailing: @escaping () -> Trailing
    ) {
        self.icon = icon
        self.iconTint = iconTint
        self.title = title
        self.subtitle = subtitle
        self.isNavigable = isNavigable
        self.action = action
        self.trailing = trailing
    }

    var body: some View {
        let rowContent = HStack(spacing: DS.Spacing.md) {
            if let icon {
                IconTile(systemImage: icon, tint: iconTint ?? skin.resolvedTextSecondary)
            }

            VStack(alignment: .leading, spacing: DS.Spacing.xxs) {
                Text(title)
                    .font(.body)
                    .foregroundStyle(skin.resolvedTextPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)

                if let subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(skin.resolvedTextTertiary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: DS.Spacing.sm)

            trailing()
                .foregroundStyle(skin.resolvedTextSecondary)

            if isNavigable {
                Image(systemName: "chevron.right")
                    .font(.system(size: DS.Size.iconSmall, weight: .semibold))
                    .foregroundStyle(DS.Colors.textQuaternary)
            }
        }
        .padding(.horizontal, DS.Spacing.md)
        .frame(minHeight: DS.Size.backlogRowHeight)
        .contentShape(Rectangle())
        .background(
            action != nil && isHovered
                ? skin.resolvedHoverFill
                : Color.clear
        )

        if let action {
            Button(action: action) { rowContent }
                .buttonStyle(.plain)
                .onHover { isHovered = $0 }
        } else {
            rowContent
        }
    }
}

extension FormRow where Trailing == EmptyView {
    /// Convenience initializer for rows with no trailing view.
    init(
        icon: String? = nil,
        iconTint: Color? = nil,
        title: String,
        subtitle: String? = nil,
        isNavigable: Bool = false,
        action: (() -> Void)? = nil
    ) {
        self.init(
            icon: icon,
            iconTint: iconTint,
            title: title,
            subtitle: subtitle,
            isNavigable: isNavigable,
            action: action,
            trailing: { EmptyView() }
        )
    }
}

// MARK: - Form Divider

/// Separator between rows inside the same `FormSection` card. Inset to align
/// with the row title column (leaves the icon tile column clear, matching
/// iOS inset-grouped-list behavior).
struct FormDivider: View {
    /// Set to `true` when the preceding row has no icon tile so the divider
    /// extends full-width (matches Reminders footnote-style separator).
    private let fullWidth: Bool

    init(fullWidth: Bool = false) {
        self.fullWidth = fullWidth
    }

    private var leadingInset: CGFloat {
        // IconTile width + horizontal padding inside FormRow.
        fullWidth ? DS.Spacing.md : (DS.Spacing.md + IconTile.size + DS.Spacing.md)
    }

    var body: some View {
        SkinSeparator()
            .padding(.leading, leadingInset)
    }
}

// MARK: - Icon Tile

/// The signature Reminders-style rounded-square colored icon. Used as the
/// leading element of a `FormRow` (and anywhere a list item needs a
/// tinted-glyph tile).
///
/// Birman: один ритм радиусов — здесь 8pt, как `subtleCornerRadius`, чтобы
/// иконки в форме не спорили с 12pt углами platter'ов.
struct IconTile: View {
    static let size: CGFloat = 28

    private let systemImage: String
    private let tint: Color

    init(systemImage: String, tint: Color) {
        self.systemImage = systemImage
        self.tint = tint
    }

    var body: some View {
        RoundedRectangle(cornerRadius: DS.Size.subtleCornerRadius, style: .continuous)
            .fill(tint)
            .frame(width: Self.size, height: Self.size)
            .overlay(
                Image(systemName: systemImage)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(DS.contrastingForeground(for: tint))
            )
            .accessibilityHidden(true)
    }
}

// MARK: - Form Toggle Row

/// Convenience: a row with a trailing `Toggle`. The toggle binds directly
/// so the row feels like a single affordance.
struct FormToggleRow: View {
    private let icon: String?
    private let iconTint: Color?
    private let title: String
    private let subtitle: String?
    @Binding private var isOn: Bool

    init(
        icon: String? = nil,
        iconTint: Color? = nil,
        title: String,
        subtitle: String? = nil,
        isOn: Binding<Bool>
    ) {
        self.icon = icon
        self.iconTint = iconTint
        self.title = title
        self.subtitle = subtitle
        self._isOn = isOn
    }

    var body: some View {
        FormRow(
            icon: icon,
            iconTint: iconTint,
            title: title,
            subtitle: subtitle,
            trailing: {
                Toggle("", isOn: $isOn)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .labelsHidden()
            }
        )
    }
}
