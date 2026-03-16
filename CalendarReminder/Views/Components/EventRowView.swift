import SwiftUI

struct EventRowView: View {
    let event: CalendarEvent
    let reminderService: ReminderService
    var onEdit: ((CalendarEvent) -> Void)? = nil
    var onDelete: ((CalendarEvent) -> Void)? = nil

    private var isLocal: Bool {
        event.calendarName == "Local"
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            // Time indicator
            VStack(spacing: 2) {
                Text(event.formattedTime)
                    .font(.system(.caption, design: .monospaced))
                    .fontWeight(.bold)
                    .foregroundColor(urgencyColor)

                Text(timeUntilText)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundColor(urgencyColor.opacity(0.8))
            }
            .frame(width: 50)

            // Event details
            VStack(alignment: .leading, spacing: 2) {
                Text(event.title)
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .lineLimit(2)

                if let location = event.location, !location.isEmpty {
                    Label(location, systemImage: "location.fill")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }

                if let calName = event.calendarName {
                    Text(calName)
                        .font(.caption2)
                        .foregroundColor(.blue)
                }
            }

            Spacer()
        }
        .contextMenu {
            if isLocal {
                Button {
                    onEdit?(event)
                } label: {
                    Label("Edit", systemImage: "pencil")
                }

                Button(role: .destructive) {
                    onDelete?(event)
                } label: {
                    Label("Delete", systemImage: "trash")
                }

                Divider()
            }

            Section("Snooze") {
                Button("5 minutes") {
                    reminderService.snoozeReminder(for: event, minutes: 5)
                }
                Button("10 minutes") {
                    reminderService.snoozeReminder(for: event, minutes: 10)
                }
                Button("15 minutes") {
                    reminderService.snoozeReminder(for: event, minutes: 15)
                }
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
        if minutes < 1 { return "now" }
        if minutes < 60 { return "in \(minutes)m" }
        let hours = minutes / 60
        let mins = minutes % 60
        if mins == 0 { return "in \(hours)h" }
        return "in \(hours)h \(mins)m"
    }
}
