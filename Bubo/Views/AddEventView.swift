import SwiftUI

struct AddEventView: View {
    var reminderService: ReminderService
    var editingEvent: CalendarEvent? = nil
    var onDismiss: () -> Void
    var onSave: (_ isEdit: Bool) -> Void

    @State private var title = ""
    @State private var date = Date()
    @State private var duration: Double = 30
    @State private var location = ""
    @State private var description = ""
    @State private var showValidation = false
    @State private var useCustomReminders = false
    @State private var reminderMinutes: [Int] = [5]
    @State private var newReminderValue = 10
    @State private var recurrenceRule: RecurrenceRule? = nil
    @State private var selectedEventType: EventType = .standard
    @State private var addToCalendar = false
    @State private var selectedColorTag: EventColorTag? = nil

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
    @FocusState private var isNotesFocused: Bool

    private static let presetReminders = [1, 2, 3, 5, 10, 15, 20, 30, 45, 60]

    private var isEditing: Bool { editingEvent != nil }
    private var isExternal: Bool { editingEvent?.isLocalEvent == false }

    private var isTitleValid: Bool {
        !title.trimmingCharacters(in: .whitespaces).isEmpty
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

    private var pomodoroCycleMinutes: Int {
        pomodoroWork + pomodoroBreak
    }

    private var pomodoroTotalMinutes: Int {
        let workTotal = pomodoroWork * pomodoroRounds
        let shortBreakTotal = pomodoroBreak * (pomodoroRounds - 1)
        let longBreak = pomodoroLongBreakEnabled ? pomodoroLongBreak : 0
        return workTotal + shortBreakTotal + longBreak
    }

    var body: some View {
        VStack(spacing: 0) {
            PopoverHeader(
                title: isEditing
                    ? (isPomodoroMode ? "Edit Pomodoro" : "Edit Event")
                    : (isPomodoroMode ? "New Pomodoro" : "New Event"),
                showBack: true,
                onBack: onDismiss
            )

            ScrollView {
                VStack(spacing: DS.Spacing.lg) {
                    
                    // Title section
                    VStack(alignment: .leading, spacing: DS.Spacing.xs) {
                        TextField("Title", text: $title, prompt: Text("Event title"))
                            .textFieldStyle(.plain)
                            .font(.headline)
                            .focused($isTitleFocused)
                            .defaultFocus($isTitleFocused, true)

                        if showValidation && !isTitleValid {
                            Label("Title is required", systemImage: "exclamationmark.triangle.fill")
                                .font(.caption)
                                .foregroundColor(DS.Colors.error)
                                .transition(.move(edge: .top).combined(with: .opacity))
                        }
                    }
                    .padding(.horizontal, DS.Spacing.md)
                    .padding(.vertical, DS.Spacing.sm)
                    .background(DS.Materials.platter)
                    .clipShape(RoundedRectangle(cornerRadius: DS.Size.cornerRadius, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: DS.Size.cornerRadius, style: .continuous)
                            .stroke(isTitleFocused ? DS.Colors.accent.opacity(0.8) : Color.clear, lineWidth: DS.Size.focusRingWidth)
                    )
                    .shadow(
                        color: isTitleFocused ? DS.Colors.accent.opacity(0.15) : DS.Shadows.ambientColor,
                        radius: isTitleFocused ? DS.Shadows.ambientRadius + 1 : DS.Shadows.ambientRadius,
                        y: DS.Shadows.ambientY
                    )
                    .animation(DS.Animation.microInteraction, value: isTitleFocused)
                    .disabled(isExternal)
                    .opacity(isExternal ? 0.6 : 1.0)

                    // Event Type
                    if !isExternal {
                        Picker("Type", selection: $selectedEventType) {
                            Label("Event", systemImage: "calendar").tag(EventType.standard)
                            Label("Pomodoro", systemImage: "timer").tag(EventType.pomodoro)
                        }
                        .pickerStyle(.segmented)
                        .padding(.horizontal, DS.Spacing.md)
                    }

                    // Date & Time
                    VStack(alignment: .leading, spacing: DS.Spacing.xs) {
                        Text("Date & Time")
                            .font(.headline)
                            .foregroundColor(DS.Colors.textPrimary)
                        
                        Grid(alignment: .leading, horizontalSpacing: DS.Spacing.sm, verticalSpacing: DS.Spacing.md) {
                            GridRow {
                                Text("Starts")
                                    .foregroundColor(DS.Colors.textSecondary)
                                    .gridColumnAlignment(.trailing)
                                
                                HStack(spacing: DS.Spacing.xs) {
                                    DateTimePickerPills(date: $date)
                                    TimeSlotPicker(selection: $date)
                                }
                            }
                            
                            if selectedEventType != .pomodoro {
                                GridRow {
                                    Text("Ends")
                                        .foregroundColor(DS.Colors.textSecondary)
                                        .gridColumnAlignment(.trailing)

                                    HStack(spacing: DS.Spacing.xs) {
                                        DateTimePickerPills(date: endDateBinding, range: date...)
                                        TimeSlotPicker(selection: endDateBinding)
                                    }
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(DS.Spacing.md)
                        .background(DS.Materials.platter)
                        .clipShape(RoundedRectangle(cornerRadius: DS.Size.cornerRadius, style: .continuous))
                        .shadow(color: DS.Shadows.ambientColor, radius: DS.Shadows.ambientRadius, y: DS.Shadows.ambientY)
                    }
                    .disabled(isExternal)
                    .opacity(isExternal ? 0.6 : 1.0)

                    // Pomodoro controls (only when Pomodoro type selected)
                    if isPomodoroMode {
                        pomodoroSection
                            .disabled(isExternal)
                            .opacity(isExternal ? 0.6 : 1.0)
                    }

                    // Calendar
                    if !isEditing {
                        VStack(alignment: .leading, spacing: DS.Spacing.xs) {
                            VStack(alignment: .leading, spacing: DS.Spacing.md) {
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
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(DS.Spacing.md)
                            .background(DS.Materials.platter)
                            .clipShape(RoundedRectangle(cornerRadius: DS.Size.cornerRadius, style: .continuous))
                            .shadow(color: DS.Shadows.ambientColor, radius: DS.Shadows.ambientRadius, y: DS.Shadows.ambientY)

                            if !addToCalendar {
                                Text("Event will be stored locally in Bubo only")
                                    .font(.caption)
                                    .foregroundColor(DS.Colors.textSecondary)
                                    .padding(.horizontal, DS.Spacing.sm)
                            }
                        }
                    }

                    // Color
                    VStack(alignment: .leading, spacing: DS.Spacing.xs) {
                        Text("Color")
                            .font(.headline)
                            .foregroundColor(DS.Colors.textPrimary)

                        HStack(spacing: DS.Spacing.xs) {
                            ForEach(EventColorTag.allCases, id: \.self) { tag in
                                Circle()
                                    .fill(tag.color)
                                    .frame(width: 14, height: 14)
                                    .overlay(
                                        Circle()
                                            .stroke(Color.white, lineWidth: selectedColorTag == tag ? 1.5 : 0)
                                    )
                                    .shadow(
                                        color: selectedColorTag == tag ? tag.color.opacity(0.5) : .clear,
                                        radius: selectedColorTag == tag ? 3 : 0
                                    )
                                    .scaleEffect(selectedColorTag == tag ? 1.2 : 1.0)
                                    .animation(DS.Animation.microInteraction, value: selectedColorTag)
                                    .onTapGesture {
                                        Haptics.tap()
                                        if selectedColorTag == tag {
                                            selectedColorTag = nil
                                        } else {
                                            selectedColorTag = tag
                                        }
                                    }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, DS.Spacing.md)
                        .padding(.vertical, DS.Spacing.sm)
                        .background(DS.Materials.platter)
                        .clipShape(RoundedRectangle(cornerRadius: DS.Size.cornerRadius, style: .continuous))
                        .shadow(color: DS.Shadows.ambientColor, radius: DS.Shadows.ambientRadius, y: DS.Shadows.ambientY)
                    }
                    .disabled(isExternal)
                    .opacity(isExternal ? 0.6 : 1.0)

                    // Details
                    VStack(alignment: .leading, spacing: DS.Spacing.xs) {
                        Text("Details")
                            .font(.headline)
                            .foregroundColor(DS.Colors.textPrimary)
                        
                        VStack(spacing: DS.Spacing.md) {
                            TextField("Location", text: $location, prompt: Text("Location"))
                                .textFieldStyle(.plain)
                                .focused($isLocationFocused)

                            Divider()

                            TextField("Notes", text: $description, prompt: Text("Notes"), axis: .vertical)
                                .textFieldStyle(.plain)
                                .focused($isNotesFocused)
                                .lineLimit(3...8)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(DS.Spacing.md)
                        .background(DS.Materials.platter)
                        .clipShape(RoundedRectangle(cornerRadius: DS.Size.cornerRadius, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: DS.Size.cornerRadius, style: .continuous)
                                .stroke((isLocationFocused || isNotesFocused) ? DS.Colors.accent.opacity(0.8) : Color.clear, lineWidth: DS.Size.focusRingWidth)
                        )
                        .shadow(
                            color: (isLocationFocused || isNotesFocused) ? DS.Colors.accent.opacity(0.15) : DS.Shadows.ambientColor,
                            radius: (isLocationFocused || isNotesFocused) ? DS.Shadows.ambientRadius + 1 : DS.Shadows.ambientRadius,
                            y: DS.Shadows.ambientY
                        )
                        .animation(DS.Animation.microInteraction, value: isLocationFocused || isNotesFocused)
                    }
                    .disabled(isExternal)
                    .opacity(isExternal ? 0.6 : 1.0)

                    // Recurrence (only for standard events)
                    if !isPomodoroMode {
                        VStack(alignment: .leading, spacing: DS.Spacing.xs) {
                            RecurrencePickerView(rule: $recurrenceRule, eventDuration: $duration, eventStartDate: date)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(DS.Spacing.md)
                                .background(DS.Materials.platter)
                                .clipShape(RoundedRectangle(cornerRadius: DS.Size.cornerRadius, style: .continuous))
                                .shadow(color: DS.Shadows.ambientColor, radius: DS.Shadows.ambientRadius, y: DS.Shadows.ambientY)
                        }
                        .disabled(isExternal)
                        .opacity(isExternal ? 0.6 : 1.0)
                    }

                    // Reminders
                    VStack(alignment: .leading, spacing: DS.Spacing.xs) {
                        Text("Reminders")
                            .font(.headline)
                            .foregroundColor(DS.Colors.textPrimary)
                        
                        VStack(alignment: .leading, spacing: DS.Spacing.md) {
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
                                    Divider()
                                }

                                Grid(alignment: .leading, horizontalSpacing: DS.Spacing.sm) {
                                    GridRow {
                                        Text("\(DS.formatMinutes(newReminderValue))")
                                            .frame(minWidth: 60, alignment: .leading)
                                            .monospacedDigit()
                                        
                                        Stepper("", value: $newReminderValue, in: 1...120)
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
                                                    .font(.caption)
                                            }
                                            .buttonStyle(.plain)
                                            .padding(.horizontal, DS.Spacing.sm)
                                            .frame(height: DS.Size.controlHeight)
                                            .background(Capsule().fill(DS.Colors.badgeFill(DS.Colors.textPrimary)))
                                            .foregroundColor(DS.Colors.textPrimary)
                                        }
                                    }
                                }
                            } else {
                                Label(
                                        "Default: \(reminderService.defaultReminderMinutesList.map { DS.formatMinutes($0) }.joined(separator: ", "))",
                                        systemImage: "bell.fill"
                                    )
                                    .font(.subheadline)
                                    .foregroundColor(.secondary)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(DS.Spacing.md)
                        .background(DS.Materials.platter)
                        .clipShape(RoundedRectangle(cornerRadius: DS.Size.cornerRadius, style: .continuous))
                        .shadow(color: DS.Shadows.ambientColor, radius: DS.Shadows.ambientRadius, y: DS.Shadows.ambientY)
                    }
                }
                .padding(.horizontal, DS.Spacing.lg)
                .padding(.vertical, DS.Spacing.xl)
            }
            .scrollContentBackground(.hidden)
            .frame(maxHeight: .infinity)
            .onChange(of: selectedEventType) {
                // Clear standard recurrence when switching to Pomodoro
                if selectedEventType == .pomodoro {
                    recurrenceRule = nil
                }
            }

            Divider()

            HStack {
                Spacer()
                Button(action: { onDismiss() }) {
                    Text("Cancel")
                }
                .keyboardShortcut(.cancelAction)
                .buttonStyle(.action(role: .secondary))

                Button(action: {
                    if isTitleValid {
                        saveEvent()
                    } else {
                        showValidation = true
                    }
                }) {
                    Label(isEditing ? "Save" : "Add Event", systemImage: isEditing ? "checkmark.circle" : "calendar.badge.plus")
                }
                .buttonStyle(.action(role: .primary))
            }
            .padding(.horizontal, DS.Spacing.lg)
            .frame(height: DS.Size.actionFooterHeight)
            .background(DS.Materials.headerBar)
        }
        .frame(width: DS.Popover.width, height: DS.Popover.height)
        .onAppear {
            availableCalendars = AppleCalendarService.shared.listCalendars()
            selectedCalendarId = AppleCalendarService.shared.defaultCalendarId ?? availableCalendars.first?.id ?? ""
            reminderMinutes = reminderService.defaultReminderMinutesList
            if let event = editingEvent {
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
            }
            Task {
                try? await Task.sleep(for: .milliseconds(100))
                isTitleFocused = true
            }
        }
    }

    // MARK: - Pomodoro Section

    private var pomodoroSection: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.xs) {
            Text("Pomodoro")
                .font(.headline)
                .foregroundColor(DS.Colors.textPrimary)

            VStack(alignment: .leading, spacing: DS.Spacing.md) {
                Grid(alignment: .leading, horizontalSpacing: DS.Spacing.md, verticalSpacing: DS.Spacing.sm) {
                    GridRow {
                        Label("Work: \(pomodoroWork) min", systemImage: "brain.head.profile")
                            .foregroundColor(.primary)
                            .gridColumnAlignment(.leading)
                        Stepper("", value: $pomodoroWork, in: 1...90)
                            .labelsHidden()
                    }

                    GridRow {
                        Label("Rounds: \(pomodoroRounds)", systemImage: "arrow.trianglehead.2.counterclockwise")
                            .foregroundColor(.primary)
                        Stepper("", value: $pomodoroRounds, in: 1...12)
                            .labelsHidden()
                    }

                    if pomodoroRounds > 1 {
                        GridRow {
                            Label("Break: \(pomodoroBreak) min", systemImage: "cup.and.saucer")
                                .foregroundColor(.primary)
                            Stepper("", value: $pomodoroBreak, in: 1...30)
                                .labelsHidden()
                        }

                        GridRow {
                            Toggle(isOn: $pomodoroLongBreakEnabled) {
                                Label("Long break", systemImage: "moon.zzz")
                                    .foregroundColor(.primary)
                            }
                            Color.clear
                        }

                        if pomodoroLongBreakEnabled {
                            GridRow {
                                Label("Duration: \(pomodoroLongBreak) min", systemImage: "moon.zzz")
                                    .foregroundColor(.primary)
                                    .padding(.leading, DS.Spacing.lg)
                                Stepper("", value: $pomodoroLongBreak, in: 5...60, step: 5)
                                    .labelsHidden()
                            }
                        }
                    }
                }

                // Visual timeline
                pomodoroTimeline
                    .padding(.vertical, DS.Spacing.md)
                    .animation(DS.Animation.smoothSpring, value: pomodoroWork)
                    .animation(DS.Animation.smoothSpring, value: pomodoroBreak)
                    .animation(DS.Animation.smoothSpring, value: pomodoroRounds)
                    .animation(DS.Animation.gentleBounce, value: pomodoroLongBreakEnabled)
                    .animation(DS.Animation.smoothSpring, value: pomodoroLongBreak)

                HStack {
                    Label(
                        "Total: \(DS.formatMinutes(pomodoroTotalMinutes))",
                        systemImage: "clock"
                    )
                    .font(.caption)
                    .foregroundColor(.secondary)

                    Spacer()

                    Link("Learn about Pomodoro combinations", destination: URL(string: "https://github.com/avpv/bubo/blob/HEAD/docs/Pomodoro.md")!)
                        .font(.caption)
                        .foregroundColor(.accentColor)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(DS.Spacing.md)
            .background(DS.Materials.platter)
            .clipShape(RoundedRectangle(cornerRadius: DS.Size.cornerRadius, style: .continuous))
            .shadow(color: DS.Shadows.ambientColor, radius: DS.Shadows.ambientRadius, y: DS.Shadows.ambientY)
        }
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
        case "work": .accentColor
        case "long": .indigo
        default: .green
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
                legendItem(color: .accentColor, icon: "brain.head.profile", label: "Work")
                legendItem(color: .green, icon: "cup.and.saucer", label: "Break")
                if pomodoroLongBreakEnabled {
                    legendItem(color: .indigo, icon: "moon.zzz", label: "Long break")
                }
                Spacer()
                // Work/break ratio
                let totalWork = pomodoroWork * pomodoroRounds
                let totalBreak = pomodoroTotalMinutes - totalWork
                if totalBreak > 0 {
                    Text("\(totalWork):\(totalBreak)")
                        .font(.system(.caption2, design: .monospaced, weight: .medium))
                        .foregroundStyle(.tertiary)
                    + Text(" work:rest")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
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
                            cornerRadius: (isFirst || isLast) ? 5 : 3,
                            style: .continuous
                        )
                        .fill(
                            LinearGradient(
                                colors: [color, color.opacity(0.7)],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                        .frame(width: segWidth)
                        .overlay {
                            if segWidth > 30 {
                                Text("\(segment.minutes)m")
                                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                                    .foregroundStyle(.white)
                            }
                        }
                    }
                }
            }
            .frame(height: 28)
            .accessibilityElement()
            .accessibilityLabel(
                "Pomodoro timeline: \(pomodoroRounds) rounds of \(pomodoroWork) min work and \(pomodoroBreak) min break"
                + (pomodoroLongBreakEnabled ? ", then \(pomodoroLongBreak) min long break" : "")
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
                        .fill(Color.secondary.opacity(0.15))
                        .frame(width: 1.5, height: 16)
                        .frame(width: 12)
                    Text("\(segments.count - 4) more")
                        .font(.system(.caption2, design: .rounded))
                        .foregroundStyle(.tertiary)
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
                        .fill(color.opacity(0.2))
                        .frame(width: 1.5)
                        .frame(maxHeight: .infinity)
                }
                Circle()
                    .fill(color)
                    .frame(width: 12, height: 12)
                    .overlay {
                        Image(systemName: icon)
                            .font(.system(size: 6, weight: .bold))
                            .foregroundStyle(.white)
                    }
            }
            .frame(width: 12)

            // Right: time and label
            VStack(alignment: .leading, spacing: 1) {
                Text("\(DS.timeFormatter.string(from: start)) – \(DS.timeFormatter.string(from: end))")
                    .font(.system(.caption, design: .monospaced, weight: .medium))
                    .foregroundColor(.primary)
                Text("\(label) · \(segment.minutes) min")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(.bottom, isLast ? 0 : DS.Spacing.xs)
        }
    }

    private func legendItem(color: Color, icon: String, label: String) -> some View {
        HStack(spacing: DS.Spacing.xxs) {
            Image(systemName: icon)
                .font(.system(size: 8))
                .foregroundStyle(color)
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
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
        if isEditing {
            reminderService.updateLocalEvent(event)
        } else if addToCalendar {
            reminderService.addCalendarEvent(event, calendarId: selectedCalendarId)
        } else {
            reminderService.addLocalEvent(event)
        }
        onSave(isEditing)
    }
}
