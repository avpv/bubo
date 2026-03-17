import SwiftUI

struct EventDetailView: View {
    let event: CalendarEvent
    var onBack: () -> Void
    var onEdit: ((CalendarEvent) -> Void)? = nil
    var onDelete: ((CalendarEvent) -> Void)? = nil
    var onDeleteSeries: ((CalendarEvent) -> Void)? = nil
    var onDeleteOccurrence: ((CalendarEvent) -> Void)? = nil

    @State private var showDeleteConfirmation = false
    @State private var showSeriesDeleteChoice = false

    private func pomodoroBadge(_ text: String, icon: String, color: Color) -> some View {
        Label(text, systemImage: icon)
            .font(.caption2)
            .padding(.horizontal, DS.Spacing.sm)
            .padding(.vertical, DS.Spacing.xxs)
            .background(color.opacity(0.15))
            .clipShape(RoundedRectangle(cornerRadius: DS.Size.badgeCornerRadius))
    }

    private var isLocal: Bool {
        event.calendarName == "Local"
    }

    var body: some View {
        VStack(spacing: 0) {
            PopoverHeader(
                title: isLocal ? "Event" : nil,
                showBack: true,
                onBack: onBack
            )

            ScrollView {
                VStack(alignment: .leading, spacing: DS.Spacing.xl) {
                    // Title
                    HStack(spacing: DS.Spacing.sm) {
                        Text(event.title)
                            .font(.title3)
                            .fontWeight(.semibold)
                            .accessibilityAddTraits(.isHeader)

                        if event.isRecurring {
                            Image(systemName: "repeat")
                                .font(.system(size: DS.Size.iconMedium))
                                .foregroundColor(.secondary)
                                .accessibilityLabel("Recurring event")
                        }
                    }

                    // Date & Time group
                    VStack(alignment: .leading, spacing: DS.Spacing.md) {
                        Label(event.formattedDate, systemImage: "calendar")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .accessibilityLabel("Date: \(event.formattedDate)")

                        Label(event.formattedTimeRange, systemImage: "clock")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .accessibilityLabel("Time: \(event.formattedTimeRange)")
                    }

                    // Location
                    if let location = event.location, !location.isEmpty {
                        Label(location, systemImage: "location.fill")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }

                    // Description
                    if let description = event.description, !description.isEmpty {
                        VStack(alignment: .leading, spacing: DS.Spacing.sm) {
                            Label("Notes", systemImage: "note.text")
                                .font(.caption)
                                .fontWeight(.medium)
                                .foregroundStyle(.tertiary)
                            Text(description)
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                                .lineSpacing(DS.Typography.bodyLineSpacing)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .padding(DS.Spacing.lg)
                        .background(Color.primary.opacity(0.04))
                        .clipShape(RoundedRectangle(cornerRadius: DS.Size.cornerRadius))
                    }

                    // Calendar name
                    if let calName = event.calendarName {
                        Label(calName, systemImage: "tray.full")
                            .font(.caption)
                            .foregroundColor(.blue)
                    }

                    // Recurrence
                    if let rule = event.recurrenceRule {
                        VStack(alignment: .leading, spacing: DS.Spacing.sm) {
                            Label(
                                rule.isPomodoro ? "Pomodoro" : "Repeats",
                                systemImage: rule.isPomodoro ? "timer" : "repeat"
                            )
                            .font(.caption)
                            .fontWeight(.medium)
                            .foregroundStyle(.tertiary)

                            Text(rule.displayText)
                                .font(.subheadline)
                                .foregroundColor(.secondary)

                            if rule.isPomodoro {
                                let workMin = Int(event.endDate.timeIntervalSince(event.startDate) / 60)
                                let breakMin = max(rule.interval - workMin, 0)
                                FlowLayout(spacing: DS.Spacing.xs) {
                                    pomodoroBadge("\(workMin) min work", icon: "brain.head.profile", color: .accentColor)
                                    pomodoroBadge("\(breakMin) min break", icon: "cup.and.saucer", color: .green)
                                    if rule.pomodoroLongBreak > 0 {
                                        pomodoroBadge("\(rule.pomodoroLongBreak) min long break", icon: "moon.zzz", color: .indigo)
                                    }
                                }
                            }

                            if rule.frequency == .weekly && !rule.weekdays.isEmpty {
                                HStack(spacing: DS.Spacing.xs) {
                                    ForEach(Weekday.allCases.filter { rule.weekdays.contains($0) }, id: \.self) { day in
                                        Text(day.shortName)
                                            .font(.caption2)
                                            .padding(.horizontal, DS.Spacing.sm)
                                            .padding(.vertical, DS.Spacing.xxs)
                                            .background(Color.accentColor.opacity(0.15))
                                            .clipShape(RoundedRectangle(cornerRadius: DS.Size.badgeCornerRadius))
                                            .accessibilityLabel(day.fullName)
                                    }
                                }
                            }
                        }
                    }

                    // Custom reminders
                    if let reminders = event.customReminderMinutes, !reminders.isEmpty {
                        VStack(alignment: .leading, spacing: DS.Spacing.sm) {
                            Label("Reminders", systemImage: "bell.fill")
                                .font(.caption)
                                .fontWeight(.medium)
                                .foregroundStyle(.tertiary)

                            HStack(spacing: DS.Spacing.xs) {
                                ForEach(reminders.sorted(), id: \.self) { min in
                                    Text(DS.formatMinutes(min))
                                        .font(.caption)
                                        .padding(.horizontal, DS.Spacing.sm)
                                        .padding(.vertical, DS.Spacing.xxs)
                                        .background(.secondary.opacity(0.12))
                                        .clipShape(RoundedRectangle(cornerRadius: DS.Size.badgeCornerRadius))
                                }
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(DS.Spacing.xl)
            }
            .frame(maxHeight: DS.Popover.detailMaxHeight)

            Spacer(minLength: 0)

            // Actions (only for local events)
            if isLocal {
                Divider()

                HStack {
                    Button(role: .destructive) {
                        if event.isRecurring {
                            showSeriesDeleteChoice = true
                        } else {
                            showDeleteConfirmation = true
                        }
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                    // Single (non-recurring) event
                    .confirmationDialog(
                        "Delete Event",
                        isPresented: $showDeleteConfirmation,
                        titleVisibility: .visible
                    ) {
                        Button("Delete", role: .destructive) { onDelete?(event) }
                        Button("Cancel", role: .cancel) { }
                    } message: {
                        Text("Are you sure you want to delete \"\(event.title)\"?")
                    }
                    // Recurring event — scope-of-delete
                    .confirmationDialog(
                        "Delete Recurring Event",
                        isPresented: $showSeriesDeleteChoice,
                        titleVisibility: .visible
                    ) {
                        Button("Delete This Event Only") {
                            onDeleteOccurrence?(event)
                        }
                        Button("Delete All Events", role: .destructive) {
                            onDeleteSeries?(event)
                        }
                        Button("Cancel", role: .cancel) { }
                    } message: {
                        Text("\"\(event.title)\" is a recurring event.")
                    }

                    Spacer()

                    Button {
                        onEdit?(event)
                    } label: {
                        Label("Edit", systemImage: "pencil")
                    }
                    .buttonStyle(.borderedProminent)
                }
                .padding(.horizontal, DS.Spacing.lg)
                .padding(.vertical, DS.Spacing.md)
                .background(.bar)
            }
        }
        .frame(width: DS.Popover.width)
        .frame(minHeight: DS.Popover.detailMinHeight)
    }
}
