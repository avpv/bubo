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

                HStack(spacing: 8) {
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
            }

            Spacer(minLength: 8)

            // Actions on hover
            if isHovered {
                HStack(spacing: 4) {
                    if event.isUpcoming {
                        Menu {
                            Button("5 minutes") {
                                reminderService.snoozeReminder(for: event, minutes: 5)
                            }
                            Button("10 minutes") {
                                reminderService.snoozeReminder(for: event, minutes: 10)
                            }
                            Button("15 minutes") {
                                reminderService.snoozeReminder(for: event, minutes: 15)
                            }
                        } label: {
                            Image(systemName: "bell.badge")
                                .font(.system(size: 13))
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.borderless)
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                        .help("Snooze reminder")
                    }

                    if isLocal {
                        Button {
                            onDelete?(event)
                        } label: {
                            Image(systemName: "minus.circle.fill")
                                .font(.system(size: 14))
                                .symbolRenderingMode(.hierarchical)
                                .foregroundStyle(.red)
                        }
                        .buttonStyle(.borderless)
                        .help("Delete event")
                    }
                }
                .transition(.opacity.animation(.easeInOut(duration: 0.15)))
            }
        }
        .padding(.vertical, 3)
        .padding(.horizontal, 4)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isHovered ? Color.primary.opacity(0.06) : Color.clear)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            onTap?(event)
        }
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovered = hovering
            }
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
            if isLocal {
                Divider()
                Button("Edit") { onEdit?(event) }
                Button("Delete", role: .destructive) { onDelete?(event) }
            }
        }
    }

    private var urgencyColor: Color {
        let minutes = event.minutesUntilStart
        if minutes <= 0 { return .red }
        if minutes <= 5 { return .red }
        if minutes <= 15 { return .orange }
        return .green
    }

    private var timeUntilText: String {
        let minutes = event.minutesUntilStart
        if minutes <= 0 { return "now" }
        if minutes < 60 { return "in \(minutes)m" }
        let hours = minutes / 60
        let mins = minutes % 60
        if mins == 0 { return "in \(hours)h" }
        return "in \(hours)h \(mins)m"
    }
}
