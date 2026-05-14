import SwiftUI

// MARK: - SettingsRow
//
// One canonical row for any form-shaped surface: Settings tabs, the
// event/task editor, the intent composer. Before this primitive,
// each tab and form re-implemented the `icon · label · hint · control`
// triangle with subtly different rhythm. The mockup
// (ui_kits/index2.html `.settings-row`) and the design docs
// (`docs/design/screens/event-editor.md`, `settings.md`,
// `intent-composer.md`) converge on this one shape.
//
// Layout: leading icon · label-stack (title + optional hint
// sub-line) · trailing content (value, toggle, disclosure chevron,
// custom picker). Heights snap to the same grid as `ChipButton` so
// stacked rows breathe the same air as chip rails sitting nearby.
//
// Birman: одна форма для одной работы. The «field row» is a single
// archetype here, not a sliding scale of «sometimes there's an icon,
// sometimes a hint, sometimes a control».

/// A single labelled row inside a settings-style form.
///
/// Use `SettingsRow.value(...)`, `.toggle(...)`, `.disclosure(...)`
/// for the common shapes. The free-form `init(icon:iconTint:label:hint:control:)`
/// covers anything else.
struct SettingsRow<Control: View>: View {
    let icon: String?
    let iconTint: Color?
    let label: String
    let hint: String?
    @ViewBuilder let control: () -> Control

    @Environment(\.activeSkin) private var skin

    init(
        icon: String? = nil,
        iconTint: Color? = nil,
        label: String,
        hint: String? = nil,
        @ViewBuilder control: @escaping () -> Control
    ) {
        self.icon = icon
        self.iconTint = iconTint
        self.label = label
        self.hint = hint
        self.control = control
    }

    var body: some View {
        HStack(alignment: .center, spacing: DS.Spacing.md) {
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: DS.Size.iconMedium, weight: .regular))
                    .foregroundStyle(iconTint ?? skin.resolvedTextTertiary)
                    .frame(width: DS.Size.iconLarge)
            }

            VStack(alignment: .leading, spacing: 1) {
                Text(label)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(skin.resolvedTextPrimary)
                    .lineLimit(2)

                if let hint, !hint.isEmpty {
                    Text(hint)
                        .font(.caption)
                        .foregroundStyle(skin.resolvedTextTertiary)
                        .lineLimit(2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            control()
                .layoutPriority(1)
        }
        .padding(.vertical, DS.Spacing.sm)
        .padding(.horizontal, DS.Spacing.contentMargin)
        .contentShape(Rectangle())
    }
}

// MARK: - Convenience factories

extension SettingsRow where Control == SettingsRowValue {
    /// Trailing read-only mono text (e.g. version, status, current value).
    static func value(
        icon: String? = nil,
        iconTint: Color? = nil,
        label: String,
        hint: String? = nil,
        value: String
    ) -> SettingsRow<SettingsRowValue> {
        SettingsRow<SettingsRowValue>(
            icon: icon,
            iconTint: iconTint,
            label: label,
            hint: hint,
            control: { SettingsRowValue(text: value) }
        )
    }
}

extension SettingsRow where Control == SettingsRowDisclosure {
    /// Trailing chevron, signals «tap pushes a sub-view».
    static func disclosure(
        icon: String? = nil,
        iconTint: Color? = nil,
        label: String,
        hint: String? = nil,
        accessory: String? = nil
    ) -> SettingsRow<SettingsRowDisclosure> {
        SettingsRow<SettingsRowDisclosure>(
            icon: icon,
            iconTint: iconTint,
            label: label,
            hint: hint,
            control: { SettingsRowDisclosure(accessory: accessory) }
        )
    }
}

// MARK: - Trailing-content primitives

/// Mono-styled read-only value. Use via `SettingsRow.value(...)`.
struct SettingsRowValue: View {
    let text: String
    @Environment(\.activeSkin) private var skin

    var body: some View {
        Text(text)
            .font(.caption.monospaced())
            .foregroundStyle(skin.resolvedTextSecondary)
    }
}

/// Optional pre-chevron accessory text + chevron. Use via
/// `SettingsRow.disclosure(...)`.
struct SettingsRowDisclosure: View {
    let accessory: String?
    @Environment(\.activeSkin) private var skin

    var body: some View {
        HStack(spacing: DS.Spacing.xs) {
            if let accessory {
                Text(accessory)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(skin.resolvedTextSecondary)
            }
            Image(systemName: "chevron.right")
                .font(.system(size: DS.Size.iconSmall, weight: .semibold))
                .foregroundStyle(skin.resolvedTextTertiary)
        }
    }
}

// MARK: - Preview

#if DEBUG
#Preview("SettingsRow · variants") {
    VStack(spacing: 0) {
        SettingsRow.value(
            icon: "calendar",
            label: "Date",
            hint: "Tue, May 12, 2026 · today",
            value: "14:00 — 15:00"
        )
        Divider().opacity(DS.Opacity.faintBorder)
        SettingsRow.disclosure(
            icon: "repeat",
            label: "Repeat",
            hint: "Weekly on Tue, Thu · ends never"
        )
        Divider().opacity(DS.Opacity.faintBorder)
        SettingsRow(
            icon: "timer",
            iconTint: .orange,
            label: "Pomodoro",
            hint: "Auto · Deep Work · 50 / 10 · 1 round"
        ) {
            Toggle("", isOn: .constant(true))
                .toggleStyle(.switch)
                .labelsHidden()
        }
        Divider().opacity(DS.Opacity.faintBorder)
        SettingsRow.disclosure(
            icon: "paintpalette",
            iconTint: .blue,
            label: "Calendar",
            hint: "Bubo Local · private",
            accessory: "Local"
        )
    }
    .frame(width: 360)
    .padding(.vertical, DS.Spacing.sm)
}
#endif
