import SwiftUI

/// Section header used inside the MenuBarView List
struct DaySectionHeader: View {
    let date: Date
    let count: Int

    var body: some View {
        HStack(spacing: 6) {
            Text(dayTitle)
                .font(.subheadline)
                .fontWeight(.semibold)
                .foregroundColor(isToday ? .accentColor : .primary)
            if isToday {
                Circle()
                    .fill(.accentColor)
                    .frame(width: 6, height: 6)
            }
            Spacer()
            Text("\(count)")
                .font(.caption)
                .foregroundColor(.secondary)
                .padding(.horizontal, 6)
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
            let formatter = DateFormatter()
            formatter.dateFormat = "EEEE, MMM d"
            return formatter.string(from: date)
        }
    }
}
