import SwiftUI

/// Day-scope optimizer entry point — a small `Plan day ▾` menu that lives
/// in the «Today» section header. Replaces the floating chip strip's
/// day-level intents (`Deadlines`, `Low energy`, etc.) with a single
/// scenario-named menu next to the data it would mutate.
///
/// Birman: «иерархия из природы данных, а не из номенклатуры» — the menu
/// is flat. Six canonical scenarios + a `More…` escape hatch to ⌘K for
/// parametric variants. No invented sub-categories («Quick», «Energy»…)
/// because they're our taxonomy, not the user's mental model.
struct PlanDayMenu: View {
    /// Run an `IntentPresets` request through the same async helper that
    /// drives the spill-over marker — toast + undo come for free.
    let runRequest: (OptimizationRequest, _ label: String) async -> Void
    /// Open the command palette filtered to day-scope intents — fired by
    /// the `More…` item. Lets parametric and rare presets stay reachable
    /// without crowding the leaf menu.
    let openMore: () -> Void
    /// True when «today» has neither events nor backlog tasks. The menu
    /// stays visible (Birman: «не делай интерфейс непредсказуемым»),
    /// but disabled with a tooltip explaining what would unlock it.
    let isEmptyDay: Bool

    @Environment(\.activeSkin) private var skin

    var body: some View {
        Menu {
            Button {
                Task { await runRequest(.organizeDay, "Organized today") }
            } label: {
                Label("Organize today", systemImage: "wand.and.stars")
            }

            Button {
                Task { await runRequest(
                    .findFocus(minutes: 120, period: .morning),
                    "Found 2\u{00A0}h focus"
                ) }
            } label: {
                Label("Find 2\u{00A0}h focus", systemImage: "brain.head.profile")
            }

            Button {
                Task { await runRequest(.lowEnergyDay, "Low energy day") }
            } label: {
                Label("Low energy day", systemImage: "leaf")
            }

            Button {
                Task { await runRequest(.pomodoroBlock, "Scheduled pomodoro day") }
            } label: {
                Label("Schedule pomodoro day", systemImage: "timer")
            }

            Button {
                Task { await runRequest(.batchMeetingsPreset, "Batched meetings") }
            } label: {
                Label("Batch meetings", systemImage: "person.2")
            }

            Button {
                Task { await runRequest(.planWeek, "Planned the week") }
            } label: {
                Label("Plan whole week", systemImage: "calendar")
            }

            Divider()

            Button(action: openMore) {
                Label("More\u{2026}", systemImage: "ellipsis.circle")
            }
        } label: {
            HStack(spacing: DS.Spacing.xxs) {
                Text("Plan day")
                Image(systemName: "chevron.down")
                    .font(.caption)
            }
            .font(.footnote.weight(.medium))
            .foregroundStyle(isEmptyDay
                ? skin.resolvedTextTertiary
                : skin.resolvedTextSecondary)
            .padding(.horizontal, DS.Spacing.xs)
            .padding(.vertical, DS.Spacing.xxs)
            .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(isEmptyDay)
        .help(isEmptyDay
            ? "Add events or tasks to plan your day"
            : "Plan today with the optimizer")
    }
}
