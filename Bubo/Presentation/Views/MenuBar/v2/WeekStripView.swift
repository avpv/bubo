import SwiftUI
import BuboDomain

/// Seven-day navigation strip rendered as initialed density bars.
/// Doubles as the popover's day-navigation control: tapping a day
/// scrolls the timeline to that section. Replaces the older
/// `← Today →` cluster + `TODAY` / `TOMORROW` section labels — the
/// strip itself answers «which day am I on?» and lets users jump.
///
/// Density (0…1) is derived per-day from booked minutes inside the
/// user's working-hours window. Renders an empty bar for days with
/// no events so the strip's rhythm stays predictable.
struct WeekStripView: View {

    let dates: [Date]
    let focused: Date?
    /// 0…1 booked fraction inside working hours, keyed by `startOfDay`.
    let densityFor: (Date) -> Double
    let onSelect: (Date) -> Void

    @Environment(\.activeSkin) private var skin

    private let cal = Calendar.current

    var body: some View {
        HStack(spacing: 6) {
            ForEach(dates, id: \.self) { date in
                dayCell(date)
            }
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private func dayCell(_ date: Date) -> some View {
        let isFocused = focused.map { cal.isDate($0, inSameDayAs: date) } ?? false
        let isToday = cal.isDateInToday(date)
        let density = max(0, min(1, densityFor(date)))

        Button {
            Haptics.tap()
            onSelect(date)
        } label: {
            VStack(spacing: 3) {
                Text(weekdayInitial(date))
                    .font(.system(size: 9, weight: .semibold, design: skin.resolvedFontDesign))
                    .foregroundStyle(isFocused
                        ? skin.accentColor
                        : (isToday ? skin.resolvedTextPrimary : skin.resolvedTextTertiary))
                    .tracking(0.4)
                ZStack(alignment: .bottom) {
                    Capsule(style: .continuous)
                        .fill(skin.resolvedTextPrimary.opacity(0.08))
                        .frame(width: 4, height: 14)
                    Capsule(style: .continuous)
                        .fill(barColor(isFocused: isFocused, isToday: isToday))
                        .frame(width: 4, height: max(2, 14 * CGFloat(density)))
                }
                .frame(height: 14)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(helpText(for: date, density: density))
        .accessibilityLabel(accessibilityLabel(for: date, density: density))
    }

    private func weekdayInitial(_ date: Date) -> String {
        let fmt = DateFormatter()
        fmt.locale = Locale.current
        fmt.setLocalizedDateFormatFromTemplate("EEEEE") // narrow, locale-aware
        return fmt.string(from: date).uppercased()
    }

    private func barColor(isFocused: Bool, isToday: Bool) -> Color {
        if isFocused { return skin.accentColor }
        if isToday   { return skin.resolvedTextPrimary.opacity(0.55) }
        return skin.resolvedTextPrimary.opacity(0.35)
    }

    private func helpText(for date: Date, density: Double) -> String {
        let fmt = DateFormatter()
        fmt.setLocalizedDateFormatFromTemplate("EEEE d MMM")
        let pct = Int((density * 100).rounded())
        return "\(fmt.string(from: date)) · \(pct)% booked"
    }

    private func accessibilityLabel(for date: Date, density: Double) -> String {
        let fmt = DateFormatter()
        fmt.setLocalizedDateFormatFromTemplate("EEEE d MMMM")
        let pct = Int((density * 100).rounded())
        return "\(fmt.string(from: date)), \(pct) percent booked"
    }
}

#if DEBUG
#Preview {
    let cal = Calendar.current
    let today = cal.startOfDay(for: Date())
    let dates = (0..<7).compactMap { cal.date(byAdding: .day, value: $0, to: today) }
    return WeekStripView(
        dates: dates,
        focused: today,
        densityFor: { d in
            let offset = cal.dateComponents([.day], from: today, to: d).day ?? 0
            return [0.2, 0.7, 0.4, 0.9, 0.55, 0.1, 0.0][min(6, max(0, offset))]
        },
        onSelect: { _ in }
    )
    .padding()
    .frame(width: 360)
    .background(Color(white: 0.98))
}
#endif
