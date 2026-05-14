import SwiftUI

// MARK: - WhenChip
//
// The «when is this scheduled?» pill. Used in the Backlog task row
// (right-trailing chip on scheduled tasks), free-slot rows, and any
// other surface that needs to point at a future moment with one
// glance.
//
// Extracted from `BacklogTaskRow+Subviews.scheduledWhenChip`
// (`:564–586`). Identical visual rhythm, but now reusable: a
// scheduled-task chip in the Today timeline, a «next slot» readout
// in the slot picker, and the time-on-card in the scenario picker
// all share one source of truth.
//
// The chip's tint is calendar-driven when a `tint` is supplied
// (matches the row's calendar-colour stripe); falls back to skin
// accent. `PRINCIPLES.md §7`: colour carries meaning (which
// calendar lane), not decoration.

/// Compact pill labelling a scheduled date/time.
///
/// Label formats (locale-aware via `setLocalizedDateFormatFromTemplate`):
/// - `Today HH:mm`     — when `Calendar.current.isDateInToday(date)`
/// - `Tomorrow HH:mm`  — when `isDateInTomorrow`
/// - `EEE HH:mm`       — abbreviated weekday otherwise
///
/// Pass a `tint` to drive the calendar-colour theming
/// (`EventColorTag.color`); leave `nil` to inherit the skin accent.
struct WhenChip: View {
    let date: Date
    let tint: Color?
    let icon: String

    @Environment(\.activeSkin) private var skin

    init(date: Date, tint: Color? = nil, icon: String = "calendar") {
        self.date = date
        self.tint = tint
        self.icon = icon
    }

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: icon)
                .font(.caption2.weight(.semibold))
            Text(Self.label(for: date))
                .font(.caption2.weight(.semibold))
                .monospacedDigit()
        }
        .foregroundStyle(effectiveTint)
        .padding(.horizontal, DS.Spacing.xs)
        .padding(.vertical, DS.Spacing.xxs)
        .background(
            RoundedRectangle(cornerRadius: DS.Size.microCornerRadius, style: .continuous)
                .fill(effectiveTint.opacity(DS.Opacity.lightFill))
        )
        .accessibilityLabel("Scheduled \(Self.label(for: date))")
    }

    private var effectiveTint: Color { tint ?? skin.accentColor }

    /// Compact «day + time» label. NB-space `\u{00A0}` between day
    /// and time prevents awkward line breaks when the chip is
    /// rendered inline with other tokens (`PRINCIPLES.md §3`).
    static func label(for date: Date) -> String {
        let cal = Calendar.current
        let timeFmt = DateFormatter()
        timeFmt.setLocalizedDateFormatFromTemplate("Hmm")
        let timeStr = timeFmt.string(from: date)
        if cal.isDateInToday(date) { return "Today\u{00A0}\(timeStr)" }
        if cal.isDateInTomorrow(date) { return "Tomorrow\u{00A0}\(timeStr)" }
        let dayFmt = DateFormatter()
        dayFmt.setLocalizedDateFormatFromTemplate("EEE")
        return "\(dayFmt.string(from: date))\u{00A0}\(timeStr)"
    }
}

// MARK: - Preview

#if DEBUG
#Preview("WhenChip · variants") {
    let now = Date()
    let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: now)!
    let nextWeek = Calendar.current.date(byAdding: .day, value: 5, to: now)!
    return VStack(alignment: .leading, spacing: DS.Spacing.sm) {
        HStack(spacing: DS.Spacing.sm) {
            WhenChip(date: now)
            WhenChip(date: tomorrow)
            WhenChip(date: nextWeek)
        }
        HStack(spacing: DS.Spacing.sm) {
            WhenChip(date: now, tint: .blue)
            WhenChip(date: tomorrow, tint: .orange)
            WhenChip(date: nextWeek, tint: .green)
        }
        HStack(spacing: DS.Spacing.sm) {
            WhenChip(date: now, icon: "clock")
            WhenChip(date: tomorrow, tint: .purple, icon: "bolt.fill")
        }
    }
    .padding()
    .frame(width: 360)
}
#endif
