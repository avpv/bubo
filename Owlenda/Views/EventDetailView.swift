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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast

    private func pomodoroBadge(_ text: String, icon: String, color: Color) -> some View {
        Label(text, systemImage: icon)
            .font(.caption2)
            .padding(.horizontal, DS.Spacing.md)
            .padding(.vertical, DS.Spacing.xs)
            .adaptiveBadgeFill(color)
            .clipShape(Capsule())
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
                            .font(.system(.title2, design: .rounded, weight: .bold))
                            .accessibilityAddTraits(.isHeader)

                        if event.isRecurring {
                            Image(systemName: "repeat")
                                .font(.system(size: DS.Size.iconMedium))
                                .foregroundColor(DS.Colors.textSecondary)
                                .contentTransition(.symbolEffect(.replace))
                                .accessibilityLabel("Recurring event")
                        }
                    }
                    .staggeredEntrance(index: 0)

                    VStack(alignment: .leading, spacing: DS.Spacing.md) {
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
                        .staggeredEntrance(index: 1)

                        // Location
                        if let location = event.location, !location.isEmpty {
                            Label(location, systemImage: "location.fill")
                                .font(.subheadline)
                                .foregroundColor(DS.Colors.textSecondary)
                                .staggeredEntrance(index: 2)
                        }
                    }
                    .padding(DS.Spacing.lg)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(DS.Materials.platter)
                    .clipShape(RoundedRectangle(cornerRadius: DS.Size.cornerRadius, style: .continuous))
                    .shadow(color: DS.Shadows.ambientColor, radius: DS.Shadows.ambientRadius, y: DS.Shadows.ambientY)

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
                        .background(DS.Materials.platter)
                        .clipShape(RoundedRectangle(cornerRadius: DS.Size.cornerRadius, style: .continuous))
                        .shadow(color: DS.Shadows.ambientColor, radius: DS.Shadows.ambientRadius, y: DS.Shadows.ambientY)
                        .staggeredEntrance(index: 3)
                    }

                    // Calendar name
                    if let calName = event.calendarName {
                        Label(calName, systemImage: "tray.full")
                            .font(.caption)
                            .foregroundColor(DS.Colors.calendarLabel)
                            .staggeredEntrance(index: 4)
                    }

                    // Recurrence
                    if let rule = event.recurrenceRule {
                        recurrenceSection(rule)
                            .staggeredEntrance(index: 5)
                    }

                    // Custom reminders
                    if let reminders = event.customReminderMinutes, !reminders.isEmpty {
                        remindersSection(reminders)
                            .staggeredEntrance(index: 6)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(DS.Spacing.xl)
            }
            .frame(maxHeight: DS.Popover.detailMaxHeight)

            Spacer(minLength: 0)

            // Actions (only for local events)
            Divider()

            HStack {
                if isLocal {
                    Button(role: .destructive) {
                        Haptics.impact()
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
                }

                Spacer()

                Button {
                        Haptics.tap()
                        onEdit?(event)
                    } label: {
                        Label("Edit", systemImage: "pencil")
                            .padding(.horizontal, DS.Spacing.md)
                            .padding(.vertical, DS.Spacing.xs)
                    }
                    .background(DS.Colors.accent)
                    .foregroundColor(.white)
                    .fontWeight(.medium)
                    .buttonStyle(.plain)
                    .clipShape(Capsule())
                    .shadow(color: DS.Colors.accent.opacity(0.3), radius: 6, y: 3)
                .shadow(color: DS.Colors.accent.opacity(0.3), radius: 6, y: 3)
            }
            .padding(.horizontal, DS.Spacing.lg)
            .padding(.vertical, DS.Spacing.sm)
            .background(DS.Materials.headerBar)
        }
        .frame(width: DS.Popover.width)
        .frame(minHeight: DS.Popover.detailMinHeight)
    }

    // MARK: - Recurrence Section

    @ViewBuilder
    private func recurrenceSection(_ rule: RecurrenceRule) -> some View {
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
                            .padding(.horizontal, DS.Spacing.md)
                            .padding(.vertical, DS.Spacing.xs)
                            .background(DS.Colors.accentSubtle)
                            .clipShape(Capsule())
                            .accessibilityLabel(day.fullName)
                    }
                }
            }
        }
    }

    // MARK: - Reminders Section

    @ViewBuilder
    private func remindersSection(_ reminders: [Int]) -> some View {
        VStack(alignment: .leading, spacing: DS.Spacing.sm) {
            Label("Reminders", systemImage: "bell.fill")
                .font(.caption)
                .fontWeight(.medium)
                .foregroundStyle(DS.Colors.textTertiary)

            HStack(spacing: DS.Spacing.xs) {
                ForEach(reminders.sorted(), id: \.self) { min in
                    Text(DS.formatMinutes(min))
                        .font(.caption)
                        .padding(.horizontal, DS.Spacing.md)
                        .padding(.vertical, DS.Spacing.xs)
                        .adaptiveBadgeFill(DS.Colors.textSecondary)
                        .clipShape(Capsule())
                }
            }
        }
    }
}
