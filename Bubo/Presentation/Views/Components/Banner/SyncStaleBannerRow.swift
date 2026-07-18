import SwiftUI

// MARK: - Sync stale banner

/// Actionable banner for the popover's status slot: the sync pipeline
/// has silently stopped refreshing (watchdog detected a stale
/// `lastSyncDate` and its self-heal retry could not clear it). Unlike
/// the informational `StatusBanner`, this one *does something* — a
/// click retries the sync — so it wears the same interactive capsule
/// voice as `PermissionBannerRow` (§5: only actions dress like
/// buttons), with a retry glyph in the trailing slot instead of a
/// navigation chevron.
struct SyncStaleBannerRow: View {
    /// Last successful refresh — named in the banner so the user sees
    /// *when* sync died, not just that it did.
    let lastSync: Date?
    let onRetry: () -> Void

    @Environment(\.activeSkin) private var skin
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f
    }()

    private var title: String {
        if let lastSync {
            let rel = Self.relativeFormatter.localizedString(for: lastSync, relativeTo: Date())
            return "Calendar not refreshed since \(rel)"
        }
        return "Calendar not refreshed yet"
    }

    var body: some View {
        Button {
            Haptics.tap()
            onRetry()
        } label: {
            HStack(spacing: DS.Spacing.sm) {
                Image(systemName: "exclamationmark.arrow.circlepath")
                    .foregroundStyle(skin.resolvedWarningColor)
                    .font(.footnote)
                    .symbolRenderingMode(.hierarchical)
                Text(title)
                    .font(.footnote)
                    .foregroundStyle(skin.resolvedTextPrimary)
                Spacer(minLength: DS.Spacing.sm)
                Image(systemName: "arrow.clockwise")
                    .font(.footnote)
                    .foregroundStyle(skin.resolvedTextTertiary)
            }
            .padding(.horizontal, DS.Spacing.md)
            .padding(.vertical, DS.Spacing.sm)
            .adaptiveBadgeFill(skin.resolvedWarningColor)
            .clipShape(Capsule())
            .elevation(.z1, skin: skin)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help("Sync now")
        // Level 1: unified outer content margin so the pill hangs on the
        // same vertical axis as the rest of the popover chrome.
        .padding(.horizontal, DS.Spacing.contentMargin)
        .padding(.vertical, DS.Spacing.xs)
        .accessibilityLabel("\(title). Sync now.")
        .transition(
            reduceMotion
                ? .opacity
                : .move(edge: .top).combined(with: .opacity)
        )
    }
}
