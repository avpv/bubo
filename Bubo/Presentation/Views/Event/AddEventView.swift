import SwiftUI
import AppKit
import BuboDomain
import BuboOptimizer

struct AddEventView: View {
    /// Cross-cutting #4: when non-nil and `editingEvent == nil`, prefill
    /// the form from this event's shape (title, duration, location,
    /// reminders, color, Pomodoro config). Treated as a brand-new draft
    /// — saving creates a fresh event, not an edit. Distinct from
    /// `editingEvent` so the save path knows to insert rather than
    /// update.
    var prefillFromEvent: CalendarEvent? = nil
    var reminderService: ReminderService
    var editingEvent: CalendarEvent? = nil
    var initialEventType: EventType = .standard
    var onDismiss: () -> Void
    var onSave: (_ isEdit: Bool) -> Void

    @Environment(\.activeSkin) var skin
    @Environment(\.accessibilityReduceMotion) var reduceMotion

    private var skinAccent: Color {
        skin.isClassic ? DS.Colors.accent : skin.accentColor
    }

    @State var title = ""
    @State var date = Date()
    @State var duration: Double = 30
    @State var location = ""
    @State var description = ""
    @State var useCustomReminders = false
    @State var reminderMinutes: [Int] = [5]
    @State var newReminderValue = 10
    @State var recurrenceRule: RecurrenceRule? = nil
    @State var selectedEventType: EventType = .standard
    @State var addToCalendar = false
    @State var selectedColorTag: EventColorTag? = nil
    @State var contextTag = ""
    @State var showMoreOptions = false

    // MARK: - Pomodoro state

    @State var pomodoroWork: Int = 25
    @State var pomodoroBreak: Int = 5
    @State var pomodoroRounds: Int = 4
    @State var pomodoroLongBreak: Int = 15
    @State var pomodoroLongBreakEnabled: Bool = false
    @State var availableCalendars: [AppleCalendarService.CalendarInfo] = []
    @State var selectedCalendarId: String = ""

    @FocusState var isTitleFocused: Bool
    @FocusState var isLocationFocused: Bool

    private static let presetReminders = [1, 2, 3, 5, 10, 15, 20, 30, 45, 60]

    private var isEditing: Bool { editingEvent != nil }
    private var isExternal: Bool { editingEvent?.isLocalEvent == false }

    /// True when the editor is open on a recurring event — either the
    /// base of a local series (`recurrenceRule` set) or an external
    /// occurrence whose EKEvent has recurrence rules (`seriesId` set).
    /// Drives the "applies to every occurrence" hint shown next to the
    /// color and context fields, since both halves of the editor write
    /// at series scope for these events.
    private var isEditingRecurring: Bool {
        guard let event = editingEvent else { return false }
        return event.seriesId != nil || event.recurrenceRule != nil
    }

    private var isTitleValid: Bool {
        !title.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// HIG: Detect unsaved changes to warn before data loss.
    private var hasUnsavedChanges: Bool {
        !title.isEmpty || !location.isEmpty || !description.isEmpty
    }

    private var eventEndDate: Date {
        date.addingTimeInterval(duration * 60)
    }

    private var endDateBinding: Binding<Date> {
        Binding(
            get: { eventEndDate },
            set: { newEnd in
                let diff = newEnd.timeIntervalSince(date)
                guard diff >= 5 * 60 else { return }
                duration = diff / 60
            }
        )
    }

    /// Whether the Pomodoro mode is controlling the event duration.
    private var isPomodoroMode: Bool {
        selectedEventType == .pomodoro
    }

    /// Whether the event is long enough to fit at least one full Pomodoro
    /// work segment. Below this the toggle is hidden — Birman: don't offer
    /// users choices that don't make sense.
    private var isPomodorizable: Bool {
        Int(duration) >= PomodoroDefaults.minimumConvertibleMinutes
            || isPomodoroMode  // keep visible if already on, so user can disable
    }

    private var pomodoroCycleMinutes: Int {
        pomodoroWork + pomodoroBreak
    }

    private var pomodoroTotalMinutes: Int {
        let workTotal = pomodoroWork * pomodoroRounds
        let shortBreakTotal = pomodoroBreak * (pomodoroRounds - 1)
        let longBreak = pomodoroLongBreakEnabled ? pomodoroLongBreak : 0
        return workTotal + shortBreakTotal + longBreak
    }

    var settings: ReminderSettings? = nil
    var optimizerService: OptimizerService? = nil

    // MARK: - Find Best Time state
    @State var bestTimeSlots: [ScheduleScenario] = []
    @State var isFindingBestTime = false

    var body: some View {
        VStack(spacing: 0) {
            // HIG/Birman: Pomodoro is a *mode* of the same event, not a
            // separate kind of thing. The header reads as one consistent
            // object regardless of whether the toggle is on. The
            // "Pomodoro" badge in the section below already signals mode.
            PopoverHeader(
                title: isEditing ? "Edit Event" : "New Event",
                showBack: true,
                onBack: onDismiss
            )

            if let settings {
                WorldClockStripView(settings: settings)
                    .fixedSize(horizontal: false, vertical: true)
            }

            ScrollView {
                // Each logical section lives on its own platter. Spacing
                // between cards replaces the in-platter separators that used
                // to mark section boundaries. Separators now live only
                // WITHIN a section (e.g. between Location and Notes).
                VStack(alignment: .leading, spacing: DS.Spacing.md) {

                    // Title — focused state is signalled only by the system
                    // caret, no extra glow shadow.
                    sectionBlock {
                        TextField("Title", text: $title, prompt: Text("Meeting with Anna, Deep work, etc.").foregroundStyle(skin.resolvedTextSecondary))
                            .textFieldStyle(.plain)
                            .font(DS.Typography.headline(skin: skin))
                            .focused($isTitleFocused)
                            .defaultFocus($isTitleFocused, true)
                            .padding(DS.Spacing.md)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .disabled(isExternal)
                            .opacity(isExternal ? 0.6 : 1.0)
                    }

                    // Date & Time
                    sectionBlock {
                        VStack(alignment: .leading, spacing: DS.Spacing.sm) {
                            sectionLabel("Date & Time")

                            Grid(alignment: .leading, horizontalSpacing: DS.Spacing.sm, verticalSpacing: DS.Spacing.md) {
                                GridRow {
                                    Text("Starts")
                                        .foregroundStyle(skin.resolvedTextSecondary)
                                        .gridColumnAlignment(.trailing)

                                    DateTimePickerPills(date: $date)
                                }

                                if selectedEventType != .pomodoro {
                                    GridRow {
                                        Text("Ends")
                                            .foregroundStyle(skin.resolvedTextSecondary)
                                            .gridColumnAlignment(.trailing)

                                        DateTimePickerPills(date: endDateBinding, range: date...)
                                    }
                                }
                            }
                        }
                        .padding(DS.Spacing.md)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .disabled(isExternal)
                        .opacity(isExternal ? 0.6 : 1.0)
                    }

                    // Find Best Time (optimizer suggestion)
                    if !isEditing, !isExternal, isTitleValid, let optimizerService {
                        sectionBlock {
                            findBestTimeSection(optimizerService)
                                .padding(DS.Spacing.md)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }

                    // Birman/HIG: Pomodoro is a mode, not a type. The toggle
                    // and its parameters are one visual group with no
                    // separator between them: separators live BETWEEN
                    // sections, not INSIDE. The toggle hides for short
                    // events (< one work segment) — for a 5-minute meeting,
                    // suggesting «Run as Pomodoro» is just noise.
                    if !isExternal, isPomodorizable {
                        sectionBlock {
                            VStack(alignment: .leading, spacing: DS.Spacing.md) {
                                pomodoroToggleRow
                                if isPomodoroMode {
                                    pomodoroSection
                                        .disabled(isExternal)
                                        .opacity(isExternal ? 0.6 : 1.0)
                                        .transition(.opacity.combined(with: .move(edge: .top)))
                                }
                            }
                            .padding(DS.Spacing.md)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }

                    // Calendar
                    if !isEditing {
                        sectionBlock {
                            VStack(alignment: .leading, spacing: DS.Spacing.sm) {
                                Toggle("Add to Calendar", isOn: $addToCalendar)

                                if addToCalendar && !availableCalendars.isEmpty {
                                    Picker("Calendar", selection: $selectedCalendarId) {
                                        ForEach(availableCalendars) { cal in
                                            Text(cal.title)
                                                .tag(cal.id)
                                        }
                                    }
                                    .pickerStyle(.menu)
                                    .controlSize(.large)
                                    .frame(height: DS.Size.controlHeight)
                                }

                                if !addToCalendar {
                                    Text("Event will be stored locally in Bubo only")
                                        .font(.footnote)
                                        .foregroundStyle(skin.resolvedTextSecondary)
                                }
                            }
                            .padding(DS.Spacing.md)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }

                    // More options — collapsed by default for new events
                    if !isExternal {
                        sectionBlock {
                            Button {
                                withAnimation(skin.resolvedMicroAnimation) {
                                    showMoreOptions.toggle()
                                }
                            } label: {
                                HStack(spacing: DS.Spacing.xs) {
                                    Text("More options")
                                        .font(.footnote.weight(.medium))
                                        .foregroundStyle(skinAccent)
                                    Image(systemName: showMoreOptions ? "chevron.up" : "chevron.down")
                                        .font(.footnote)
                                        .foregroundStyle(skinAccent)
                                    Spacer()
                                }
                            }
                            .buttonStyle(.plain)
                            .padding(DS.Spacing.md)
                        }
                    }

                    if showMoreOptions || isExternal {
                        // Color — editable for both local and external events.
                        // External overrides ride alongside the EventKit row
                        // via `EventAttributeOverrideStore` and survive sync.
                        sectionBlock {
                            VStack(alignment: .leading, spacing: DS.Spacing.sm) {
                                sectionLabel("Color")

                                HStack(spacing: DS.Spacing.xs) {
                                    ForEach(EventColorTag.allCases, id: \.self) { tag in
                                        ColorDotButton(
                                            tag: tag,
                                            isActive: selectedColorTag == tag,
                                            action: {
                                                Haptics.tap()
                                                selectedColorTag = selectedColorTag == tag ? nil : tag
                                            }
                                        )
                                    }
                                }
                            }
                            .padding(DS.Spacing.md)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }

                        // Context (Project / Category) — same dual-source story
                        // as Color above.
                        sectionBlock {
                            VStack(alignment: .leading, spacing: DS.Spacing.sm) {
                                sectionLabel("Context")

                                TextField("Project or category", text: $contextTag, prompt: Text("e.g. backend, design, personal").foregroundStyle(skin.resolvedTextSecondary))
                                    .textFieldStyle(.plain)

                                if isEditingRecurring {
                                    Text("Color and context apply to every occurrence in the series.")
                                        .font(.footnote)
                                        .foregroundStyle(skin.resolvedTextSecondary)
                                }
                            }
                            .padding(DS.Spacing.md)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }

                        // Details
                        sectionBlock {
                            VStack(alignment: .leading, spacing: DS.Spacing.sm) {
                                sectionLabel("Details")

                                TextField("Location", text: $location, prompt: Text("Zoom link or room 302").foregroundStyle(skin.resolvedTextSecondary))
                                    .textFieldStyle(.plain)
                                    .focused($isLocationFocused)

                                SkinSeparator()

                                HStack(alignment: .top, spacing: DS.Spacing.sm) {
                                    FormattableTextView(text: $description, prompt: "Add notes, agenda, or attachments", promptStyle: skin.resolvedTextSecondary)
                                        .frame(minHeight: 60, maxHeight: 160)

                                    EmojiPickerButton(text: $description)
                                        .padding(.top, DS.Spacing.xxs)
                                }
                            }
                            .padding(DS.Spacing.md)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .disabled(isExternal)
                            .opacity(isExternal ? 0.6 : 1.0)
                        }

                        // Recurrence (only for standard events)
                        if !isPomodoroMode {
                            sectionBlock {
                                RecurrencePickerView(rule: $recurrenceRule, eventDuration: $duration, eventStartDate: date)
                                    .padding(DS.Spacing.md)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .disabled(isExternal)
                                    .opacity(isExternal ? 0.6 : 1.0)
                            }
                        }

                        // Reminders
                        sectionBlock {
                            VStack(alignment: .leading, spacing: DS.Spacing.sm) {
                                sectionLabel("Reminders")

                                Toggle("Custom reminders", isOn: $useCustomReminders)

                                if useCustomReminders {
                                    ForEach(Array(reminderMinutes.sorted().enumerated()), id: \.element) { index, minutes in
                                        HStack {
                                            Label(DS.formatMinutes(minutes), systemImage: "bell.fill")
                                            Spacer()
                                            Button(role: .destructive) {
                                                reminderMinutes.removeAll { $0 == minutes }
                                            } label: {
                                                Image(systemName: "trash")
                                            }
                                            .buttonStyle(.borderless)
                                        }
                                        SkinSeparator()
                                    }

                                    Grid(alignment: .leading, horizontalSpacing: DS.Spacing.sm) {
                                        GridRow {
                                            Text("\(DS.formatMinutes(newReminderValue))")
                                                .frame(minWidth: 60, alignment: .leading)
                                                .monospacedDigit()

                                            Stepper("Reminder minutes", value: $newReminderValue, in: 1...120)
                                                .labelsHidden()

                                            Button {
                                                if !reminderMinutes.contains(newReminderValue) {
                                                    reminderMinutes.append(newReminderValue)
                                                }
                                            } label: {
                                                Label("Add", systemImage: "plus")
                                            }
                                            .buttonStyle(.action(role: .primary, size: .compact))
                                        }
                                    }

                                    let available = Self.presetReminders.filter { !reminderMinutes.contains($0) }
                                    if !available.isEmpty {
                                        HStack(spacing: DS.Spacing.xs) {
                                            ForEach(available.prefix(5), id: \.self) { preset in
                                                Button {
                                                    Haptics.tap()
                                                    reminderMinutes.append(preset)
                                                } label: {
                                                    Text(DS.formatMinutes(preset))
                                                        .font(.footnote)
                                                }
                                                .buttonStyle(.action(role: .secondary, size: .compact))
                                            }
                                        }
                                    }
                                } else {
                                    Label(
                                            "Default: \(reminderService.defaultReminderMinutesList.map { DS.formatMinutes($0) }.joined(separator: ", "))",
                                            systemImage: "bell.fill"
                                        )
                                        .font(.subheadline)
                                        .foregroundStyle(skin.resolvedTextSecondary)
                                }
                            }
                            .padding(DS.Spacing.md)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    } // end showMoreOptions
                }
                .padding(.horizontal, DS.Spacing.lg)
                .padding(.vertical, DS.Spacing.lg)
            }
            .scrollContentBackground(.hidden)
            .frame(maxHeight: .infinity)
            .onChange(of: selectedEventType) {
                // Clear standard recurrence when switching to Pomodoro
                if selectedEventType == .pomodoro {
                    recurrenceRule = nil
                    // Auto-suggest best pomodoro slot
                    if let optimizerService, !isEditing {
                        autoSuggestPomodoroSlot(optimizerService)
                    }
                }
            }

            SkinSeparator()

            HStack {
                Spacer()
                Button(action: {
                    // Save draft for recovery on next open, then dismiss without confirmation
                    if hasUnsavedChanges && !isEditing {
                        saveDraft()
                    }
                    onDismiss()
                }) {
                    Text("Cancel")
                }
                .keyboardShortcut(.cancelAction)
                .buttonStyle(.action(role: .secondary))

                Button(action: {
                    clearDraft()
                    saveEvent()
                }) {
                    Label(isEditing ? "Save" : "Add Event", systemImage: isEditing ? "checkmark.circle" : "calendar.badge.plus")
                }
                .buttonStyle(.action(role: .primary))
                .keyboardShortcut(.defaultAction)
                .disabled(!isTitleValid)
            }
            .padding(.horizontal, DS.Spacing.lg)
            .frame(height: DS.Size.actionFooterHeight)
            .skinBarBackground(skin)
        }
        .frame(width: DS.Popover.width, height: DS.Popover.height)
        .onAppear {
            availableCalendars = AppleCalendarService.shared.listCalendars()
            selectedCalendarId = AppleCalendarService.shared.defaultCalendarId ?? availableCalendars.first?.id ?? ""
            reminderMinutes = reminderService.defaultReminderMinutesList
            if let event = editingEvent {
                showMoreOptions = true  // Show all fields when editing
                title = event.title
                date = event.startDate
                duration = event.endDate.timeIntervalSince(event.startDate) / 60
                location = event.location ?? ""
                description = event.description ?? ""
                if let custom = event.customReminderMinutes, !custom.isEmpty {
                    useCustomReminders = true
                    reminderMinutes = custom
                }
                recurrenceRule = event.recurrenceRule
                selectedEventType = event.eventType
                selectedColorTag = event.colorTag
                contextTag = event.context ?? ""
                // Load Pomodoro parameters when editing a Pomodoro event
                if event.eventType == .pomodoro, let rule = event.recurrenceRule, rule.pomodoroMode {
                    if case .afterCount(let rounds) = rule.end {
                        pomodoroRounds = rounds
                    }
                    pomodoroWork = max(Int(duration), 5)
                    pomodoroBreak = max(rule.interval - Int(duration), 1)
                    if rule.pomodoroLongBreak > 0 {
                        pomodoroLongBreakEnabled = true
                        pomodoroLongBreak = rule.pomodoroLongBreak
                    }
                }
            } else if let source = prefillFromEvent {
                // Cross-cutting #4: «Repeat from this event…» path.
                // Inherit shape, drop identity. Same shape-handling as
                // the editing branch above, minus the id/series/state
                // we deliberately reset in `cloneAsDraft(_:)` upstream.
                showMoreOptions = true
                title = source.title
                date = source.startDate
                duration = source.endDate.timeIntervalSince(source.startDate) / 60
                location = source.location ?? ""
                description = source.description ?? ""
                if let custom = source.customReminderMinutes, !custom.isEmpty {
                    useCustomReminders = true
                    reminderMinutes = custom
                }
                recurrenceRule = nil
                selectedEventType = source.eventType
                selectedColorTag = source.colorTag
                contextTag = source.context ?? ""
                if source.eventType == .pomodoro, let rule = source.recurrenceRule, rule.pomodoroMode {
                    if case .afterCount(let rounds) = rule.end {
                        pomodoroRounds = rounds
                    }
                    pomodoroWork = max(Int(duration), 5)
                    pomodoroBreak = max(rule.interval - Int(duration), 1)
                    if rule.pomodoroLongBreak > 0 {
                        pomodoroLongBreakEnabled = true
                        pomodoroLongBreak = rule.pomodoroLongBreak
                    }
                }
            } else {
                let now = Date()
                let cal = Calendar.current
                var comps = cal.dateComponents([.year, .month, .day, .hour, .minute], from: now)
                let currentMins = comps.minute ?? 0
                comps.minute = currentMins + (30 - (currentMins % 30))
                date = cal.date(from: comps) ?? now
                selectedEventType = initialEventType
                loadDraft()
                clearDraft()
            }
            // Focus title field after brief delay for popover to settle
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(100))
                isTitleFocused = true
            }
        }
    }

    // MARK: - Section Label

    /// Delegates to the shared `SectionLabel` view defined in DesignSystem so
    /// every form surface uses the exact same treatment.
    private func sectionLabel(_ text: String) -> some View {
        SectionLabel(text: text)
    }

    // MARK: - Section Block

    /// Wraps a form section in its own platter card. The form is a vertical
    /// stack of these blocks with DS.Spacing.md between them.
    @ViewBuilder
    private func sectionBlock<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .skinPlatter(skin)
            .skinPlatterDepth(skin)
    }

    // MARK: - Draft Persistence

    private static let draftTitleKey = "bubo.draft.title"
    private static let draftLocationKey = "bubo.draft.location"
    private static let draftDescriptionKey = "bubo.draft.description"

    private func saveDraft() {
        UserDefaults.standard.set(title, forKey: Self.draftTitleKey)
        UserDefaults.standard.set(location, forKey: Self.draftLocationKey)
        UserDefaults.standard.set(description, forKey: Self.draftDescriptionKey)
    }

    private func clearDraft() {
        UserDefaults.standard.removeObject(forKey: Self.draftTitleKey)
        UserDefaults.standard.removeObject(forKey: Self.draftLocationKey)
        UserDefaults.standard.removeObject(forKey: Self.draftDescriptionKey)
    }

    private func loadDraft() {
        if let t = UserDefaults.standard.string(forKey: Self.draftTitleKey), !t.isEmpty {
            title = t
        }
        if let l = UserDefaults.standard.string(forKey: Self.draftLocationKey), !l.isEmpty {
            location = l
        }
        if let d = UserDefaults.standard.string(forKey: Self.draftDescriptionKey), !d.isEmpty {
            description = d
            showMoreOptions = true
        }
    }

    private func saveEvent() {
        if isExternal, let event = editingEvent {
            let minutes = useCustomReminders ? reminderMinutes.sorted() : nil
            reminderService.updateLocalReminder(for: event.id, minutes: minutes)
            reminderService.updateEventAttributes(
                for: event,
                colorTag: selectedColorTag,
                context: contextTag
            )
            Haptics.impact()
            onSave(true)
            return
        }

        // Build the appropriate recurrence rule
        let finalRule: RecurrenceRule? = isPomodoroMode ? buildPomodoroRule() : recurrenceRule

        // For Pomodoro, override duration to work session length
        let finalEnd = isPomodoroMode
            ? date.addingTimeInterval(Double(pomodoroWork) * 60)
            : eventEndDate

        var event = CalendarEvent(
            id: editingEvent?.id ?? UUID().uuidString,
            title: title,
            startDate: date,
            endDate: finalEnd,
            location: location.isEmpty ? nil : location,
            description: description.isEmpty ? nil : description,
            calendarName: addToCalendar ? nil : "Local",
            customReminderMinutes: useCustomReminders ? reminderMinutes.sorted() : nil,
            recurrenceRule: finalRule,
            eventType: selectedEventType
        )
        event.colorTag = selectedColorTag
        event.context = contextTag.isEmpty ? nil : contextTag
        if isEditing {
            reminderService.updateLocalEvent(event)
        } else if addToCalendar {
            reminderService.addCalendarEvent(event, calendarId: selectedCalendarId)
        } else {
            reminderService.addLocalEvent(event)
        }
        // HIG: Confirm successful action with haptic feedback
        Haptics.impact()
        onSave(isEditing)

    }
}
