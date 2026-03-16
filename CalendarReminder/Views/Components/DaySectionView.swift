import SwiftUI

/// Section header used inside the MenuBarView List
struct DaySectionHeader: View {
    let date: Date
    let count: Int

    var body: some View {
        HStack(spacing: DS.Spacing.sm) {
            Text(dayTitle)
                .font(.subheadline)
                .fontWeight(.semibold)
                .foregroundColor(isToday ? .accentColor : .primary)
            if isToday {
                Circle()
                    .fill(.accentColor)
                    .frame(width: DS.Size.todayDotSize, height: DS.Size.todayDotSize)
            }
            Spacer()
            Text("\(count)")
                .font(.caption)
                .foregroundColor(.secondary)
                .padding(.horizontal, DS.Spacing.sm)
                .padding(.vertical, 1)
                .background(.secondary.opacity(0.12))
                .clipShape(Capsule())
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
