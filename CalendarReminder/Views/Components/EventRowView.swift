import SwiftUI

struct EventRowView: View {
    let event: CalendarEvent
    let reminderService: ReminderService

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 0) {
            // Urgency accent bar
            RoundedRectangle(cornerRadius: 2)
                .fill(urgencyColor.gradient)
                .frame(width: 3, height: isHovered ? 44 : 36)
                .animation(.easeOut(duration: 0.2), value: isHovered)

            HStack(alignment: .center, spacing: 10) {
                // Time column
                VStack(spacing: 2) {
                    Text(event.formattedTime)
                        .font(.system(.caption, design: .rounded).weight(.bold))
                        .foregroundColor(urgencyColor)
                    Text(timeUntilText)
                        .font(.system(size: 9, weight: .medium, design: .rounded))
                        .foregroundColor(urgencyColor.opacity(0.8))
                }
                .frame(width: 52)

                // Event details
                VStack(alignment: .leading, spacing: 3) {
                    Text(event.title)
                        .font(.system(.subheadline, design: .rounded).weight(.semibold))
                        .lineLimit(2)
                        .foregroundColor(.primary)

                    HStack(spacing: 8) {
                        if let location = event.location, !location.isEmpty {
                            Label(location, systemImage: "location.fill")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                        }

                        if let calName = event.calendarName {
                            Text(calName)
                                .font(.system(size: 9, weight: .medium))
                                .foregroundColor(.accentColor)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(
                                    Capsule()
                                        .fill(Color.accentColor.opacity(0.12))
                                )
                        }
                    }
                }

                Spacer(minLength: 0)

                // Urgency badge for imminent events
                if event.minutesUntilStart <= 5 {
                    Text("NOW")
                        .font(.system(size: 9, weight: .heavy, design: .rounded))
                        .foregroundColor(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.red.gradient))
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
        }
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isHovered
                    ? Color(nsColor: .controlBackgroundColor)
                    : urgencyColor.opacity(0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(urgencyColor.opacity(isHovered ? 0.15 : 0.06), lineWidth: 0.5)
        )
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.15)) {
                isHovered = hovering
            }
        }
        .padding(.horizontal, 8)
        .contextMenu {
            Section("Snooze") {
                Button { reminderService.snoozeReminder(for: event, minutes: 5) } label: {
                    Label("5 minutes", systemImage: "clock.badge.5")
                }
                Button { reminderService.snoozeReminder(for: event, minutes: 10) } label: {
                    Label("10 minutes", systemImage: "clock.badge.10")
                }
                Button { reminderService.snoozeReminder(for: event, minutes: 15) } label: {
                    Label("15 minutes", systemImage: "clock.badge.15")
                }
            }
        }
    }

    private var urgencyColor: Color {
        let minutes = event.minutesUntilStart
        if minutes <= 5 { return .red }
        if minutes <= 15 { return .orange }
        if minutes <= 60 { return .yellow }
        return .green
    }

    private var timeUntilText: String {
        let minutes = event.minutesUntilStart
        if minutes < 1 { return "now" }
        if minutes < 60 { return "\(minutes)m" }
        let hours = minutes / 60
        let mins = minutes % 60
        if mins == 0 { return "\(hours)h" }
        return "\(hours)h \(mins)m"
    }
}
