import SwiftUI

/// Section header used inside the MenuBarView List
struct DaySectionHeader: View {
    let date: Date
    let count: Int

    @State private var appeared = false

    var body: some View {
        HStack(spacing: DS.Spacing.sm) {
            Text(dayTitle)
                .font(.subheadline)
                .fontWeight(.semibold)
                .foregroundColor(isToday ? DS.Colors.accent : DS.Colors.textPrimary)
            if isToday {
                Circle()
                    .fill(DS.Colors.accent)
                    .frame(width: DS.Size.todayDotSize, height: DS.Size.todayDotSize)
                    .scaleEffect(appeared ? 1 : 0)
            }
            Spacer()
            Text("\(count)")
                .font(.caption)
                .foregroundColor(DS.Colors.textSecondary)
                .padding(.horizontal, DS.Spacing.sm)
                .padding(.vertical, DS.Spacing.xxs)
                .background(DS.Colors.badgeFill(DS.Colors.textSecondary))
                .clipShape(Capsule())
        }
        .onAppear {
            withAnimation(DS.Animation.gentleBounce.delay(0.15)) {
                appeared = true
            }
        }
    }

    private var isToday: Bool {
        Calendar.current.isDateInToday(date)
    }

    private var dayTitle: String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) {
            return "Today"
        } else if calendar.isDateInTomorrow(date) {
            return "Tomorrow"
        } else {
            return DS.daySectionFormatter.string(from: date)
        }
    }
}
