import SwiftUI
import BuboDomain

/// Apple Reminders' Today / Scheduled / Flagged cards adapted to Bubo's
/// tighter menu-bar geometry: one horizontal row of chips with leading
/// icon + label + trailing count badge. "All" is the nil state — selecting
/// it (or re-tapping the active chip) clears the filter. Hidden when the
/// active backlog is empty — nothing to navigate, no need to show a row of
/// zeros.
///
/// Birman: don't show zero. Chips with count 0 are hidden unless they're
/// the currently-selected filter, in which case the user needs them
/// visible to clear back to «All».
struct BacklogSmartFilterRow: View {
    let activeTasksCount: Int
    let counts: [BacklogLogic.SmartFilter: Int]
    @Binding var smartFilter: BacklogLogic.SmartFilter?

    @Environment(\.activeSkin) private var skin
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// At least one non-«All» chip would render — either a filter has a
    /// non-zero count, or a filter is engaged (and must stay visible so the
    /// user can clear it). A row whose only resident is «All N» offers no
    /// choice; hide it and save the band.
    private var hasFilterableContent: Bool {
        smartFilter != nil || counts.values.contains { $0 > 0 }
    }

    var body: some View {
        if activeTasksCount > 0 && hasFilterableContent {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: DS.Spacing.xs) {
                    chip(filter: nil, count: activeTasksCount)
                    ForEach(BacklogLogic.SmartFilter.allCases, id: \.self) { filter in
                        let count = counts[filter] ?? 0
                        if count > 0 || smartFilter == filter {
                            chip(filter: filter, count: count)
                        }
                    }
                }
                // Host provides the screen's contentMargin — chips hang
                // on the same 16 pt axis as every other band.
                .padding(.vertical, DS.Spacing.xxs)
            }
        }
    }

    @ViewBuilder
    private func chip(
        filter: BacklogLogic.SmartFilter?,
        count: Int
    ) -> some View {
        let isOn = smartFilter == filter
        let label = filter?.label ?? "All"
        let icon = filter?.systemImage ?? "tray.full"
        Button {
            Haptics.tap()
            withAnimation(DS.Animation.motionAware(DS.Animation.quick, reduceMotion: reduceMotion)) {
                // Tap the active chip to clear back to "All"; tap "All"
                // when already on "All" is a no-op (no surprise toggle).
                if isOn {
                    smartFilter = nil
                } else {
                    smartFilter = filter
                }
            }
        } label: {
            HStack(spacing: DS.Spacing.xxs) {
                Image(systemName: icon)
                    .font(.footnote)
                Text(label)
                    .font(.footnote.weight(isOn ? .semibold : .regular))
                Text("\(count)")
                    .font(.footnote.monospacedDigit())
                    .foregroundStyle(skin.resolvedTextTertiary)
            }
            .foregroundStyle(isOn ? skin.accentColor : skin.resolvedTextSecondary)
            .padding(.horizontal, DS.Spacing.sm)
            .padding(.vertical, DS.Spacing.xxs)
            .background(
                Capsule().fill(skin.accentColor.opacity(isOn ? DS.Opacity.lightFill : 0))
            )
            .overlay(
                Capsule().strokeBorder(
                    skin.accentColor.opacity(isOn ? DS.Opacity.softAccent : DS.Opacity.borderIdle),
                    lineWidth: DS.Border.thin
                )
            )
        }
        .buttonStyle(.plain)
        .help(
            isOn
                ? "Showing only \(label.lowercased()) — tap to clear"
                : (filter == nil
                    ? "Show all active tasks"
                    : "Filter to \(label.lowercased()) tasks")
        )
    }
}
