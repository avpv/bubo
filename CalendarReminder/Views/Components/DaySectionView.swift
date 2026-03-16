import SwiftUI

/// Section header used inside the MenuBarView List
struct DaySectionHeader: View {
    let date: Date
    let count: Int

    var body: some View {
        HStack {
            Text(dayTitle)
            Spacer()
            Text("\(count)")
                .foregroundColor(.secondary)
        }
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
