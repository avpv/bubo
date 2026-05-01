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
    /// Open the command palette seeded with this event (per-event scope
    /// optimizer entry — header overflow menu's «Reschedule…» item).
    var onReschedule: ((CalendarEvent) -> Void)? = nil
    /// Run the optimizer's «extend to adjacent free slot» preset for this
    /// event. Surfaces in the header overflow menu — disabled for read-only
    /// external events (the optimizer can't move them).
    var onExtend: ((CalendarEvent) -> Void)? = nil

    @State private var showDeleteConfirmation = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.activeSkin) private var skin

    private var skinAccent: Color {
        skin.isClassic ? DS.Colors.accent : skin.accentColor
    }

    private func pomodoroBadge(_ text: String, icon: String, color: Color) -> some View {
        Label(text, systemImage: icon)
            .font(.footnote)
            .padding(.horizontal, DS.Spacing.md)
            .padding(.vertical, DS.Spacing.xs)
            .adaptiveBadgeFill(color)
            .clipShape(Capsule())
    }

    private var isLocal: Bool {
        event.isLocalEvent
    }

    /// Header overflow menu hosting optimizer-driven actions (Reschedule,
    /// Extend). Lives in the trailing slot of `PopoverHeader` so the footer
    /// can keep just two explicit affordances — Edit and Delete. Returns
    /// `nil` when neither callback is wired so the header stays balanced.
    /// Styling is left to the active skin — match the back button pattern
    /// (.borderless) so the icon picks up skin foreground/tint via env.
    private var optimizerOverflowMenu: AnyView? {
        guard onReschedule != nil || onExtend != nil else { return nil }
        let menu = Menu {
            if onReschedule != nil {
                Button {
                    Haptics.tap()
                    onReschedule?(event)
                } label: {
                    Label("Reschedule\u{2026}", systemImage: "calendar.badge.clock")
                }
            }
            if onExtend != nil {
                Button {
                    Haptics.tap()
                    onExtend?(event)
                } label: {
                    Label("Extend to next free slot", systemImage: "arrow.right.to.line")
                }
                .disabled(!isLocal)
            }
        } label: {
            Label("More actions", systemImage: "ellipsis.circle")
                .labelStyle(.iconOnly)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("More actions")
        return AnyView(menu)
    }

    var body: some View {
        // HIG: Use TimelineView for time-based UI updates instead of Timer.publish
        TimelineView(.periodic(from: .now, by: 1)) { context in
        let now = context.date
        VStack(spacing: 0) {
            PopoverHeader(
                title: isLocal ? (event.eventType == .pomodoro ? "Pomodoro" : "Event") : nil,
                showBack: true,
                onBack: onBack,
                trailing: optimizerOverflowMenu
            )

            ScrollView {
                VStack(alignment: .leading, spacing: DS.Spacing.xl) {
                    // Title
                    HStack(spacing: DS.Spacing.sm) {
                        Text(event.title)
                            .font(.system(.title2, design: skin.resolvedFontDesign, weight: .bold))
                            .accessibilityAddTraits(.isHeader)

                        if event.isRecurring {
                            Image(systemName: "repeat")
                                .font(.system(size: DS.Size.iconMedium, weight: .medium))
                                .foregroundStyle(skin.resolvedTextSecondary)
                                .contentTransition(.symbolEffect(.replace))
                                .help("Recurring event")
                                .accessibilityLabel("Recurring event")
                        }
                    }

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

                        // Meeting link — prominent Join button
                        if let meetingURL = event.meetingLink, let serviceName = event.meetingServiceName {
                            Button {
                                Haptics.tap()
                                NSWorkspace.shared.open(meetingURL)
                            } label: {
                                Label("Join \(serviceName)", systemImage: "video.fill")
                                    .font(.subheadline)
                                    .fontWeight(skin.resolvedHeadlineFontWeight)
                                    .foregroundStyle(DS.contrastingForeground(for: skinAccent))
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
                        }

                        // Location
                        if let location = event.location, !location.isEmpty {
                            Label(location, systemImage: "location.fill")
                                .font(.subheadline)
                                .foregroundStyle(skin.resolvedTextSecondary)
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
                                .font(.footnote)
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
                    }

                    // Calendar name
                    if let calName = event.calendarName {
                        Label(calName, systemImage: "tray.full")
                            .font(.footnote)
                            .foregroundStyle(DS.Colors.calendarLabel)
                    }

                    // Recurrence / Pomodoro info
                    if let rule = event.recurrenceRule {
                        recurrenceSection(rule)
                    } else if event.eventType == .pomodoro {
                        Label("Pomodoro", systemImage: "timer")
                            .font(.footnote)
                            .fontWeight(.medium)
                            .foregroundStyle(skin.resolvedTextTertiary)
                    }

                    // Active Reminders (Default + Custom)
                    let activeReminders = reminderService.activeReminderMinutes(for: event)
                    if !activeReminders.isEmpty {
                        remindersSection(activeReminders)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(DS.Spacing.xl)
            }
            .frame(maxHeight: .infinity)

            Spacer(minLength: 0)

            // Actions (only for local events)
            SkinSeparator()

            // Two explicit footer buttons: Delete (destructive) and Edit
            // (primary). Optimizer paths (Reschedule / Extend) live in the
            // command palette — they don't belong on a per-event detail
            // screen where the user expects basic edit affordances.
            HStack(spacing: DS.Spacing.sm) {
                Spacer()

                if isLocal {
                    Button(role: .destructive) {
                        Haptics.impact()
                        if event.isRecurring {
                            showDeleteConfirmation = true
                        } else {
                            onDelete?(event)
                        }
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                    .buttonStyle(.action(role: .destructive))

                    Button {
                        Haptics.tap()
                        onEdit?(event)
                    } label: {
                        Label("Edit", systemImage: "pencil")
                    }
                    .buttonStyle(.action(role: .primary))
                    .keyboardShortcut(.defaultAction)
                }
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
                    .font(.footnote)
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
                .font(.system(.footnote, design: .monospaced))
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
            .font(.footnote)
            .fontWeight(.medium)
            .foregroundStyle(skin.resolvedTextTertiary)

            Text(rule.displayText)
                .font(.subheadline)
                .foregroundStyle(skin.resolvedTextSecondary)

            if event.eventType == .pomodoro {
                let workMin = Int(event.endDate.timeIntervalSince(event.startDate) / 60)
                let breakMin = max(rule.interval - workMin, 0)
                FlowLayout(spacing: DS.Spacing.xs) {
                    pomodoroBadge("\(workMin)\u{00A0}min work", icon: "brain.head.profile", color: skinAccent)
                    pomodoroBadge("\(breakMin)\u{00A0}min break", icon: "cup.and.saucer", color: skin.resolvedSuccessColor)
                    if rule.pomodoroLongBreak > 0 {
                        pomodoroBadge("\(rule.pomodoroLongBreak)\u{00A0}min long break", icon: "moon.zzz", color: DS.Colors.info)
                    }
                }
            }

            if rule.frequency == .weekly && !rule.weekdays.isEmpty {
                HStack(spacing: DS.Spacing.xs) {
                    ForEach(Weekday.allCases.filter { rule.weekdays.contains($0) }, id: \.self) { day in
                        Text(day.shortName)
                            .font(.footnote)
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
                .font(.footnote)
                .fontWeight(.medium)
                .foregroundStyle(skin.resolvedTextTertiary)

            HStack(spacing: DS.Spacing.xs) {
                ForEach(reminders.sorted(), id: \.self) { min in
                    Text(DS.formatMinutes(min))
                        .font(.footnote)
                        .padding(.horizontal, DS.Spacing.md)
                        .padding(.vertical, DS.Spacing.xs)
                        .adaptiveBadgeFill(skin.resolvedTextSecondary)
                        .clipShape(Capsule())
                }
            }
        }
    }
}
