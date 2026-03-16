import SwiftUI

struct EventRowView: View {
    let event: CalendarEvent
    let reminderService: ReminderService

    @State private var showSnoozeMenu = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            // Time indicator
            VStack {
                Text(event.formattedTime)
                    .font(.system(.caption, design: .monospaced))
                    .fontWeight(.bold)
                    .foregroundColor(urgencyColor)
            }
            .frame(width: 50)

            // Event details
            VStack(alignment: .leading, spacing: 2) {
                Text(event.title)
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .lineLimit(2)

                if let location = event.location, !location.isEmpty {
                    HStack(spacing: 2) {
                        Image(systemName: "location.fill")
                            .font(.caption2)
                        Text(location)
                            .font(.caption)
                    }
                    .foregroundColor(.secondary)
                }

                if let calName = event.calendarName {
                    Text(calName)
                        .font(.caption2)
                        .foregroundColor(.blue)
                }

                Text(timeUntilText)
                    .font(.caption2)
                    .foregroundColor(urgencyColor)
            }

            Spacer()
        }
        .padding(.horizontal)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(urgencyColor.opacity(0.05))
        )
        .padding(.horizontal, 4)
        .contextMenu {
            Button("Remind in 5 min") {
                reminderService.snoozeReminder(for: event, minutes: 5)
            }
            Button("Remind in 10 min") {
                reminderService.snoozeReminder(for: event, minutes: 10)
            }
            Button("Remind in 15 min") {
                reminderService.snoozeReminder(for: event, minutes: 15)
            }
        }
    }

    private var urgencyColor: Color {
        let minutes = event.minutesUntilStart
        if minutes <= 5 { return .red }
        if minutes <= 15 { return .orange }
        return .green
    }

    private var timeUntilText: String {
        let minutes = event.minutesUntilStart
        if minutes < 1 { return "Now!" }
        if minutes < 60 { return "in \(minutes) min" }
        let hours = minutes / 60
        let mins = minutes % 60
        if mins == 0 { return "in \(hours) h" }
        return "in \(hours) h \(mins) min"
    }
}
