import SwiftUI
import AppKit

// MARK: - Permission banners
//
// Actionable per-service banners for the popover's status slot: when a
// sync source is enabled in Settings but macOS access is missing, the
// banner names the broken service and clicking it deep-links straight
// to the matching Settings pane. One banner renders as a bare pill;
// two render as a horizontal pager with a quiet dot indicator, so the
// secondary message lives in the same vertical slot as the primary one
// rather than stacking and pushing the day list down.

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

/// Hosts one or more permission banners. A single spec renders the bare
/// pill; two or more render as a paged horizontal scroll with a quiet
/// dot indicator beneath.
struct PermissionBannersCarousel: View {
    let specs: [PermissionBannerSpec]

    @State private var currentID: String?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if specs.count == 1, let only = specs.first {
                PermissionBannerRow(spec: only)
            } else {
                VStack(spacing: DS.Spacing.xs) {
                    ScrollView(.horizontal) {
                        HStack(spacing: 0) {
                            ForEach(specs) { spec in
                                PermissionBannerRow(spec: spec)
                                    .containerRelativeFrame(.horizontal)
                                    .id(spec.id)
                            }
                        }
                        .scrollTargetLayout()
                    }
                    .scrollTargetBehavior(.paging)
                    .scrollIndicators(.hidden)
                    .scrollPosition(id: $currentID)

                    PermissionBannerPageDots(
                        count: specs.count,
                        activeIndex: activeIndex
                    )
                }
                .onAppear {
                    if currentID == nil { currentID = specs.first?.id }
                }
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Permissions required. Swipe to switch between \(specs.count) banners.")
            }
        }
        .padding(.vertical, DS.Spacing.xs)
        .transition(
            reduceMotion
                ? .opacity
                : .move(edge: .top).combined(with: .opacity)
        )
    }

    private var activeIndex: Int {
        guard let id = currentID,
              let i = specs.firstIndex(where: { $0.id == id })
        else { return 0 }
        return i
    }
}

/// Page indicator. Deliberately tiny and quiet — the dots inform, the
/// pill is the figure. Filled = active, hairline-faint = inactive.
struct PermissionBannerPageDots: View {
    let count: Int
    let activeIndex: Int

    @Environment(\.activeSkin) private var skin

    var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<count, id: \.self) { i in
                Circle()
                    .fill(
                        i == activeIndex
                            ? skin.resolvedTextSecondary
                            : skin.resolvedTextTertiary.opacity(DS.Opacity.tertiaryText)
                    )
                    .frame(width: 5, height: 5)
                    .animation(DS.Animation.quick, value: activeIndex)
            }
        }
        .accessibilityHidden(true)
    }
}
