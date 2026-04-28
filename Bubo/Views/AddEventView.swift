import SwiftUI
import AppKit

struct AddEventView: View {
    var reminderService: ReminderService
    var editingEvent: CalendarEvent? = nil
    var initialEventType: EventType = .standard
    var onDismiss: () -> Void
    var onSave: (_ isEdit: Bool) -> Void

    @Environment(\.activeSkin) private var skin
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var skinAccent: Color {
        skin.isClassic ? DS.Colors.accent : skin.accentColor
    }

    @State private var title = ""
    @State private var date = Date()
    @State private var duration: Double = 30
    @State private var location = ""
    @State private var description = ""
    @State private var useCustomReminders = false
    @State private var reminderMinutes: [Int] = [5]
    @State private var newReminderValue = 10
    @State private var recurrenceRule: RecurrenceRule? = nil
    @State private var selectedEventType: EventType = .standard
    @State private var addToCalendar = false
    @State private var selectedColorTag: EventColorTag? = nil
    @State private var contextTag = ""
    @State private var showMoreOptions = false

    // MARK: - Pomodoro state

    @State private var pomodoroWork: Int = 25
    @State private var pomodoroBreak: Int = 5
    @State private var pomodoroRounds: Int = 4
    @State private var pomodoroLongBreak: Int = 15
    @State private var pomodoroLongBreakEnabled: Bool = false
    @State private var availableCalendars: [AppleCalendarService.CalendarInfo] = []
    @State private var selectedCalendarId: String = ""

    @FocusState private var isTitleFocused: Bool
    @FocusState private var isLocationFocused: Bool

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
    @State private var bestTimeSlots: [ScheduleScenario] = []
    @State private var isFindingBestTime = false

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
                            .font(.headline)
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

                    // Birman/HIG: Pomodoro — режим, а не тип. Toggle и его
                    // параметры — одна visual group без разделителя между:
                    // разделители живут МЕЖДУ секциями, не ВНУТРИ. Toggle
                    // прячется на коротких событиях (< одного work-сегмента)
                    // — для встречи в 5 минут предложение «Run as Pomodoro»
                    // — это шум.
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

    // MARK: - Find Best Time

    private func findBestTimeSection(_ service: OptimizerService) -> some View {
        VStack(alignment: .leading, spacing: DS.Spacing.xs) {
            Button {
                Haptics.tap()
                findBestTime(service)
            } label: {
                HStack(spacing: DS.Spacing.xs) {
                    if isFindingBestTime {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: "wand.and.stars")
                            .font(.footnote)
                    }
                    Text("Find Best Time")
                        .font(.footnote.weight(.medium))
                }
                .foregroundStyle(skin.accentColor)
            }
            .buttonStyle(.plain)
            .disabled(isFindingBestTime)

            if !bestTimeSlots.isEmpty {
                VStack(spacing: DS.Spacing.xs) {
                    ForEach(Array(bestTimeSlots.prefix(3).enumerated()), id: \.offset) { index, scenario in
                        if let gene = scenario.genes.first {
                            Button {
                                Haptics.tap()
                                date = gene.startTime
                                bestTimeSlots = []
                            } label: {
                                HStack(spacing: DS.Spacing.sm) {
                                    if index == 0 {
                                        Image(systemName: "star.fill")
                                            .font(.footnote)
                                            .foregroundStyle(skin.accentColor)
                                    }
                                    Text(DS.timeFormatter.string(from: gene.startTime))
                                        .font(.footnote.weight(.medium).monospacedDigit())
                                        .foregroundStyle(skin.resolvedTextPrimary)
                                    Text("(\(Int(scenario.fitness * 100))%)")
                                        .font(.footnote)
                                        .foregroundStyle(skin.resolvedTextSecondary)
                                    Spacer()
                                }
                                .padding(.vertical, DS.Spacing.xs)
                                .padding(.horizontal, DS.Spacing.sm)
                                .background(
                                    index == 0
                                        ? AnyShapeStyle(skin.accentColor.opacity(0.08))
                                        : AnyShapeStyle(skin.resolvedPlatterMaterial.opacity(0.3))
                                )
                                .clipShape(RoundedRectangle(cornerRadius: DS.Size.previewSmallRadius))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
    }

    private func findBestTime(_ service: OptimizerService) {
        isFindingBestTime = true
        let eventDuration = isPomodoroMode ? TimeInterval(pomodoroTotalMinutes * 60) : duration * 60

        let request = OptimizationRequest(
            .createBlock(title: title, minutes: Int(eventDuration / 60), focus: isPomodoroMode),
            .findSlotsForBacklog,
            .horizon(.today), .speed(.quick), .scenarios(count: 3),
            name: "Find Best Time"
        )

        Task {
            let result = await service.executeRequest(request, reminderService: reminderService)
            isFindingBestTime = false
            if let optimizerResult = result.optimizerResult {
                bestTimeSlots = optimizerResult.scenarios
            }
        }
    }

    private func autoSuggestPomodoroSlot(_ service: OptimizerService) {
        isFindingBestTime = true

        let request = OptimizationRequest(
            .pomodoroSession,
            .findSlotsForBacklog,
            .horizon(.today), .speed(.quick), .scenarios(count: 3),
            name: "Pomodoro Slot"
        )

        Task {
            let result = await service.executeRequest(request, reminderService: reminderService)
            isFindingBestTime = false
            if let optimizerResult = result.optimizerResult {
                bestTimeSlots = optimizerResult.scenarios
                // Auto-set date to best slot
                if let bestGene = optimizerResult.scenarios.first?.genes.first {
                    date = bestGene.startTime
                }
            }
        }
    }

    // MARK: - Pomodoro Toggle (mode switch)

    /// Binding that flips `selectedEventType` between `.standard` and
    /// `.pomodoro`. Lives outside the body so SwiftUI doesn't recompute
    /// it for every render. HIG: a Toggle is the platform-correct control
    /// for "this event runs as a Pomodoro session" (boolean state).
    private var pomodoroBinding: Binding<Bool> {
        Binding(
            get: { selectedEventType == .pomodoro },
            set: { newValue in
                withAnimation(DS.Animation.motionAware(DS.Animation.standard, reduceMotion: reduceMotion)) {
                    selectedEventType = newValue ? .pomodoro : .standard
                }
            }
        )
    }

    private var pomodoroToggleRow: some View {
        Toggle(isOn: pomodoroBinding) {
            HStack(spacing: DS.Spacing.sm) {
                Image(systemName: "timer")
                    .font(.callout)
                    .foregroundStyle(isPomodoroMode ? skinAccent : skin.resolvedTextSecondary)
                    .frame(width: DS.Size.iconLarge)
                VStack(alignment: .leading, spacing: DS.Spacing.xxs) {
                    Text("Run as Pomodoro")
                        .font(.callout)
                        .foregroundStyle(skin.resolvedTextPrimary)
                    // Birman: подзаголовок объясняет, что произойдёт, без
                    // необходимости знать слово "Pomodoro" заранее.
                    Text("Split into focused work + break sessions")
                        .font(.footnote)
                        .foregroundStyle(skin.resolvedTextTertiary)
                }
            }
        }
        .toggleStyle(.switch)
        .controlSize(.small)
        .accessibilityHint("Splits this event into work and break intervals")
    }

    // MARK: - Pomodoro Section

    private var pomodoroSection: some View {
        // Birman: no sectionLabel("Pomodoro") here — the toggle row above
        // already says "Run as Pomodoro" with a timer icon. Three labels
        // for the same concept on one screen is two too many. The outer
        // VStack that used to host that label is also gone — its only
        // remaining child is the parameter stack below.
        VStack(alignment: .leading, spacing: DS.Spacing.md) {
            Grid(alignment: .leading, horizontalSpacing: DS.Spacing.md, verticalSpacing: DS.Spacing.sm) {
                GridRow {
                    Label("Work: \(pomodoroWork)\u{00A0}min", systemImage: "brain.head.profile")
                        .foregroundStyle(skin.resolvedTextPrimary)
                        .gridColumnAlignment(.leading)
                    Stepper("Work duration", value: $pomodoroWork, in: 1...90)
                        .labelsHidden()
                }

                GridRow {
                    Label("Rounds: \(pomodoroRounds)", systemImage: "arrow.trianglehead.2.counterclockwise")
                        .foregroundStyle(skin.resolvedTextPrimary)
                    Stepper("Number of rounds", value: $pomodoroRounds, in: 1...12)
                        .labelsHidden()
                }

                if pomodoroRounds > 1 {
                    GridRow {
                        Label("Break: \(pomodoroBreak)\u{00A0}min", systemImage: "cup.and.saucer")
                            .foregroundStyle(skin.resolvedTextPrimary)
                        Stepper("Break duration", value: $pomodoroBreak, in: 1...30)
                            .labelsHidden()
                    }

                    GridRow {
                        Toggle(isOn: $pomodoroLongBreakEnabled) {
                            Label("Long break", systemImage: "moon.zzz")
                                .foregroundStyle(skin.resolvedTextPrimary)
                        }
                        Color.clear
                    }

                    if pomodoroLongBreakEnabled {
                        GridRow {
                            Label("Duration: \(pomodoroLongBreak)\u{00A0}min", systemImage: "moon.zzz")
                                .foregroundStyle(skin.resolvedTextPrimary)
                                .padding(.leading, DS.Spacing.lg)
                            Stepper("Long break duration", value: $pomodoroLongBreak, in: 5...60, step: 5)
                                .labelsHidden()
                        }
                    }
                }
            }

            // Visual timeline
            pomodoroTimeline
                .padding(.vertical, DS.Spacing.md)
                .animation(skin.resolvedMicroAnimation, value: pomodoroWork)
                .animation(skin.resolvedMicroAnimation, value: pomodoroBreak)
                .animation(skin.resolvedMicroAnimation, value: pomodoroRounds)
                .animation(skin.resolvedMicroAnimation, value: pomodoroLongBreakEnabled)
                .animation(skin.resolvedMicroAnimation, value: pomodoroLongBreak)

            HStack {
                Label(
                    "Total: \(DS.formatMinutes(pomodoroTotalMinutes))",
                    systemImage: "clock"
                )
                .font(.footnote)
                .foregroundStyle(skin.resolvedTextSecondary)

                Spacer()

                Link("Learn about Pomodoro combinations", destination: URL(string: "https://github.com/avpv/bubo/blob/HEAD/docs/Pomodoro.md")!)
                    .font(.footnote)
                    .foregroundStyle(skin.accentColor)
                    .accessibilityHint("Opens in your web browser")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Pomodoro Timeline Preview

    /// Build the list of timeline segments with their start times.
    private var pomodoroSegments: [(type: String, minutes: Int, startOffset: Int)] {
        var segments: [(type: String, minutes: Int, startOffset: Int)] = []
        var offset = 0
        for round in 0..<pomodoroRounds {
            segments.append((type: "work", minutes: pomodoroWork, startOffset: offset))
            offset += pomodoroWork
            if round < pomodoroRounds - 1 {
                segments.append((type: "break", minutes: pomodoroBreak, startOffset: offset))
                offset += pomodoroBreak
            }
        }
        if pomodoroLongBreakEnabled && pomodoroLongBreak > 0 {
            segments.append((type: "long", minutes: pomodoroLongBreak, startOffset: offset))
        }
        return segments
    }

    // MARK: - Segment Styling Helpers

    private func segmentColor(for type: String) -> Color {
        switch type {
        case "work": skin.accentColor
        case "long": DS.Colors.info
        default: skin.resolvedSuccessColor
        }
    }

    private func segmentIcon(for type: String) -> String {
        switch type {
        case "work": "brain.head.profile"
        case "long": "moon.zzz"
        default: "cup.and.saucer"
        }
    }

    private func segmentLabel(for type: String) -> String {
        switch type {
        case "work": "Work"
        case "long": "Long break"
        default: "Break"
        }
    }

    // MARK: - Improved Timeline

    private var pomodoroTimeline: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.sm) {
            // Legend row (above bar for context)
            HStack(spacing: DS.Spacing.md) {
                legendItem(color: skin.accentColor, icon: "brain.head.profile", label: "Work")
                legendItem(color: skin.resolvedSuccessColor, icon: "cup.and.saucer", label: "Break")
                if pomodoroLongBreakEnabled {
                    legendItem(color: DS.Colors.info, icon: "moon.zzz", label: "Long break")
                }
                Spacer()
                // Work/break ratio
                let totalWork = pomodoroWork * pomodoroRounds
                let totalBreak = pomodoroTotalMinutes - totalWork
                if totalBreak > 0 {
                    Text("\(totalWork):\(totalBreak)")
                        .font(.system(.footnote, design: .monospaced, weight: .medium))
                        .foregroundStyle(skin.resolvedTextTertiary)
                    + Text(" work:rest")
                        .font(.footnote)
                        .foregroundStyle(skin.resolvedTextTertiary)
                }
            }

            // Bar visualization
            GeometryReader { geo in
                let totalWidth = geo.size.width
                let totalDuration = CGFloat(pomodoroTotalMinutes)
                HStack(spacing: 1.5) {
                    ForEach(Array(pomodoroSegments.enumerated()), id: \.offset) { idx, segment in
                        let rawWidth = totalWidth * CGFloat(segment.minutes) / totalDuration
                        let segWidth = max(rawWidth - 1.5, 4)
                        let color = segmentColor(for: segment.type)
                        let isFirst = idx == 0
                        let isLast = idx == pomodoroSegments.count - 1

                        RoundedRectangle(
                            cornerRadius: (isFirst || isLast) ? max(DS.Size.cornerRadius - 3, 3) : max(DS.Size.cornerRadius - 5, 2),
                            style: .continuous
                        )
                        .fill(
                            LinearGradient(
                                colors: [color, color.opacity(DS.Opacity.accentMuted)],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                        .frame(width: segWidth)
                        .overlay {
                            if segWidth > 30 {
                                Text("\(segment.minutes)\u{00A0}m")
                                    .font(.system(.footnote, design: skin.resolvedFontDesign, weight: .semibold))
                                    .foregroundStyle(DS.contrastingForeground(for: color))
                            }
                        }
                    }
                }
            }
            .frame(height: DS.Size.controlHeight)
            .accessibilityElement()
            .accessibilityLabel(
                "Pomodoro timeline: \(pomodoroRounds) rounds of \(pomodoroWork)\u{00A0}min work and \(pomodoroBreak)\u{00A0}min break"
                + (pomodoroLongBreakEnabled ? ", then \(pomodoroLongBreak)\u{00A0}min long break" : "")
            )

            // Session schedule
            pomodoroSchedule
        }
    }

    /// Shows the actual session schedule with real times based on event start.
    /// Collapses middle segments when there are too many to fit.
    private var pomodoroSchedule: some View {
        let segments = pomodoroSegments
        let maxVisible = 6

        return VStack(alignment: .leading, spacing: 0) {
            if segments.count <= maxVisible {
                ForEach(Array(segments.enumerated()), id: \.offset) { idx, segment in
                    scheduleRow(segment, index: idx, total: segments.count)
                }
            } else {
                ForEach(Array(segments.prefix(2).enumerated()), id: \.offset) { idx, segment in
                    scheduleRow(segment, index: idx, total: segments.count)
                }
                HStack(spacing: DS.Spacing.sm) {
                    // Connecting line centered in the same 12pt column as dots
                    Rectangle()
                        .fill(skin.resolvedTextSecondary.opacity(DS.Opacity.subtleBorder))
                        .frame(width: 1.5, height: 16)
                        .frame(width: 12)
                    Text("\(segments.count - 4) more")
                        .font(.system(.footnote, design: skin.resolvedFontDesign))
                        .foregroundStyle(skin.resolvedTextTertiary)
                }
                ForEach(Array(segments.suffix(2).enumerated()), id: \.offset) { idx, segment in
                    scheduleRow(segment, index: segments.count - 2 + idx, total: segments.count)
                }
            }
        }
    }

    private func scheduleRow(
        _ segment: (type: String, minutes: Int, startOffset: Int),
        index: Int,
        total: Int
    ) -> some View {
        let start = date.addingTimeInterval(TimeInterval(segment.startOffset * 60))
        let end = start.addingTimeInterval(TimeInterval(segment.minutes * 60))
        let color = segmentColor(for: segment.type)
        let icon = segmentIcon(for: segment.type)
        let label = segmentLabel(for: segment.type)
        let isLast = index == total - 1

        return HStack(alignment: .top, spacing: DS.Spacing.sm) {
            // Left: icon dot with connecting line
            ZStack(alignment: .top) {
                if !isLast {
                    Rectangle()
                        .fill(color.opacity(DS.Opacity.strongFill))
                        .frame(width: 1.5)
                        .frame(maxHeight: .infinity)
                }
                Circle()
                    .fill(color)
                    .frame(width: 12, height: 12)
                    .overlay {
                        Image(systemName: icon)
                            .font(.system(size: 6, weight: .bold))
                            .foregroundStyle(DS.contrastingForeground(for: color))
                    }
            }
            .frame(width: 12)

            // Right: time and label
            VStack(alignment: .leading, spacing: 1) {
                Text("\(DS.timeFormatter.string(from: start)) – \(DS.timeFormatter.string(from: end))")
                    .font(.system(.footnote, design: .monospaced, weight: .medium))
                    .foregroundStyle(skin.resolvedTextPrimary)
                Text("\(label) · \(segment.minutes)\u{00A0}min")
                    .font(.footnote)
                    .foregroundStyle(skin.resolvedTextSecondary)
            }
            .padding(.bottom, isLast ? 0 : DS.Spacing.xs)
        }
    }

    private func legendItem(color: Color, icon: String, label: String) -> some View {
        HStack(spacing: DS.Spacing.xxs) {
            Image(systemName: icon)
                .font(.system(size: 8, weight: .medium))
                .foregroundStyle(color)
            Text(label)
                .font(.footnote)
                .foregroundStyle(skin.resolvedTextSecondary)
        }
    }

    private func buildPomodoroRule() -> RecurrenceRule {
        RecurrenceRule(
            frequency: .minutely,
            interval: pomodoroCycleMinutes,
            end: .afterCount(pomodoroRounds),
            pomodoroMode: true,
            pomodoroLongBreak: pomodoroLongBreakEnabled ? pomodoroLongBreak : 0
        )
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
