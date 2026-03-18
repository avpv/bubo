import SwiftUI

struct EventRowView: View {
    let event: CalendarEvent
    let reminderService: ReminderService
    var onEdit: ((CalendarEvent) -> Void)? = nil
    var onDelete: ((CalendarEvent) -> Void)? = nil
    var onTap: ((CalendarEvent) -> Void)? = nil

    @State private var isHovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var isLocal: Bool {
        event.isLocalEvent
    }

    var body: some View {
        HStack(alignment: .center, spacing: 0) {
            // Urgency accent bar with glow for imminent events
            urgencyBar

            // Time indicator
            timeColumn

            // Event details
            eventDetails

            Spacer(minLength: DS.Spacing.md)

            // Actions on hover — slide in from right
            if isHovered {
                hoverActions
            }
        }
        .padding(.vertical, DS.Spacing.sm)
        .padding(.horizontal, DS.Spacing.sm)
        .background(
            RoundedRectangle(cornerRadius: DS.Size.cornerRadius, style: .continuous)
                .fill(DS.Materials.platter)
                .overlay(
                    RoundedRectangle(cornerRadius: DS.Size.cornerRadius, style: .continuous)
                        .fill(isHovered ? DS.Colors.hoverFill : Color.clear)
                )
        )
        .shadow(
            color: isHovered ? DS.Shadows.hoverColor : DS.Shadows.ambientColor,
            radius: isHovered ? DS.Shadows.hoverRadius : DS.Shadows.ambientRadius,
            y: isHovered ? DS.Shadows.hoverY : DS.Shadows.ambientY
        )
        // Hover scale — slightly more pronounced for tactile feel
        .scaleEffect(isHovered ? 1.02 : 1.0)
        .contentShape(Rectangle())
        .onTapGesture {
            Haptics.tap()
            onTap?(event)
        }
        .onHover { hovering in
            withAnimation(DS.Animation.microInteraction) {
                isHovered = hovering
            }
            if hovering { Haptics.generic() }
        }
        // Scroll-aware transition: fade/scale as items enter/exit viewport
        .eventScrollTransition()
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(event.title)\(event.isRecurring ? ", recurring" : ""), \(event.formattedTimeRange)\(event.location.map { ", \($0)" } ?? "")")
        .accessibilityHint("Click to view details. Right-click to set reminder.")
        .accessibilityAddTraits(.isButton)
        .contextMenu {
            Section("Set Reminder") {
                reminderMenuItems
            }
            if isLocal {
                Divider()
                Button("Edit") { onEdit?(event) }
                Button("Delete", role: .destructive) { onDelete?(event) }
            }
        }
    }

    // MARK: - Urgency Bar

    private var urgencyBar: some View {
        Capsule()
            .fill(DS.urgencyColor(minutesUntil: event.minutesUntilStart))
            .frame(width: DS.Size.accentBarWidth, height: DS.Size.accentBarHeight)
            .padding(.trailing, DS.Spacing.md)
            .shadow(
                color: DS.urgencyColor(minutesUntil: event.minutesUntilStart).opacity(event.minutesUntilStart <= 15 ? 0.6 : 0.2),
                radius: event.minutesUntilStart <= 5 ? 6 : 3
            )
    }

    // MARK: - Time Column

    private var timeColumn: some View {
        VStack(spacing: DS.Spacing.xxs) {
            Text(event.formattedTime)
                .font(.system(.caption, design: .monospaced))
                .fontWeight(.bold)
                .foregroundColor(DS.Colors.textPrimary)

            Text(timeUntilText)
                .font(.system(.caption2, design: .monospaced))
                .foregroundColor(DS.Colors.textSecondary)
                .contentTransition(.numericText())
        }
        .frame(width: DS.Size.timeColumnWidth)
        .padding(.trailing, DS.Spacing.xs)
    }

    // MARK: - Event Details

    private var eventDetails: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.xxs) {
            HStack(spacing: DS.Spacing.xs) {
                Text(event.title)
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .lineLimit(2)

                if event.recurrenceRule?.isPomodoro == true {
                    Image(systemName: "timer")
                        .font(.system(size: DS.Size.iconSmall))
                        .foregroundColor(DS.Colors.warning)
                        .contentTransition(.symbolEffect(.replace))
                        .accessibilityLabel("Pomodoro")
                } else if event.isRecurring {
                    Image(systemName: "repeat")
                        .font(.system(size: DS.Size.iconSmall))
                        .foregroundColor(DS.Colors.textSecondary)
                        .contentTransition(.symbolEffect(.replace))
                        .accessibilityLabel("Recurring")
                }
            }

            HStack(spacing: DS.Spacing.md) {
                if let location = event.location, !location.isEmpty {
                    Label(location, systemImage: "mappin")
                        .font(.caption2)
                        .foregroundColor(DS.Colors.textSecondary)
                        .lineLimit(1)
                }

                if let calName = event.calendarName {
                    Text(calName)
                        .font(.caption2)
                        .foregroundColor(DS.Colors.textTertiary)
                }
            }
        }
    }

    // MARK: - Hover Actions

    private var hoverActions: some View {
        HStack(spacing: DS.Spacing.xs) {
            if event.isUpcoming {
                Menu {
                    reminderMenuItems
                } label: {
                    Image(systemName: "bell.badge")
                        .font(.system(size: DS.Size.iconMedium))
                        .foregroundStyle(DS.Colors.textSecondary)
                }
                .buttonStyle(.borderless)
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Set reminder")
                .accessibilityLabel("Set reminder")
            }

            if isLocal {
                Button {
                    Haptics.impact()
                    onDelete?(event)
                } label: {
                    Image(systemName: "minus.circle.fill")
                        .font(.system(size: DS.Size.iconLarge))
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(DS.Colors.error)
                }
                .buttonStyle(.borderless)
                .help("Delete event")
            }
        }
        .transition(
            .asymmetric(
                insertion: .move(edge: .trailing).combined(with: .opacity),
                removal: .opacity
            )
        )
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

    @ViewBuilder
    private var reminderMenuItems: some View {
        let activeReminders = reminderService.activeReminderMinutes(for: event)
        let customReminders = activeReminders.filter { active in 
            !DS.snoozeOptions.contains { $0.minutes == active }
        }
        let allOptions = (DS.snoozeOptions.map { $0.minutes } + customReminders).sorted()

        ForEach(allOptions, id: \.self) { minutes in
            Toggle(isOn: Binding(
                get: { activeReminders.contains(minutes) },
                set: { isSet in
                    var current = Set(activeReminders)
                    if isSet {
                        current.insert(minutes)
                    } else {
                        current.remove(minutes)
                    }
                    reminderService.updateLocalReminder(for: event.id, minutes: Array(current).sorted())
                }
            )) {
                if let option = DS.snoozeOptions.first(where: { $0.minutes == minutes }) {
                    Text(option.label)
                } else {
                    Text("\(DS.formatMinutes(minutes)) before")
                }
            }
        }
        Divider()
        Button("Clear All") {
            reminderService.updateLocalReminder(for: event.id, minutes: [])
        }
        .disabled(activeReminders.isEmpty)
    }
}
