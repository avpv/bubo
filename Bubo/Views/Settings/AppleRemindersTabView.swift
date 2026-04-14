import SwiftUI

/// Apple Reminders sync was temporarily disabled after a regression where
/// loading `RemindersSyncService` + its SwiftData-backed backlog prevented
/// the menu bar popover from opening.  This view is left as a stub so the
/// Settings scene still compiles; the real UI will return once the sync
/// service is rewritten to be safe.
struct AppleRemindersTabView: View {
    @Environment(\.activeSkin) private var skin

    var body: some View {
        ScrollView {
            VStack(spacing: DS.Spacing.lg) {
                SettingsPlatter("Apple Reminders") {
                    Text("Apple Reminders integration is being reworked and is temporarily unavailable.")
                        .font(.callout)
                        .foregroundStyle(skin.resolvedTextSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(DS.Spacing.xl)
        }
    }
}
