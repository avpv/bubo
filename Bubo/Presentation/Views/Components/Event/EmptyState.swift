import SwiftUI

/// «Nothing scheduled» panel for the popover. Two layouts share one
/// view: a compact one-row hint when tasks already pin above (so tasks
/// keep dominating), and a full-screen «All clear» card when there's
/// nothing at all.
///
/// Birman: emptiness is information too — show it quietly. No pulsing
/// icon, no radial glow, no ceremony.
struct EmptyState: View {
    /// Number of pending tasks pinned above the empty calendar.
    /// Drives the compact-vs-full layout switch.
    let pendingTaskCount: Int
    /// «Through Sunday», «No more events today», etc — same string
    /// used in both layouts.
    let subtitle: String
    /// When true, surface the quiet «Adjust which calendars are visible»
    /// escape hatch. Host gates this on (calendarHasAccess && isCalendarSyncEnabled)
    /// so we never offer a settings link the user can't act on.
    let showCalendarSettingsLink: Bool
    let onAddEvent: () -> Void
    let onAdjustCalendars: () -> Void

    @Environment(\.activeSkin) private var skin

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                if pendingTaskCount > 0 {
                    compactRow
                } else {
                    fullCard
                }
            }
        }
        .scrollContentBackground(.hidden)
        .transition(.opacity.combined(with: .scale(scale: 0.95)))
    }

    private var compactRow: some View {
        HStack(spacing: DS.Spacing.sm) {
            Image(systemName: "calendar")
                .font(.footnote)
                .foregroundStyle(skin.resolvedTextTertiary)
            Text(subtitle)
                .font(.footnote)
                .foregroundStyle(skin.resolvedTextTertiary)
            Spacer()
            Button {
                Haptics.tap()
                onAddEvent()
            } label: {
                Text("Add Event")
                    .font(.footnote.weight(.regular))
            }
            .buttonStyle(.plain)
            .foregroundStyle(skin.accentColor)
        }
        .padding(.horizontal, DS.Spacing.lg)
        .padding(.vertical, DS.Spacing.lg)
    }

    private var fullCard: some View {
        VStack(spacing: DS.Spacing.sm) {
            Text("All clear")
                .font(DS.Typography.headline(skin: skin))
                .foregroundStyle(skin.resolvedTextPrimary)
            Text(subtitle)
                .font(.subheadline)
                .foregroundStyle(skin.resolvedTextSecondary)
                .lineLimit(1)
                .truncationMode(.tail)

            Button {
                Haptics.tap()
                onAddEvent()
            } label: {
                Label("Add Event", systemImage: "plus")
                    .font(.footnote)
                    .fontWeight(.regular)
            }
            .buttonStyle(.action(role: .primary, size: .compact))
            .padding(.top, DS.Spacing.md)

            if showCalendarSettingsLink {
                Button {
                    Haptics.tap()
                    onAdjustCalendars()
                } label: {
                    Text("Adjust which calendars are visible \u{2192}")
                        .font(.footnote)
                        .foregroundStyle(skin.resolvedTextTertiary)
                }
                .buttonStyle(.plain)
                .padding(.top, DS.Spacing.sm)
                .accessibilityLabel("Open Calendar Settings to pick which calendars are visible")
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, DS.Spacing.xxl)
    }
}
