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
    @State private var contentAppeared = false

    private func pomodoroBadge(_ text: String, icon: String, color: Color) -> some View {
        Label(text, systemImage: icon)
            .font(.caption2)
            .padding(.horizontal, DS.Spacing.sm)
            .padding(.vertical, DS.Spacing.xxs)
            .background(DS.Colors.badgeFill(color))
            .clipShape(RoundedRectangle(cornerRadius: DS.Size.badgeCornerRadius))
    }

    private var isLocal: Bool {
        event.isLocalEvent
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
                                .foregroundColor(DS.Colors.textSecondary)
                                .accessibilityLabel("Recurring event")
                        }
                    }
                    .opacity(contentAppeared ? 1 : 0)
                    .offset(y: contentAppeared ? 0 : 8)

                    // Date & Time group
                    VStack(alignment: .leading, spacing: DS.Spacing.md) {
                        Label(event.formattedDate, systemImage: "calendar")
                            .font(.subheadline)
                            .foregroundColor(DS.Colors.textSecondary)
                            .accessibilityLabel("Date: \(event.formattedDate)")

                        Label(event.formattedTimeRange, systemImage: "clock")
                            .font(.subheadline)
                            .foregroundColor(DS.Colors.textSecondary)
                            .accessibilityLabel("Time: \(event.formattedTimeRange)")
                    }
                    .opacity(contentAppeared ? 1 : 0)
                    .offset(y: contentAppeared ? 0 : 8)

                    // Location
                    if let location = event.location, !location.isEmpty {
                        Label(location, systemImage: "location.fill")
                            .font(.subheadline)
                            .foregroundColor(DS.Colors.textSecondary)
                            .opacity(contentAppeared ? 1 : 0)
                            .offset(y: contentAppeared ? 0 : 8)
                    }

                    // Description
                    if let description = event.description, !description.isEmpty {
                        VStack(alignment: .leading, spacing: DS.Spacing.sm) {
                            Label("Notes", systemImage: "note.text")
                                .font(.caption)
                                .fontWeight(.medium)
                                .foregroundStyle(DS.Colors.textTertiary)
                            Text(description)
                                .font(.subheadline)
                                .foregroundColor(DS.Colors.textSecondary)
                                .lineSpacing(DS.Typography.bodyLineSpacing)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .padding(DS.Spacing.lg)
                        .background(DS.Colors.hoverFill)
                        .clipShape(RoundedRectangle(cornerRadius: DS.Size.cornerRadius))
                        .opacity(contentAppeared ? 1 : 0)
                        .offset(y: contentAppeared ? 0 : 8)
                    }

                    // Calendar name
                    if let calName = event.calendarName {
                        Label(calName, systemImage: "tray.full")
                            .font(.caption)
                            .foregroundColor(DS.Colors.calendarLabel)
                            .opacity(contentAppeared ? 1 : 0)
                            .offset(y: contentAppeared ? 0 : 8)
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
                            .foregroundStyle(DS.Colors.textTertiary)

                            Text(rule.displayText)
                                .font(.subheadline)
                                .foregroundColor(DS.Colors.textSecondary)

                            if rule.isPomodoro {
                                let workMin = Int(event.endDate.timeIntervalSince(event.startDate) / 60)
                                let breakMin = max(rule.interval - workMin, 0)
                                FlowLayout(spacing: DS.Spacing.xs) {
                                    pomodoroBadge("\(workMin) min work", icon: "brain.head.profile", color: DS.Colors.accent)
                                    pomodoroBadge("\(breakMin) min break", icon: "cup.and.saucer", color: DS.Colors.success)
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
                                            .background(DS.Colors.accentSubtle)
                                            .clipShape(RoundedRectangle(cornerRadius: DS.Size.badgeCornerRadius))
                                            .accessibilityLabel(day.fullName)
                                    }
                                }
                            }
                        }
                        .opacity(contentAppeared ? 1 : 0)
                        .offset(y: contentAppeared ? 0 : 8)
                    }

                    // Custom reminders
                    if let reminders = event.customReminderMinutes, !reminders.isEmpty {
                        VStack(alignment: .leading, spacing: DS.Spacing.sm) {
                            Label("Reminders", systemImage: "bell.fill")
                                .font(.caption)
                                .fontWeight(.medium)
                                .foregroundStyle(DS.Colors.textTertiary)

                            HStack(spacing: DS.Spacing.xs) {
                                ForEach(reminders.sorted(), id: \.self) { min in
                                    Text(DS.formatMinutes(min))
                                        .font(.caption)
                                        .padding(.horizontal, DS.Spacing.sm)
                                        .padding(.vertical, DS.Spacing.xxs)
                                        .background(DS.Colors.badgeFill(DS.Colors.textSecondary))
                                        .clipShape(RoundedRectangle(cornerRadius: DS.Size.badgeCornerRadius))
                                }
                            }
                        }
                        .opacity(contentAppeared ? 1 : 0)
                        .offset(y: contentAppeared ? 0 : 8)
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
        .onAppear {
            withAnimation(DS.Animation.smoothSpring.delay(0.1)) {
                contentAppeared = true
            }
        }
    }
}
