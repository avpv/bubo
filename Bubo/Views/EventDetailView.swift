import SwiftUI

struct EventDetailView: View {
    let event: CalendarEvent
    var reminderService: ReminderService
    var onBack: () -> Void
    var onEdit: ((CalendarEvent) -> Void)? = nil
    var onDelete: ((CalendarEvent) -> Void)? = nil
    var onDeleteSeries: ((CalendarEvent) -> Void)? = nil
    var onDeleteOccurrence: ((CalendarEvent) -> Void)? = nil
    var onTimer: ((CalendarEvent) -> Void)? = nil

    @State private var showDeleteConfirmation = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.activeSkin) private var skin

    private var skinAccent: Color {
        skin.isClassic ? DS.Colors.accent : skin.accentColor
    }

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
        // HIG: Use TimelineView for time-based UI updates instead of Timer.publish
        TimelineView(.periodic(from: .now, by: 1)) { context in
        let now = context.date
        VStack(spacing: 0) {
            PopoverHeader(
                title: isLocal ? (event.eventType == .pomodoro ? "Pomodoro" : "Event") : nil,
                showBack: true,
                onBack: onBack
            )

            ScrollView {
                // Reminders-style inset groups: one rhythm of radii, quiet
                // section labels, colored icon tiles on every row.
                VStack(alignment: .leading, spacing: DS.Spacing.lg) {
                    titleCard

                    dateTimeSection(now: now)

                    if let meetingURL = event.meetingLink, let serviceName = event.meetingServiceName {
                        meetingSection(url: meetingURL, service: serviceName)
                    }

                    if let location = event.location, !location.isEmpty {
                        locationSection(location)
                    }

                    if let description = event.description, !description.isEmpty {
                        notesSection(description)
                    }

                    organisationSection()
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, DS.Spacing.lg)
                .padding(.vertical, DS.Spacing.lg)
            }
            .frame(maxHeight: .infinity)

            Spacer(minLength: 0)

            // Actions (only for local events)
            SkinSeparator()

            HStack {
                if isLocal {
                    if event.isRecurring {
                        // Recurring events still need confirmation to choose scope
                        Button(role: .destructive) {
                            Haptics.impact()
                            showDeleteConfirmation = true
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                        .buttonStyle(.action(role: .destructive))
                    } else {
                        // Single events: delete immediately with undo toast
                        Button(role: .destructive) {
                            Haptics.impact()
                            onDelete?(event)
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                        .buttonStyle(.action(role: .destructive))
                    }
                }

                Spacer()

                Button {
                    Haptics.tap()
                    onEdit?(event)
                } label: {
                    Label("Edit", systemImage: "pencil")
                }
                .buttonStyle(.action(role: .primary))
                .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, DS.Spacing.lg)
            .frame(height: DS.Size.actionFooterHeight)
            .skinBarBackground(skin)
            // Confirmation only for recurring events (need to choose scope)
            .confirmationDialog(
                "Delete Recurring Event",
                isPresented: $showDeleteConfirmation,
                titleVisibility: .visible
            ) {
                Button("Delete This Event Only", role: .destructive) {
                    Haptics.impact()
                    onDeleteOccurrence?(event)
                }
                Button("Delete All Events", role: .destructive) {
                    Haptics.impact()
                    onDeleteSeries?(event)
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Do you want to delete just this occurrence or all events in the series?")
            }
        }
        .frame(width: DS.Popover.width, height: DS.Popover.height)
        } // TimelineView
    }

    // MARK: - Title Card
    //
    // Mirrors Apple Reminders' hero title card: big bold text in its own
    // platter, with a recurrence glyph inline if applicable.

    private var titleCard: some View {
        HStack(alignment: .firstTextBaseline, spacing: DS.Spacing.sm) {
            Text(event.title)
                .font(.system(.title2, design: skin.resolvedFontDesign, weight: .bold))
                .foregroundStyle(skin.resolvedTextPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityAddTraits(.isHeader)

            if event.isRecurring {
                Image(systemName: "repeat")
                    .font(.system(size: DS.Size.iconMedium, weight: .medium))
                    .foregroundStyle(skin.resolvedTextSecondary)
                    .contentTransition(.symbolEffect(.replace))
                    .accessibilityLabel("Recurring event")
            }
        }
        .padding(DS.Spacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .skinPlatter(skin)
        .skinPlatterDepth(skin)
    }

    // MARK: - Date & Time Section

    @ViewBuilder
    private func dateTimeSection(now: Date) -> some View {
        FormSection(header: "Date & Time") {
            FormRow(
                icon: "calendar",
                iconTint: skin.resolvedDestructiveColor,
                title: "Date",
                trailing: {
                    Text(event.formattedDate)
                        .monospacedDigit()
                }
            )
            FormDivider()
            FormRow(
                icon: "clock",
                iconTint: DS.Colors.info,
                title: "Time",
                trailing: {
                    Text(event.formattedTimeRange)
                        .monospacedDigit()
                }
            )

            let secondsUntilStart = Int(event.startDate.timeIntervalSince(now))
            let secondsUntilEnd = Int(event.endDate.timeIntervalSince(now))
            if secondsUntilStart > 0 || secondsUntilEnd > 0 {
                FormDivider()
                countdownRow(
                    secondsUntilStart: secondsUntilStart,
                    secondsUntilEnd: secondsUntilEnd
                )
            } else {
                FormDivider()
                FormRow(
                    icon: "checkmark.circle",
                    iconTint: skin.resolvedTextTertiary,
                    title: "Ended"
                )
            }
        }
    }

    private func countdownRow(secondsUntilStart: Int, secondsUntilEnd: Int) -> some View {
        let inProgress = secondsUntilStart <= 0
        let total = inProgress ? secondsUntilEnd : secondsUntilStart
        let label = inProgress ? "Ends in" : "Starts in"
        let color = inProgress
            ? skinAccent
            : DS.urgencyColor(minutesUntil: total / 60, skin: skin)

        let days = total / 86400
        let hours = (total % 86400) / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60

        return FormRow(
            icon: "timer",
            iconTint: color,
            title: label,
            isNavigable: true,
            action: {
                Haptics.tap()
                onTimer?(event)
            },
            trailing: {
                HStack(spacing: DS.Spacing.xs) {
                    if days > 0 { countdownUnit(value: days, unit: "d") }
                    if days > 0 || hours > 0 { countdownUnit(value: hours, unit: "h") }
                    countdownUnit(value: minutes, unit: "m")
                    countdownUnit(value: seconds, unit: "s")
                }
            }
        )
    }

    private func countdownUnit(value: Int, unit: String) -> some View {
        HStack(spacing: 1) {
            Text("\(value)")
                .font(.system(.subheadline, design: .monospaced, weight: .semibold))
                .foregroundStyle(skin.resolvedTextPrimary)
                .contentTransition(.numericText())
            Text(unit)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(skin.resolvedTextSecondary)
        }
    }

    // MARK: - Meeting Section

    private func meetingSection(url: URL, service: String) -> some View {
        FormSection {
            FormRow(
                icon: "video.fill",
                iconTint: skin.resolvedSuccessColor,
                title: "Join \(service)",
                isNavigable: true,
                action: {
                    Haptics.tap()
                    NSWorkspace.shared.open(url)
                }
            )
        }
    }

    // MARK: - Location Section

    private func locationSection(_ location: String) -> some View {
        FormSection {
            FormRow(
                icon: "location.fill",
                iconTint: DS.Colors.info,
                title: location
            )
        }
    }

    // MARK: - Notes Section

    private func notesSection(_ description: String) -> some View {
        FormSection(header: "Notes") {
            MarkdownText(text: description)
                .font(.subheadline)
                .foregroundStyle(skin.resolvedTextSecondary)
                .lineSpacing(DS.Typography.bodyLineSpacing)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(DS.Spacing.md)
        }
    }

    // MARK: - Organisation Section

    /// Groups calendar membership, recurrence/Pomodoro info and reminders
    /// under a single "Organisation" heading — matches the Apple Reminders
    /// Organisation card (List, Tags, Subtasks).
    @ViewBuilder
    private func organisationSection() -> some View {
        let hasCalendar = event.calendarName != nil
        let rule = event.recurrenceRule
        let isPomodoro = event.eventType == .pomodoro
        let activeReminders = reminderService.activeReminderMinutes(for: event)
        let hasOrg = hasCalendar || rule != nil || isPomodoro || !activeReminders.isEmpty

        if hasOrg {
            FormSection(header: "Organisation") {
                if let calName = event.calendarName {
                    FormRow(
                        icon: "tray.full.fill",
                        iconTint: DS.Colors.calendarLabel,
                        title: "Calendar",
                        trailing: {
                            Text(calName)
                                .lineLimit(1)
                        }
                    )
                }

                if let rule {
                    if hasCalendar { FormDivider() }
                    recurrenceRow(rule)
                } else if isPomodoro {
                    if hasCalendar { FormDivider() }
                    FormRow(
                        icon: "timer",
                        iconTint: skinAccent,
                        title: "Pomodoro"
                    )
                }

                if !activeReminders.isEmpty {
                    if hasCalendar || rule != nil || isPomodoro { FormDivider() }
                    remindersRow(activeReminders)
                }
            }
        }
    }

    // MARK: - Recurrence Row

    @ViewBuilder
    private func recurrenceRow(_ rule: RecurrenceRule) -> some View {
        let isPomo = event.eventType == .pomodoro
        FormRow(
            icon: isPomo ? "timer" : "repeat",
            iconTint: isPomo ? skinAccent : skin.resolvedSuccessColor,
            title: isPomo ? "Pomodoro" : "Repeats",
            trailing: {
                Text(rule.displayText)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        )

        if isPomo {
            let workMin = Int(event.endDate.timeIntervalSince(event.startDate) / 60)
            let breakMin = max(rule.interval - workMin, 0)
            FormDivider()
            VStack(alignment: .leading, spacing: DS.Spacing.sm) {
                FlowLayout(spacing: DS.Spacing.xs) {
                    pomodoroBadge("\(workMin)\u{00A0}min work", icon: "brain.head.profile", color: skinAccent)
                    pomodoroBadge("\(breakMin)\u{00A0}min break", icon: "cup.and.saucer", color: skin.resolvedSuccessColor)
                    if rule.pomodoroLongBreak > 0 {
                        pomodoroBadge("\(rule.pomodoroLongBreak)\u{00A0}min long break", icon: "moon.zzz", color: DS.Colors.info)
                    }
                }
            }
            .padding(.horizontal, DS.Spacing.md)
            .padding(.vertical, DS.Spacing.sm)
            .frame(maxWidth: .infinity, alignment: .leading)
        }

        if rule.frequency == .weekly && !rule.weekdays.isEmpty {
            FormDivider()
            HStack(spacing: DS.Spacing.xs) {
                ForEach(Weekday.allCases.filter { rule.weekdays.contains($0) }, id: \.self) { day in
                    Text(day.shortName)
                        .font(.caption2)
                        .padding(.horizontal, DS.Spacing.md)
                        .padding(.vertical, DS.Spacing.xs)
                        .background(skinAccent.opacity(DS.Opacity.mediumFill))
                        .clipShape(Capsule())
                        .accessibilityLabel(day.fullName)
                }
                Spacer()
            }
            .padding(.horizontal, DS.Spacing.md)
            .padding(.vertical, DS.Spacing.sm)
        }
    }

    // MARK: - Reminders Row

    private func remindersRow(_ reminders: [Int]) -> some View {
        FormRow(
            icon: "bell.fill",
            iconTint: skin.resolvedWarningColor,
            title: "Reminders",
            trailing: {
                HStack(spacing: DS.Spacing.xs) {
                    ForEach(reminders.sorted().prefix(3), id: \.self) { min in
                        Text(DS.formatMinutes(min))
                            .font(.caption)
                            .padding(.horizontal, DS.Spacing.sm)
                            .padding(.vertical, 2)
                            .adaptiveBadgeFill(skin.resolvedTextSecondary)
                            .clipShape(Capsule())
                    }
                    if reminders.count > 3 {
                        Text("+\(reminders.count - 3)")
                            .font(.caption2)
                            .foregroundStyle(skin.resolvedTextTertiary)
                    }
                }
            }
        )
    }
}
