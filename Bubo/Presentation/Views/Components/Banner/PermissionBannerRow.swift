import SwiftUI
import AppKit

// MARK: - Permission banners
//
// Actionable per-service banners for the popover's status slot: when a
// sync source is enabled in Settings but macOS access is missing, the
// banner names the broken service and clicking it deep-links straight
// to the matching Settings pane. Restores the behaviour of the old
// `PermissionBannersCarousel` without the pager chrome — when both
// services are broken the two rows simply stack (two slim rows cost
// less than a swipe-to-discover carousel).

struct PermissionBannerSpec: Identifiable, Equatable {
    let id: String
    let icon: String
    let title: LocalizedStringKey
    let accessibilityLabel: String
    let pane: SettingsView.SettingsPane

    static let calendar = PermissionBannerSpec(
        id: "calendar",
        icon: "calendar.badge.exclamationmark",
        title: "Calendar access not granted",
        accessibilityLabel: "Calendar access not granted. Open settings to grant access.",
        pane: .calendars
    )

    static let reminders = PermissionBannerSpec(
        id: "reminders",
        icon: "checklist",
        title: "Reminders access not granted",
        accessibilityLabel: "Reminders access not granted. Open settings to grant access.",
        pane: .appleReminders
    )
}

/// One slim, clickable banner row. Same capsule voice as `StatusBanner`,
/// plus a trailing chevron because — unlike the informational banners —
/// this one *goes somewhere*: it opens Settings on the pane that fixes
/// the named problem.
struct PermissionBannerRow: View {
    let spec: PermissionBannerSpec

    @Environment(\.openSettings) private var openSettings
    @Environment(\.activeSkin) private var skin

    var body: some View {
        Button {
            Haptics.tap()
            NSApp.keyWindow?.close()
            SettingsViewModel.pendingPane = spec.pane
            openSettings()
            NSApp.activate()
            NotificationCenter.default.post(
                name: SettingsViewModel.navigateToPaneNotification,
                object: spec.pane
            )
        } label: {
            HStack(spacing: DS.Spacing.sm) {
                Image(systemName: spec.icon)
                    .foregroundStyle(skin.resolvedWarningColor)
                    .font(.footnote)
                    .symbolRenderingMode(.hierarchical)
                Text(spec.title)
                    .font(.footnote)
                    .foregroundStyle(skin.resolvedTextPrimary)
                Spacer(minLength: DS.Spacing.sm)
                Image(systemName: "chevron.right")
                    .font(.footnote)
                    .foregroundStyle(skin.resolvedTextTertiary)
            }
            .padding(.horizontal, DS.Spacing.md)
            .padding(.vertical, DS.Spacing.sm)
            .adaptiveBadgeFill(skin.resolvedWarningColor)
            .clipShape(Capsule())
            // Permission pill rides on the card plane (z1) inside the popover.
            .elevation(.z1, skin: skin)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help("Open Settings → \(spec.pane.rawValue)")
        // Level 1: unified outer content margin so the pill hangs on the
        // same vertical axis as the rest of the popover chrome.
        .padding(.horizontal, DS.Spacing.contentMargin)
        .accessibilityLabel(spec.accessibilityLabel)
    }
}
