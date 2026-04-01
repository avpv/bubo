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
                VStack(alignment: .leading, spacing: DS.Spacing.xl) {
                    // Title
                    HStack(spacing: DS.Spacing.sm) {
                        Text(event.title)
                            .font(.system(.title2, design: .rounded, weight: .bold))
                            .accessibilityAddTraits(.isHeader)

                        if event.isRecurring {
                            Image(systemName: "repeat")
                                .font(.system(size: DS.Size.iconMedium, weight: .medium))
                                .foregroundStyle(skin.resolvedTextSecondary)
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
                                .foregroundStyle(skin.resolvedTextSecondary)
                                .accessibilityLabel("Date: \(event.formattedDate)")

                            Label(event.formattedTimeRange, systemImage: "clock")
                                .font(.subheadline)
                                .foregroundStyle(skin.resolvedTextSecondary)
                                .accessibilityLabel("Time: \(event.formattedTimeRange)")
                        }
                        .staggeredEntrance(index: 1)

                        // Live countdown with seconds — tap to open timer screen
                        Button {
                            Haptics.tap()
                            onTimer?(event)
                        } label: {
                            countdownSection(now: now)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .staggeredEntrance(index: 2)

                        // Meeting link — prominent Join button
                        if let meetingURL = event.meetingLink, let serviceName = event.meetingServiceName {
                            Button {
                                Haptics.tap()
                                NSWorkspace.shared.open(meetingURL)
                            } label: {
                                Label("Join \(serviceName)", systemImage: "video.fill")
                                    .font(.subheadline)
                                    .fontWeight(.semibold)
                                    .foregroundStyle(DS.Colors.onOverlay)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, DS.Spacing.sm)
                                    .background(
                                        LinearGradient(
                                            colors: [skinAccent, skin.resolvedSecondaryAccent],
                                            startPoint: .leading,
                                            endPoint: .trailing
                                        )
                                    )
                                    .clipShape(RoundedRectangle(cornerRadius: DS.Size.cornerRadius, style: .continuous))
                            }
                            .buttonStyle(.plain)
                            .staggeredEntrance(index: 3)
                        }

                        // Location
                        if let location = event.location, !location.isEmpty {
                            Label(location, systemImage: "location.fill")
                                .font(.subheadline)
                                .foregroundStyle(skin.resolvedTextSecondary)
                                .staggeredEntrance(index: 3)
                        }
                    }
                    .padding(DS.Spacing.lg)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .skinPlatter(skin)
                    .skinPlatterDepth(skin)

                    // Description
                    if let description = event.description, !description.isEmpty {
                        VStack(alignment: .leading, spacing: DS.Spacing.sm) {
                            Label("Notes", systemImage: "note.text")
                                .font(.caption)
                                .fontWeight(.medium)
                                .foregroundStyle(skin.resolvedTextTertiary)
                            MarkdownText(text: description)
                                .font(.subheadline)
                                .foregroundStyle(skin.resolvedTextSecondary)
                                .lineSpacing(DS.Typography.bodyLineSpacing)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .padding(DS.Spacing.lg)
                        .skinPlatter(skin)
                        .skinPlatterDepth(skin)
                        .staggeredEntrance(index: 3)
                    }

                    // Calendar name
                    if let calName = event.calendarName {
                        Label(calName, systemImage: "tray.full")
                            .font(.caption)
                            .foregroundStyle(DS.Colors.calendarLabel)
                            .staggeredEntrance(index: 4)
                    }

                    // Recurrence / Pomodoro info
                    if let rule = event.recurrenceRule {
                        recurrenceSection(rule)
                            .staggeredEntrance(index: 5)
                    } else if event.eventType == .pomodoro {
                        Label("Pomodoro", systemImage: "timer")
                            .font(.caption)
                            .fontWeight(.medium)
                            .foregroundStyle(skin.resolvedTextTertiary)
                            .staggeredEntrance(index: 5)
                    }

                    // Active Reminders (Default + Custom)
                    let activeReminders = reminderService.activeReminderMinutes(for: event)
                    if !activeReminders.isEmpty {
                        remindersSection(activeReminders)
                            .staggeredEntrance(index: 6)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(DS.Spacing.xl)
            }
            .frame(maxHeight: .infinity)

            Spacer(minLength: 0)

            // Actions (only for local events)
            SkinSeparator()

            HStack {
                if isLocal {
                    Button(role: .destructive) {
                        Haptics.impact()
                        showDeleteConfirmation = true
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                    .buttonStyle(.action(role: .destructive))
                }

                Spacer()

                Button {
                    Haptics.tap()
                    onEdit?(event)
                } label: {
                    Label("Edit", systemImage: "pencil")
                }
                .buttonStyle(.action(role: .primary))
            }
            .padding(.horizontal, DS.Spacing.lg)
            .frame(height: DS.Size.actionFooterHeight)
            .skinBarBackground(skin)
            // HIG: Use confirmationDialog for destructive actions
            .confirmationDialog(
                event.isRecurring ? "Delete Recurring Event" : "Delete Event",
                isPresented: $showDeleteConfirmation,
                titleVisibility: .visible
            ) {
                if event.isRecurring {
                    Button("Delete This Event Only", role: .destructive) {
                        Haptics.impact()
                        onDeleteOccurrence?(event)
                    }
                    Button("Delete All Events", role: .destructive) {
                        Haptics.impact()
                        onDeleteSeries?(event)
                    }
                } else {
                    Button("Delete", role: .destructive) {
                        Haptics.impact()
                        onDelete?(event)
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(event.isRecurring
                    ? "This event repeats. Do you want to delete just this occurrence or all events in the series?"
                    : "Are you sure you want to delete \u{201C}\(event.title)\u{201D}?")
            }
        }
        .frame(width: DS.Popover.width, height: DS.Popover.height)
        } // TimelineView
    }

    // MARK: - Countdown Section

    @ViewBuilder
    private func countdownSection(now: Date) -> some View {
        let secondsUntilStart = Int(event.startDate.timeIntervalSince(now))
        let secondsUntilEnd = Int(event.endDate.timeIntervalSince(now))

        if secondsUntilStart > 0 {
            // Event hasn't started yet
            countdownDisplay(
                label: "Starts in",
                totalSeconds: secondsUntilStart,
                color: DS.urgencyColor(minutesUntil: secondsUntilStart / 60, skin: skin)
            )
        } else if secondsUntilEnd > 0 {
            // Event is in progress
            countdownDisplay(
                label: "Ends in",
                totalSeconds: secondsUntilEnd,
                color: skinAccent
            )
        } else {
            // Event has ended
            Label("Ended", systemImage: "checkmark.circle")
                .font(.subheadline)
                .foregroundStyle(skin.resolvedTextTertiary)
        }
    }

    private func countdownDisplay(label: String, totalSeconds: Int, color: Color) -> some View {
        let days = totalSeconds / 86400
        let hours = (totalSeconds % 86400) / 3600
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60

        return HStack(spacing: DS.Spacing.md) {
            Image(systemName: "timer")
                .font(.system(size: DS.Size.iconMedium))
                .foregroundStyle(color)

            VStack(alignment: .leading, spacing: DS.Spacing.xxs) {
                Text(label)
                    .font(.caption2)
                    .foregroundStyle(skin.resolvedTextTertiary)

                HStack(spacing: DS.Spacing.xs) {
                    if days > 0 {
                        countdownUnit(value: days, unit: "d")
                    }
                    countdownUnit(value: hours, unit: "h")
                    countdownUnit(value: minutes, unit: "m")
                    countdownUnit(value: seconds, unit: "s")
                }
            }

            Spacer()

            Image(systemName: "chevron.right")
                .font(.system(size: DS.Size.iconSmall, weight: .semibold))
                .foregroundStyle(DS.Colors.textQuaternary)
        }
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

    // MARK: - Recurrence Section

    @ViewBuilder
    private func recurrenceSection(_ rule: RecurrenceRule) -> some View {
        VStack(alignment: .leading, spacing: DS.Spacing.sm) {
            Label(
                event.eventType == .pomodoro ? "Pomodoro" : "Repeats",
                systemImage: event.eventType == .pomodoro ? "timer" : "repeat"
            )
            .font(.caption)
            .fontWeight(.medium)
            .foregroundStyle(skin.resolvedTextTertiary)

            Text(rule.displayText)
                .font(.subheadline)
                .foregroundStyle(skin.resolvedTextSecondary)

            if event.eventType == .pomodoro {
                let workMin = Int(event.endDate.timeIntervalSince(event.startDate) / 60)
                let breakMin = max(rule.interval - workMin, 0)
                FlowLayout(spacing: DS.Spacing.xs) {
                    pomodoroBadge("\(workMin) min work", icon: "brain.head.profile", color: skinAccent)
                    pomodoroBadge("\(breakMin) min break", icon: "cup.and.saucer", color: skin.resolvedSuccessColor)
                    if rule.pomodoroLongBreak > 0 {
                        pomodoroBadge("\(rule.pomodoroLongBreak) min long break", icon: "moon.zzz", color: DS.Colors.info)
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
                            .background(skinAccent.opacity(DS.Opacity.mediumFill))
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
                .foregroundStyle(skin.resolvedTextTertiary)

            HStack(spacing: DS.Spacing.xs) {
                ForEach(reminders.sorted(), id: \.self) { min in
                    Text(DS.formatMinutes(min))
                        .font(.caption)
                        .padding(.horizontal, DS.Spacing.md)
                        .padding(.vertical, DS.Spacing.xs)
                        .adaptiveBadgeFill(skin.resolvedTextSecondary)
                        .clipShape(Capsule())
                }
            }
        }
    }
}
