import SwiftUI

// MARK: - Working Days Picker

/// Seven-chip checkbox row for selecting which weekdays the planner
/// is allowed to place movable events on. Each chip toggles one
/// weekday in/out of the bound `Set<Int>` that uses Foundation's
/// 1-indexed weekday convention (1 = Sunday, 2 = Monday, …,
/// 7 = Saturday).
///
/// The row is laid out Monday-first to match the user's mental "work
/// week starts Mon" model even on locales where `Calendar.current`
/// reports Sunday as `firstWeekday`. The internal order is fixed;
/// weekday-to-index mapping stays Foundation-native so bindings
/// round-trip unchanged through `OptimizerPreferences.workingDays`.
///
/// At least one day must remain selected — the last click on a
/// solo-checked chip is a no-op rather than a flip-to-empty. Empty
/// would read as "no working days" at the constraint layer, which
/// makes every placement infeasible and is almost never what the
/// user wants.
struct WorkingDaysPicker: View {
    @Binding var selection: Set<Int>

    @Environment(\.activeSkin) private var skin

    /// (weekday index in Foundation's 1…7, short label). Mon…Sun
    /// display order with Sat/Sun at the end matches the screenshot
    /// the product asked for.
    private static let days: [(weekday: Int, label: String)] = [
        (2, "Mon"),
        (3, "Tue"),
        (4, "Wed"),
        (5, "Thu"),
        (6, "Fri"),
        (7, "Sat"),
        (1, "Sun")
    ]

    var body: some View {
        HStack(spacing: DS.Spacing.xs) {
            ForEach(Self.days, id: \.weekday) { day in
                chip(for: day.weekday, label: day.label)
            }
        }
    }

    @ViewBuilder
    private func chip(for weekday: Int, label: String) -> some View {
        let isOn = selection.contains(weekday)

        Button {
            toggle(weekday)
        } label: {
            Text(label)
                .font(.caption.weight(isOn ? .semibold : .regular))
                .foregroundStyle(
                    isOn
                        ? skin.resolvedTextPrimary
                        : skin.resolvedTextSecondary
                )
                .padding(.vertical, 6)
                .padding(.horizontal, 10)
                .background(
                    Capsule()
                        .fill(
                            isOn
                                ? skin.accentColor.opacity(0.22)
                                : skin.resolvedTextTertiary.opacity(0.10)
                        )
                )
                .overlay(
                    Capsule()
                        .stroke(
                            isOn
                                ? skin.accentColor.opacity(0.55)
                                : skin.resolvedTextTertiary.opacity(0.25),
                            lineWidth: 1
                        )
                )
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityAddTraits(isOn ? [.isSelected] : [])
    }

    private func toggle(_ weekday: Int) {
        if selection.contains(weekday) {
            // Refuse to drop to zero: at least one day must stay
            // checked so the planner has somewhere to place tasks.
            guard selection.count > 1 else { return }
            selection.remove(weekday)
        } else {
            selection.insert(weekday)
        }
    }
}
