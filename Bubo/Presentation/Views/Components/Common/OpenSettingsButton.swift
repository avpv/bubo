import SwiftUI

// MARK: - Settings Button

struct OpenSettingsButton: View {
    var iconOnly: Bool = false
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Button {
            Haptics.tap()
            NSApp.keyWindow?.close()
            openSettings()
            NSApp.activate()
        } label: {
            if iconOnly {
                Image(systemName: "gear")
                    .accessibilityLabel("Settings")
            } else {
                // Trailing ellipsis: the action opens another window
                // (HIG buttons: append an ellipsis when a button opens
                // another window, view, or app).
                Label("Settings\u{2026}", systemImage: "gear")
            }
        }
    }
}
