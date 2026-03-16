import SwiftUI

struct DaySectionView: View {
    let date: Date
    let events: [CalendarEvent]
    let reminderService: ReminderService

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(dayTitle)
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundColor(.secondary)
                .textCase(.uppercase)
                .padding(.horizontal)

            ForEach(events) { event in
                EventRowView(event: event, reminderService: reminderService)
            }
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
            formatter.locale = Locale(identifier: "en_US")
            formatter.dateFormat = "MMMM d, EEEE"
            return formatter.string(from: date)
        }
    }
}
