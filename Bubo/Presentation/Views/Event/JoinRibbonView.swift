import SwiftUI
import BuboDomain

// MARK: - Post-Join Ribbon (J1)
//
// Tiny floating ribbon shown after the user taps «Join …» in the
// full-screen meeting alert. It carries a live countdown to the
// event start, the meeting service name, and one explicit
// «Re-alert» action that re-pops the full-screen reminder if the
// user got distracted before the call actually opened. Auto-dismisses
// at `event.startDate`.
//
// Birman: «don't multiply modalities». The full-screen alert is the
// dominant; the ribbon is a quiet acknowledgment, not a second
// dominant — single subdued band, three short labels, two icons.

struct JoinRibbonView: View {
    @Environment(\.activeSkin) private var skin

    let event: CalendarEvent
    let onReAlert: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let secondsRemaining = max(Int(event.startDate.timeIntervalSince(context.date)), 0)
            HStack(spacing: DS.Spacing.md) {
                Image(systemName: "checkmark.circle.fill")
                    .font(DS.Typography.body(skin: skin))
                    .foregroundStyle(skin.resolvedSuccessColor)

                VStack(alignment: .leading, spacing: 1) {
                    Text("Joined \u{00B7} \(event.title)")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(skin.resolvedTextPrimary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Text(countdownText(secondsRemaining))
                        .font(DS.Typography.machineHint)
                        .foregroundStyle(skin.resolvedTextSecondary)
                        .contentTransition(.numericText())
                }

                Spacer(minLength: DS.Spacing.md)

                Button {
                    Haptics.tap()
                    onReAlert()
                } label: {
                    Text("Re-alert")
                        .font(.footnote.weight(.regular))
                        .foregroundStyle(skin.accentColor)
                        .padding(.horizontal, DS.Spacing.md)
                        .padding(.vertical, DS.Spacing.xxs)
                        .background(
                            Capsule().fill(skin.accentColor.opacity(DS.Opacity.lightFill))
                        )
                }
                .buttonStyle(.plain)
                .help("Bring the full-screen reminder back if Zoom hasn't opened yet")
                .accessibilityLabel("Re-show full-screen alert")

                Button {
                    Haptics.tap()
                    onDismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(skin.resolvedTextTertiary)
                        .frame(width: DS.Size.controlHeight, height: DS.Size.controlHeight)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Dismiss ribbon")
            }
            .padding(.horizontal, DS.Spacing.lg)
            .frame(height: 36)
            .frame(minWidth: 360)
        }
    }

    private func countdownText(_ secondsRemaining: Int) -> String {
        if secondsRemaining <= 0 { return "Starts now" }
        let minutes = secondsRemaining / 60
        let seconds = secondsRemaining % 60
        if minutes >= 60 {
            let hours = minutes / 60
            let mins = minutes % 60
            return String(format: "Starts in %d:%02d:%02d", hours, mins, seconds)
        }
        return String(format: "Starts in %d:%02d", minutes, seconds)
    }
}
