import SwiftUI

struct DaySectionView: View {
    let date: Date
    let events: [CalendarEvent]
    let reminderService: ReminderService

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Day header
            HStack(spacing: 6) {
                if isToday {
                    Text(dayNumber)
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                        .foregroundColor(.white)
                        .frame(width: 22, height: 22)
                        .background(Circle().fill(Color.accentColor.gradient))
                } else {
                    Text(dayNumber)
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundColor(.secondary)
                        .frame(width: 22, height: 22)
                        .background(
                            Circle()
                                .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
                        )
                }

                Text(dayTitle)
                    .font(.system(.caption, design: .rounded).weight(.semibold))
                    .foregroundColor(isToday ? .primary : .secondary)

                if isToday {
                    Text("Today")
                        .font(.system(size: 9, weight: .bold, design: .rounded))
                        .foregroundColor(.accentColor)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(
                            Capsule()
                                .fill(Color.accentColor.opacity(0.12))
                        )
                }

                Spacer()

                Text("\(events.count)")
                    .font(.system(size: 9, weight: .medium, design: .rounded))
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.top, 4)

            ForEach(events) { event in
                EventRowView(event: event, reminderService: reminderService)
            }
        }
    }

    private var isToday: Bool {
        Calendar.current.isDateInToday(date)
    }

    private var dayNumber: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "d"
        return formatter.string(from: date)
    }

    private var dayTitle: String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) {
            let formatter = DateFormatter()
            formatter.dateFormat = "EEEE"
            return formatter.string(from: date)
        } else if calendar.isDateInTomorrow(date) {
            return "Tomorrow"
        } else {
            let formatter = DateFormatter()
            formatter.dateFormat = "EEEE, MMM d"
            return formatter.string(from: date)
        }
    }
}
