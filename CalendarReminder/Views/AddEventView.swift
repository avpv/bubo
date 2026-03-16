import SwiftUI

struct AddEventView: View {
    @ObservedObject var reminderService: ReminderService
    var editingEvent: CalendarEvent? = nil
    var onDismiss: () -> Void
    var onSave: (_ isEdit: Bool) -> Void

    @State private var title = ""
    @State private var date = Date()
    @State private var duration: Double = 60
    @State private var location = ""
    @State private var description = ""
    @State private var showValidation = false
    @State private var useCustomReminders = false
    @State private var reminderMinutes: [Int] = [5]
    @State private var newReminderValue = 10

    // Recurrence state
    @State private var frequency: RecurrenceFrequency? = nil
    @State private var interval: Int = 1
    @State private var endType: EndType = .never
    @State private var endCount: Int = 10
    @State private var endDate_: Date = Calendar.current.date(byAdding: .month, value: 1, to: Date()) ?? Date()
    @State private var selectedWeekdays: Set<Weekday> = []

    @FocusState private var isTitleFocused: Bool

    private static let presetReminders = [1, 2, 3, 5, 10, 15, 20, 30, 45, 60]

    private var isEditing: Bool { editingEvent != nil }

    private enum EndType: String, CaseIterable {
        case never = "Never"
        case afterCount = "After"
        case onDate = "On date"
    }

    private var currentRecurrenceRule: RecurrenceRule? {
        guard let freq = frequency else { return nil }
        let end: RecurrenceEnd
        switch endType {
        case .never: end = .never
        case .afterCount: end = .afterCount(endCount)
        case .onDate: end = .untilDate(endDate_)
        }
        return RecurrenceRule(
            frequency: freq,
            interval: interval,
            end: end,
            weekdays: freq == .weekly ? selectedWeekdays : []
        )
    }

    private var isTitleValid: Bool {
        !title.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private var eventEndDate: Date {
        date.addingTimeInterval(duration * 60)
    }

    var body: some View {
        VStack(spacing: 0) {
            PopoverHeader(
                title: isEditing ? "Edit Event" : "New Event",
                showBack: true,
                onBack: onDismiss
            )

            // Form
            Form {
                Section {
                    TextField("Event title", text: $title)
                        .focused($isTitleFocused)
                        .textFieldStyle(.roundedBorder)

                    if showValidation && !isTitleValid {
                        Label("Title is required", systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundColor(.red)
                    }
                }

                Section("Date & Time") {
                    HStack {
                        Text("Start")
                        Spacer()
                        DatePicker("", selection: $date, displayedComponents: .date)
                            .labelsHidden()
                        DatePicker("", selection: $date, displayedComponents: .hourAndMinute)
                            .labelsHidden()
                    }

                    Picker("Duration", selection: $duration) {
                        Text("15 min").tag(15.0)
                        Text("30 min").tag(30.0)
                        Text("45 min").tag(45.0)
                        Text("1 hour").tag(60.0)
                        Text("1.5 hours").tag(90.0)
                        Text("2 hours").tag(120.0)
                        Text("3 hours").tag(180.0)
                    }

                    LabeledContent("Ends at") {
                        Text(DS.timeFormatter.string(from: eventEndDate))
                            .foregroundColor(.secondary)
                    }
                }

                Section("Details") {
                    TextField("Location (optional)", text: $location)
                        .textFieldStyle(.roundedBorder)

                    TextField("Notes (optional)", text: $description)
                        .textFieldStyle(.roundedBorder)
                }

                recurrenceSection

                Section("Reminders") {
                    Toggle("Custom reminders", isOn: $useCustomReminders)

                    if useCustomReminders {
                        ForEach(reminderMinutes.sorted(), id: \.self) { minutes in
                            HStack {
                                Label("\(DS.formatMinutes(minutes)) before", systemImage: "bell.fill")
                                Spacer()
                                Button(role: .destructive) {
                                    reminderMinutes.removeAll { $0 == minutes }
                                } label: {
                                    Image(systemName: "trash")
                                }
                                .buttonStyle(.borderless)
                            }
                        }

                        HStack {
                            Stepper("\(DS.formatMinutes(newReminderValue))", value: $newReminderValue, in: 1...120)

                            Button("Add") {
                                if !reminderMinutes.contains(newReminderValue) {
                                    reminderMinutes.append(newReminderValue)
                                }
                            }
                        }

                        // Quick presets
                        let available = Self.presetReminders.filter { !reminderMinutes.contains($0) }
                        if !available.isEmpty {
                            HStack(spacing: DS.Spacing.xs) {
                                ForEach(available.prefix(5), id: \.self) { preset in
                                    Button(DS.formatMinutes(preset)) {
                                        reminderMinutes.append(preset)
                                    }
                                    .buttonStyle(.bordered)
                                    .controlSize(.mini)
                                }
                            }
                        }
                    } else {
                        Text("Default: 5 min before")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .frame(maxHeight: DS.Popover.formMaxHeight)

            Divider()

            // Actions
            HStack {
                Spacer()
                Button("Cancel") {
                    onDismiss()
                }
                .keyboardShortcut(.cancelAction)

                Button(isEditing ? "Save" : "Add Event") {
                    if isTitleValid {
                        saveEvent()
                    } else {
                        showValidation = true
                    }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
            .padding(.horizontal, DS.Spacing.lg)
            .padding(.vertical, DS.Spacing.md)
            .background(.bar)
        }
        .frame(width: DS.Popover.width)
        .onAppear {
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
                if let rule = event.recurrenceRule {
                    frequency = rule.frequency
                    interval = rule.interval
                    selectedWeekdays = rule.weekdays
                    switch rule.end {
                    case .never:
                        endType = .never
                    case .afterCount(let count):
                        endType = .afterCount
                        endCount = count
                    case .untilDate(let d):
                        endType = .onDate
                        endDate_ = d
                    }
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                isTitleFocused = true
            }
        }
    }

    // MARK: - Recurrence Section

    @ViewBuilder
    private var recurrenceSection: some View {
        Section("Repeat") {
            // Frequency picker — None means no recurrence
            Picker("Frequency", selection: $frequency) {
                Text("Never").tag(RecurrenceFrequency?.none)
                ForEach(RecurrenceFrequency.allCases, id: \.self) { freq in
                    Text("Every \(freq.label)").tag(Optional(freq))
                }
            }

            if let freq = frequency {
                // Interval
                Stepper("Every \(interval) \(interval == 1 ? freq.singularUnit : freq.pluralUnit)",
                        value: $interval, in: 1...99)

                // Weekday selector for weekly
                if freq == .weekly {
                    weekdayPicker
                }

                // End condition
                Picker("Ends", selection: $endType) {
                    ForEach(EndType.allCases, id: \.self) { type in
                        Text(type.rawValue).tag(type)
                    }
                }

                switch endType {
                case .never:
                    EmptyView()
                case .afterCount:
                    Stepper("After \(endCount) occurrences", value: $endCount, in: 2...100)
                case .onDate:
                    DatePicker("Until", selection: $endDate_, displayedComponents: .date)
                }

                // Summary
                if let rule = currentRecurrenceRule {
                    Label(rule.displayText, systemImage: "repeat")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
    }

    private var weekdayPicker: some View {
        HStack(spacing: DS.Spacing.xs) {
            ForEach(Weekday.allCases, id: \.self) { day in
                Button {
                    if selectedWeekdays.contains(day) {
                        selectedWeekdays.remove(day)
                    } else {
                        selectedWeekdays.insert(day)
                    }
                } label: {
                    Text(day.initial)
                        .font(.caption2)
                        .fontWeight(.medium)
                        .frame(width: 28, height: 28)
                        .background(
                            selectedWeekdays.contains(day)
                                ? Color.accentColor
                                : Color.secondary.opacity(0.12)
                        )
                        .foregroundColor(selectedWeekdays.contains(day) ? .white : .primary)
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - Save

    private func saveEvent() {
        let event = CalendarEvent(
            id: editingEvent?.id ?? UUID().uuidString,
            title: title,
            startDate: date,
            endDate: eventEndDate,
            location: location.isEmpty ? nil : location,
            description: description.isEmpty ? nil : description,
            calendarName: "Local",
            customReminderMinutes: useCustomReminders ? reminderMinutes.sorted() : nil,
            recurrenceRule: currentRecurrenceRule
        )
        if isEditing {
            reminderService.updateLocalEvent(event)
        } else {
            reminderService.addLocalEvent(event)
        }
        onSave(isEditing)
    }
}
