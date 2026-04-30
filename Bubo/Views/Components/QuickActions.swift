import SwiftUI

// MARK: - Quick Actions
//
// Single primary chip — opens the ⌘K command palette. Per-task,
// per-event, backlog and day-scope optimizer entry points live next to
// their data now (row context menu, EventDetailView Edit ▾ menu,
// SpillOverMarker action-links, Plan day ▾ menu). The ranker is still
// used by SmartBanner for contextual suggestion suppression — but the
// ranked candidates no longer surface as floating chips above the
// timeline. Birman: «не плодь сущности на главном экране», и каждое
// действие живёт рядом со своим объектом.

struct QuickActions: View {
    @Environment(\.activeSkin) private var skin

    var optimizerService: OptimizerService
    var reminderService: ReminderService
    var onExecuted: (_ label: String, _ undo: @escaping () -> Void) -> Void
    var onError: (_ message: String) -> Void = { _ in }
    var onOpenPalette: () -> Void

    var body: some View {
        // The single Optimize chip — gateway to the command palette for
        // free-text intents, parametric variants and rare presets. Solid
        // accent fill marks it as the row's primary action.
        Button {
            Haptics.tap()
            onOpenPalette()
        } label: {
            HStack(spacing: DS.Spacing.xs) {
                Image(systemName: "sparkles")
                    .font(.footnote.weight(.semibold))
                    .frame(width: DS.Size.iconSmall, height: DS.Size.iconSmall)
                Text("Optimize")
                    .font(.footnote.weight(.medium))
                    .lineLimit(1)
                Text("⌘K")
                    .font(.footnote.monospaced())
                    .foregroundStyle(primaryForeground.opacity(DS.Opacity.accentMuted))
            }
            .fixedSize()
            .foregroundStyle(primaryForeground)
            .padding(.horizontal, DS.Spacing.sm)
            .padding(.vertical, DS.Spacing.pillVertical)
            .background(
                Capsule().fill(skin.accentColor)
            )
            .overlay(
                Capsule().strokeBorder(
                    Color.white.opacity(0.25),
                    lineWidth: DS.Border.thin
                )
            )
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help("AI optimizer (\u{2318}K)")
    }

    /// Foreground used on top of the solid accent fill — picks black or
    /// white depending on the accent colour's luminance so contrast never
    /// breaks on light accents.
    private var primaryForeground: Color {
        DS.contrastingForeground(for: skin.accentColor)
    }
}
