import SwiftUI

/// Horizontal row of one-tap optimizer presets that lives on the main
/// screen above the timeline. Each chip fires a canonical
/// `OptimizationRequest` through the same `runQuickAction` pipe the
/// SmartActions row uses — toast + undo come for free.
///
/// Birman: «прямое действие на месте проблемы». The user reads the
/// timeline and immediately has «Find focus», «Pomodoro day», «Organize
/// today», «Plan week» one tap away — no need to dive into the backlog
/// card or the command palette to ask the optimizer for help.
///
/// The legacy `QuickActions` card was absorbed into `SmartActions`
/// when the inline backlog was the dominant surface; with the inline
/// backlog reduced to a status panel, optimizer entry points need
/// their own place again — that place is here.
struct QuickActionsRow: View {

    /// Run an arbitrary `OptimizationRequest` through the host's quick-
    /// action pipe (toast + undo). Same closure shape `BacklogView`
    /// uses for its `onRunRequest`.
    let onRunRequest: (OptimizationRequest, String) async -> Void

    @Environment(\.activeSkin) private var skin

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: DS.Spacing.xs) {
                preset(
                    icon: "brain.head.profile",
                    label: "Find focus",
                    successLabel: "Found 2\u{00A0}h focus",
                    request: .findFocus(minutes: 120, period: .morning)
                )
                preset(
                    icon: "timer",
                    label: "Pomodoro",
                    successLabel: "Scheduled pomodoro day",
                    request: .pomodoroBlock
                )
                preset(
                    icon: "wand.and.stars",
                    label: "Organize",
                    successLabel: "Organized today",
                    request: .organizeDay
                )
                preset(
                    icon: "calendar",
                    label: "Plan week",
                    successLabel: "Planned the week",
                    request: .planWeek
                )
            }
            .padding(.horizontal, DS.Spacing.contentMargin)
            .padding(.vertical, DS.Spacing.xs)
        }
    }

    @ViewBuilder
    private func preset(
        icon: String,
        label: String,
        successLabel: String,
        request: OptimizationRequest
    ) -> some View {
        Button {
            Haptics.tap()
            Task { await onRunRequest(request, successLabel) }
        } label: {
            HStack(spacing: DS.Spacing.xxs) {
                Image(systemName: icon)
                    .font(.footnote)
                Text(label)
                    .font(.footnote.weight(.medium))
            }
            .foregroundStyle(skin.accentColor)
            .padding(.horizontal, DS.Spacing.sm)
            .padding(.vertical, DS.Spacing.xs)
            .background(
                Capsule().fill(skin.accentColor.opacity(DS.Opacity.lightFill))
            )
            .overlay(
                Capsule().strokeBorder(
                    skin.accentColor.opacity(DS.Opacity.softAccent),
                    lineWidth: DS.Border.thin
                )
            )
        }
        .buttonStyle(.plain)
        .help("Run «\(label)» — optimizer finds the best slot")
        .accessibilityLabel("\(label) — runs the optimizer")
    }
}
