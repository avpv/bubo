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
                .fill(DS.urgencyColor(minutesUntil: event.minutesUntilStart))
                .frame(width: DS.Size.accentBarWidth, height: DS.Size.accentBarHeight)
                .padding(.trailing, DS.Spacing.md)

            // Time indicator
            VStack(spacing: DS.Spacing.xxs) {
                Text(event.formattedTime)
                    .font(.system(.caption, design: .monospaced))
                    .fontWeight(.bold)
                    .foregroundColor(DS.urgencyColor(minutesUntil: event.minutesUntilStart))

                Text(timeUntilText)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundColor(DS.urgencyColor(minutesUntil: event.minutesUntilStart).opacity(0.8))
            }
            .frame(width: DS.Size.timeColumnWidth)
            .padding(.trailing, DS.Spacing.xs)

            // Event details
            VStack(alignment: .leading, spacing: DS.Spacing.xxs) {
                HStack(spacing: DS.Spacing.xs) {
                    Text(event.title)
                        .font(.subheadline)
                        .fontWeight(.medium)
                        .lineLimit(2)

                    if event.isRecurring {
                        Image(systemName: "repeat")
                            .font(.system(size: DS.Size.iconSmall))
                            .foregroundColor(.secondary)
                    }
                }

                HStack(spacing: DS.Spacing.md) {
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

            Spacer(minLength: DS.Spacing.md)

            // Actions on hover
            if isHovered {
                HStack(spacing: DS.Spacing.xs) {
                    if event.isUpcoming {
                        Menu {
                            ForEach(DS.snoozeOptions) { option in
                                Button(option.label) {
                                    reminderService.snoozeReminder(for: event, minutes: option.minutes)
                                }
                            }
                        } label: {
                            Image(systemName: "bell.badge")
                                .font(.system(size: DS.Size.iconMedium))
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
                                .font(.system(size: DS.Size.iconLarge))
                                .symbolRenderingMode(.hierarchical)
                                .foregroundStyle(.red)
                        }
                        .buttonStyle(.borderless)
                        .help("Delete event")
                    }
                }
                .transition(.opacity.animation(DS.Animation.quick))
            }
        }
        .padding(.vertical, DS.Spacing.xs)
        .padding(.horizontal, DS.Spacing.xs)
        .background(
            RoundedRectangle(cornerRadius: DS.Size.cornerRadius)
                .fill(isHovered ? Color.primary.opacity(0.06) : Color.clear)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            onTap?(event)
        }
        .onHover { hovering in
            withAnimation(DS.Animation.quick) {
                isHovered = hovering
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(event.title), \(event.formattedTimeRange)\(event.location.map { ", \($0)" } ?? "")")
        .accessibilityHint("Click to view details. Right-click to snooze.")
        .accessibilityAddTraits(.isButton)
        .contextMenu {
            Section("Snooze") {
                ForEach(DS.snoozeOptions) { option in
                    Button(option.label) {
                        reminderService.snoozeReminder(for: event, minutes: option.minutes)
                    }
                }
            }
            if isLocal {
                Divider()
                Button("Edit") { onEdit?(event) }
                Button("Delete", role: .destructive) { onDelete?(event) }
            }
        }
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
