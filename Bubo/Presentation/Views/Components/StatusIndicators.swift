import SwiftUI

/// Tiny pair of status glyphs that ride in the popover header's trailing
/// area: a pulsing wifi-slash when offline, a mini spinner while reminders
/// sync. Both glyphs hide themselves when their condition is false; the
/// host doesn't need to gate visibility.
///
/// Kept as a separate view so the menu-bar header stays declarative —
/// the host hands over the two `@Observable` services and the view
/// observes them itself.
struct StatusIndicators: View {
    let networkMonitor: NetworkMonitor
    let reminderService: ReminderService
    @Environment(\.activeSkin) private var skin

    var body: some View {
        HStack(spacing: DS.Spacing.sm) {
            if !networkMonitor.isConnected {
                Image(systemName: "wifi.slash")
                    .foregroundStyle(skin.resolvedDestructiveColor)
                    .font(.system(size: DS.Size.iconSmall))
                    .symbolEffect(.pulse, options: .repeating.speed(0.5))
                    .help("No internet connection")
                    .accessibilityLabel("No internet connection")
                    .transition(.scale.combined(with: .opacity))
            }

            if reminderService.isSyncing {
                ProgressView()
                    .controlSize(.mini)
                    .frame(width: DS.Size.syncIndicatorSize, height: DS.Size.syncIndicatorSize)
                    .transition(.scale.combined(with: .opacity))
            }
        }
        .animation(skin.resolvedMicroAnimation, value: networkMonitor.isConnected)
        .animation(skin.resolvedMicroAnimation, value: reminderService.isSyncing)
    }
}
