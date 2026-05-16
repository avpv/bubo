import SwiftUI

/// «Nothing scheduled» panel for the popover. Two layouts share one
/// view: a compact one-row hint when tasks already pin above (so tasks
/// keep dominating), and a full-screen «All clear» Apple-style empty
/// state when there's nothing at all.
///
/// Apple philosophy «deference»: emptiness is information too — show it
/// with a hero SF symbol, a single title line, a quiet description, and
/// **one** primary action. macOS 14's `ContentUnavailableView` is the
/// native composition for this — symbol top-centred, title beneath,
/// description quiet, action in a system button. We use it directly so
/// the empty state feels like Files.app's "No tags" screen rather than
/// a hand-rolled card.
struct EmptyState: View {
    let pendingTaskCount: Int
    let subtitle: String
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

    /// macOS 14+ native empty-state composition. Symbol + title +
    /// description + primary action all in one system primitive — same
    /// vocabulary as Finder, Files, Music, Notes.
    @ViewBuilder
    private var fullCard: some View {
        ContentUnavailableView {
            Label("All clear", systemImage: "calendar")
        } description: {
            Text(subtitle)
        } actions: {
            Button {
                Haptics.tap()
                onAddEvent()
            } label: {
                Label("Add Event", systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
            .tint(skin.accentColor)
            .controlSize(.regular)

            if showCalendarSettingsLink {
                Button {
                    Haptics.tap()
                    onAdjustCalendars()
                } label: {
                    Text("Adjust which calendars are visible")
                }
                .buttonStyle(.plain)
                .foregroundStyle(skin.resolvedTextTertiary)
                .accessibilityLabel("Open Calendar Settings to pick which calendars are visible")
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, DS.Spacing.xxl)
    }
}
