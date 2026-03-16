import SwiftUI

struct EventRowView: View {
    let event: CalendarEvent
    let reminderService: ReminderService
    var onEdit: ((CalendarEvent) -> Void)? = nil
    var onDelete: ((CalendarEvent) -> Void)? = nil
    var onTap: ((CalendarEvent) -> Void)? = nil

    @State private var isHovered = false

    private var isLocal: Bool {
        event.calendarName == "Local"
    }

    var body: some View {
        HStack(alignment: .center, spacing: 0) {
            // Urgency accent bar
            RoundedRectangle(cornerRadius: 1.5)
                .fill(urgencyColor)
                .frame(width: 3, height: 28)
                .padding(.trailing, 8)

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
            .padding(.trailing, 4)

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

            // Delete button (local events only, shown on hover)
            if isLocal && isHovered {
                Button {
                    onDelete?(event)
                } label: {
                    Image(systemName: "minus.circle.fill")
                        .font(.system(size: 16))
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(.red)
                }
                .buttonStyle(.borderless)
                .help("Delete")
                .transition(.opacity)
            }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onTapGesture {
            onTap?(event)
        }
        .onHover { hovering in
            isHovered = hovering
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(event.title), \(event.formattedTimeRange)\(event.location.map { ", \($0)" } ?? "")")
        .accessibilityHint("Click to view details. Right-click to snooze.")
        .accessibilityAddTraits(.isButton)
        .contextMenu {
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
