import SwiftUI

// MARK: - KbdKey + KbdRow
//
// Mono-styled keycap labels for keyboard shortcuts. Used in:
// - Quick Capture: ⌃⇧⌘␣ topbar reminder, ↩ / ⇧↩ / ⎋ hint row
// - Command palette: foot bar hints + per-row trailing shortcut
// - Backlog composer: ↩ Add / ⇧↩ Details / ⎋ Cancel hint row
// - Settings General: keyboard-shortcut review list
// - Meeting alert: Skip ⎋ pill, ↩ Join
//
// Extracts the inline pattern from `BacklogAddTaskField.kbdHint` so
// every shortcut hint in the app reads with the same rhythm. Two
// pieces: the keycap glyph (`KbdKey`) and the `key + label` row
// (`KbdRow`).

/// Visual size for a keycap. `regular` matches the topbar reminder
/// in Quick Capture (10 pt mono); `small` matches the inline hint
/// rows under composers.
enum KbdKeySize {
    case regular
    case small

    var font: Font {
        switch self {
        case .regular: return .system(size: 10, weight: .semibold, design: .monospaced)
        case .small:   return .system(size: 10, weight: .medium, design: .monospaced)
        }
    }

    var horizontalPadding: CGFloat {
        switch self {
        case .regular: return DS.Spacing.xs + 1   // 5pt
        case .small:   return DS.Spacing.xs       // 4pt
        }
    }

    var verticalPadding: CGFloat {
        switch self {
        case .regular: return 3
        case .small:   return 2
        }
    }

    var cornerRadius: CGFloat {
        switch self {
        case .regular: return DS.Size.microCornerRadius     // 4pt
        case .small:   return DS.Size.microCornerRadius - 1 // 3pt
        }
    }

    var minWidth: CGFloat {
        switch self {
        case .regular: return 12
        case .small:   return 12
        }
    }
}

/// A single keycap glyph (`⌘`, `⇧`, `⎋`, `↩`, `␣`, `A`, …).
struct KbdKey: View {
    let key: String
    let size: KbdKeySize

    @Environment(\.activeSkin) private var skin

    init(_ key: String, size: KbdKeySize = .small) {
        self.key = key
        self.size = size
    }

    var body: some View {
        Text(key)
            .font(size.font)
            .foregroundStyle(skin.resolvedTextSecondary)
            .frame(minWidth: size.minWidth)
            .padding(.horizontal, size.horizontalPadding)
            .padding(.vertical, size.verticalPadding)
            .background(
                RoundedRectangle(cornerRadius: size.cornerRadius, style: .continuous)
                    .fill(skin.resolvedTextPrimary.opacity(DS.Opacity.lightFill - 0.01))
            )
            .overlay(
                RoundedRectangle(cornerRadius: size.cornerRadius, style: .continuous)
                    .strokeBorder(
                        skin.resolvedTextPrimary.opacity(DS.Opacity.faintBorder),
                        lineWidth: 0.5
                    )
            )
            .accessibilityLabel(Self.a11yLabel(for: key))
    }

    /// VoiceOver expansion for the special glyphs that have well-known
    /// names. Falls back to the raw key for letters/digits.
    private static func a11yLabel(for key: String) -> String {
        switch key {
        case "⌘": return "Command"
        case "⇧": return "Shift"
        case "⌃": return "Control"
        case "⌥": return "Option"
        case "⎋": return "Escape"
        case "↩": return "Return"
        case "␣": return "Space"
        case "⏎": return "Return"
        default:  return key
        }
    }
}

/// A `keycap + label` row — e.g. `↩ Add to backlog`. Used in the
/// hint rows under composers and in the command palette foot bar.
struct KbdRow: View {
    let keys: [String]
    let label: String
    let size: KbdKeySize

    @Environment(\.activeSkin) private var skin

    init(_ keys: [String], _ label: String, size: KbdKeySize = .small) {
        self.keys = keys
        self.label = label
        self.size = size
    }

    /// Convenience for the single-key case: `KbdRow("↩", "Add")`.
    init(_ key: String, _ label: String, size: KbdKeySize = .small) {
        self.keys = [key]
        self.label = label
        self.size = size
    }

    var body: some View {
        HStack(spacing: DS.Spacing.xs) {
            HStack(spacing: 3) {
                ForEach(keys, id: \.self) { KbdKey($0, size: size) }
            }
            Text(label)
                .font(.caption.weight(.medium))
                .foregroundStyle(skin.resolvedTextTertiary)
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Preview

#if DEBUG
#Preview("KbdKey / KbdRow") {
    VStack(alignment: .leading, spacing: DS.Spacing.lg) {
        // Quick Capture topbar — chord display
        HStack(spacing: 3) {
            KbdKey("⌃", size: .regular)
            KbdKey("⇧", size: .regular)
            KbdKey("⌘", size: .regular)
            KbdKey("␣", size: .regular)
        }

        // Quick Capture hint row
        HStack(spacing: DS.Spacing.md) {
            KbdRow("↩", "Add to backlog")
            KbdRow(["⇧", "↩"], "Open full editor")
            Spacer()
            KbdRow("⎋", "Cancel")
        }

        // Command palette foot bar
        HStack(spacing: DS.Spacing.md) {
            KbdRow(["↑", "↓"], "Navigate")
            KbdRow("⏎", "Run")
            KbdRow(["⌘", "K"], "Toggle")
        }

        // Settings General — shortcut review
        VStack(alignment: .leading, spacing: DS.Spacing.xs) {
            KbdRow(["⌘", "B"], "Backlog")
            KbdRow(["⌘", "K"], "Command palette")
            KbdRow(["⌃", "⇧", "⌘", "␣"], "Quick Capture")
        }
    }
    .padding()
    .frame(width: 420)
}
#endif
