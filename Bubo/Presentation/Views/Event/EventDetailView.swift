import SwiftUI
import BuboDomain

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

    /// J8: auto-expand the Prep scratchpad as the event approaches.
    /// 10-min window matches the existing reminder-default cadence. Past
    /// the start we keep it collapsed by default — the user is in the
    /// meeting, not preparing for it.
    private func prepShouldAutoExpand(now: Date) -> Bool {
        let secondsUntilStart = event.startDate.timeIntervalSince(now)
        return secondsUntilStart > 0 && secondsUntilStart <= 600
    }

    /// J7: surface the Focus-Filters tip for events the user is most
    /// likely to want to defend (Pomodoros + locally-titled focus blocks).
    /// External meetings already carry their own etiquette; we don't
    /// suggest engaging Do Not Disturb during someone else's stand-up.
    private var shouldShowFocusTip: Bool {
        guard isLocal else { return false }
        let isPomodoro = event.eventType == .pomodoro
        let titleSignalsFocus = event.title.localizedCaseInsensitiveContains("focus")
            || event.title.localizedCaseInsensitiveContains("deep work")
        return isPomodoro || titleSignalsFocus
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
                            .font(.system(.title2, design: skin.resolvedFontDesign, weight: .bold))
                            .accessibilityAddTraits(.isHeader)

                        if event.isRecurring {
                            Image(systemName: "repeat")
                                .font(.system(size: DS.Size.iconMedium, weight: .regular))
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

                            // Optimizer-driven time actions live inside the
                            // time platter — contextual home for «Reschedule»
                            // and «Extend» since both manipulate when the
                            // event lives, not what it is. Compact secondary
                            // buttons keep visual weight subordinate to the
                            // time facts they sit beneath.
                            if onReschedule != nil || (onExtend != nil && isLocal) {
                                HStack(spacing: DS.Spacing.sm) {
                                    if onReschedule != nil {
                                        Button {
                                            Haptics.tap()
                                            onReschedule?(event)
                                        } label: {
                                            Label("Reschedule", systemImage: "calendar.badge.clock")
                                        }
                                        .buttonStyle(.action(role: .secondary, size: .compact))
                                    }
                                    if onExtend != nil && isLocal {
                                        Button {
                                            Haptics.tap()
                                            onExtend?(event)
                                        } label: {
                                            Label("Extend", systemImage: "arrow.right.to.line")
                                        }
                                        .buttonStyle(.action(role: .secondary, size: .compact))
                                    }
                                }
                            }
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
                                // Solid accent — the same voice as every
                                // other primary CTA (PRINCIPLES §7). This
                                // was the app's one gradient button; the
                                // row-level Join is plain accent, and the
                                // louder treatment didn't make the verb
                                // more primary, just off-voice.
                                Label("Join \(serviceName)", systemImage: "video.fill")
                                    .font(.subheadline)
                                    .fontWeight(skin.resolvedHeadlineFontWeight)
                                    .foregroundStyle(DS.contrastingForeground(for: skinAccent))
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, DS.Spacing.sm)
                                    .background(skinAccent)
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
                                .fontWeight(.regular)
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

                    // J8: Prep — local-only markdown scratchpad keyed by
                    // event id. Round-trips through `EventPrepStore`
                    // (UserDefaults + iCloud KV mirror), so notes survive
                    // app restarts and propagate to other devices logged
                    // into the same iCloud account, but never touch the
                    // shared calendar — colleagues invited to the meeting
                    // see nothing. Auto-expanded when start is < 10 min
                    // away so the user gets a heads-up nudge.
                    PrepNotesSection(
                        eventId: event.id,
                        autoExpand: prepShouldAutoExpand(now: now)
                    )

                    // J7: macOS Focus tip — surfaced once per event id for
                    // local Pomodoro / Focus events that benefit from
                    // pairing with a system Focus filter. The system path
                    // is genuinely separate (Focus Filters / Intents
                    // entitlement), so we recommend rather than wire it
                    // automatically. Quiet, dismissible, never re-shows
                    // for the same event.
                    if shouldShowFocusTip {
                        FocusTipBanner(eventId: event.id)
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
                            .fontWeight(.regular)
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

            // Actions footer — local events only. External events have
            // no Delete/Edit verbs here, and an empty bar under a
            // hairline is exactly the «empty band renders nothing»
            // failure PRINCIPLES §2 forbids — so the whole band
            // (separator included) exists only when its verbs do.
            if isLocal {
                SkinSeparator()

                // Two explicit footer buttons: Delete (destructive) and Edit
                // (primary). Optimizer paths (Reschedule / Extend) live in the
                // command palette — they don't belong on a per-event detail
                // screen where the user expects basic edit affordances.
                HStack(spacing: DS.Spacing.sm) {
                    Spacer()

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
            .fontWeight(.regular)
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

    // MARK: - Prep Notes Section

    /// J8: per-event markdown scratchpad. Auto-expanded when start is
    /// less than 10 min away (passed in via `autoExpand`); otherwise
    /// stays collapsed behind a one-line summary so the detail view
    /// stays scannable at calmer moments.
    private struct PrepNotesSection: View {
        let eventId: String
        let autoExpand: Bool

        @Environment(\.activeSkin) private var skin
        @State private var draft: String = EventPrepStore.text(for: "")
        @State private var isExpanded: Bool = false
        @State private var hasLoaded: Bool = false
        @FocusState private var editorFocused: Bool

        var body: some View {
            VStack(alignment: .leading, spacing: DS.Spacing.sm) {
                Button {
                    Haptics.tap()
                    withAnimation(skin.resolvedMicroAnimation) {
                        isExpanded.toggle()
                    }
                    if isExpanded {
                        editorFocused = true
                    }
                } label: {
                    HStack(spacing: DS.Spacing.sm) {
                        Image(systemName: "square.and.pencil")
                            .font(.footnote)
                            .foregroundStyle(skin.resolvedTextTertiary)
                        Text("Prep")
                            .font(.footnote.weight(.regular))
                            .foregroundStyle(skin.resolvedTextTertiary)
                        if !draft.isEmpty {
                            Text("\u{00B7} private")
                                .font(DS.Typography.machineHint)
                                .foregroundStyle(skin.resolvedTextTertiary)
                        }
                        Spacer(minLength: DS.Spacing.sm)
                        Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: DS.Size.iconSmall, weight: .regular))
                            .foregroundStyle(skin.resolvedTextTertiary)
                            .contentTransition(.symbolEffect(.replace))
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isExpanded ? "Collapse prep notes" : "Expand prep notes")

                if isExpanded {
                    // Local-only label — explicit signal that the notes
                    // never leave the device chain. Same micro-typography
                    // as the «Event will be stored locally in Bubo only»
                    // line in AddEventView's local-event hint.
                    Text("Stored locally on your devices · not visible to invitees")
                        .font(DS.Typography.machineHint)
                        .foregroundStyle(skin.resolvedTextTertiary)

                    TextEditor(text: $draft)
                        .font(.subheadline)
                        .foregroundStyle(skin.resolvedTextPrimary)
                        .scrollContentBackground(.hidden)
                        .focused($editorFocused)
                        .frame(minHeight: 80, maxHeight: 200)
                        .padding(DS.Spacing.sm)
                        .background(
                            RoundedRectangle(cornerRadius: DS.Size.previewCardRadius, style: .continuous)
                                .fill(skin.resolvedTextTertiary.opacity(DS.Opacity.subtleFill))
                        )
                        .onChange(of: draft) { _, newValue in
                            // Skip the first onChange that fires when we
                            // load the saved draft into state; only user
                            // edits should hit the store.
                            guard hasLoaded else { return }
                            EventPrepStore.setText(newValue, for: eventId)
                        }
                } else if !draft.isEmpty {
                    // Collapsed preview — first non-empty line, truncated.
                    // Lets the user see a hint without expanding.
                    let preview = draft
                        .components(separatedBy: .newlines)
                        .first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) ?? ""
                    Text(preview)
                        .font(.subheadline)
                        .foregroundStyle(skin.resolvedTextSecondary)
                        .lineLimit(2)
                        .truncationMode(.tail)
                }
            }
            .padding(DS.Spacing.lg)
            .skinPlatter(skin)
            .skinPlatterDepth(skin)
            .onAppear {
                draft = EventPrepStore.text(for: eventId)
                isExpanded = autoExpand || !draft.isEmpty
                hasLoaded = true
            }
        }
    }

    // MARK: - Focus Tip

    /// J7: one-shot tip that nudges the user to pair this event with a
    /// macOS Focus Filter. Surfaced for local Pomodoros and titled
    /// «focus / deep work» blocks. Dismissed-per-event via UserDefaults
    /// so the same tip never re-appears for the same id.
    private struct FocusTipBanner: View {
        let eventId: String

        @Environment(\.activeSkin) private var skin
        @State private var isVisible: Bool = false

        private static let dismissedKey = "BuboFocusTipDismissedEventIds"

        var body: some View {
            Group {
                if isVisible {
                    HStack(alignment: .top, spacing: DS.Spacing.sm) {
                        Image(systemName: "moon.stars.fill")
                            .font(.subheadline)
                            .foregroundStyle(skin.accentColor)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Tip · pair with macOS Focus")
                                .font(.footnote.weight(.regular))
                                .foregroundStyle(skin.resolvedTextPrimary)
                            // Concrete instruction — the user can act on
                            // it without us reaching into Focus Filters
                            // through Intents (a separate entitlement).
                            Text("Control Center \u{2192} Focus \u{2192} Work to mute notifications during this block.")
                                .font(.footnote)
                                .foregroundStyle(skin.resolvedTextSecondary)
                        }
                        Spacer(minLength: DS.Spacing.sm)
                        Button {
                            Haptics.tap()
                            dismissPermanently()
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: DS.Size.iconSmall, weight: .regular))
                                .foregroundStyle(skin.resolvedTextTertiary)
                        }
                        .buttonStyle(.plain)
                        .help("Don't show this tip again for this event")
                        .accessibilityLabel("Dismiss tip")
                    }
                    .padding(DS.Spacing.md)
                    .skinPlatter(skin)
                    .transition(.opacity)
                }
            }
            .onAppear {
                let dismissed = Set(UserDefaults.standard.stringArray(forKey: Self.dismissedKey) ?? [])
                isVisible = !dismissed.contains(eventId)
            }
        }

        private func dismissPermanently() {
            var dismissed = Set(UserDefaults.standard.stringArray(forKey: Self.dismissedKey) ?? [])
            dismissed.insert(eventId)
            // Cap at 500 ids so the array doesn't grow unbounded for
            // long-lived users; we drop the oldest by intersecting with
            // a sorted prefix. Order isn't observable past membership,
            // so a deterministic-but-arbitrary trim is fine.
            if dismissed.count > 500 {
                dismissed = Set(dismissed.sorted().prefix(500))
            }
            UserDefaults.standard.set(Array(dismissed), forKey: Self.dismissedKey)
            withAnimation(skin.resolvedMicroAnimation) {
                isVisible = false
            }
        }
    }

    // MARK: - Reminders Section

    @ViewBuilder
    private func remindersSection(_ reminders: [Int]) -> some View {
        VStack(alignment: .leading, spacing: DS.Spacing.sm) {
            Label("Reminders", systemImage: "bell.fill")
                .font(.footnote)
                .fontWeight(.regular)
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
