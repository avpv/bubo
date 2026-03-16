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
    @State private var enableRecurrence = false
    @State private var recurrenceIntervalMinutes = 30
    @State private var recurrenceRepeatCount = 4
    @FocusState private var isTitleFocused: Bool

    private static let presetReminders = [1, 2, 3, 5, 10, 15, 20, 30, 45, 60]

    private var isEditing: Bool { editingEvent != nil }

    private var currentRecurrenceRule: RecurrenceRule? {
        guard enableRecurrence else { return nil }
        return RecurrenceRule(intervalMinutes: recurrenceIntervalMinutes, repeatCount: recurrenceRepeatCount)
    }

    private var isTitleValid: Bool {
        !title.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private var endDate: Date {
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
                        Text(DS.timeFormatter.string(from: endDate))
                            .foregroundColor(.secondary)
                    }
                }

                Section("Details") {
                    TextField("Location (optional)", text: $location)
                        .textFieldStyle(.roundedBorder)

                    TextField("Notes (optional)", text: $description)
                        .textFieldStyle(.roundedBorder)
                }

                Section("Repeat") {
                    Toggle("Repeat event", isOn: $enableRecurrence)

                    if enableRecurrence {
                        Stepper("Interval: \(DS.formatMinutes(recurrenceIntervalMinutes))",
                                value: $recurrenceIntervalMinutes, in: 5...180, step: 5)
                        Stepper("Repeats: \(recurrenceRepeatCount)x",
                                value: $recurrenceRepeatCount, in: 2...20)

                        if let rule = currentRecurrenceRule {
                            HStack(spacing: DS.Spacing.xs) {
                                Image(systemName: "repeat")
                                    .foregroundColor(.secondary)
                                Text(rule.displayText)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                Text("(\(DS.formatMinutes(rule.totalSpanMinutes)) total)")
                                    .font(.caption)
                                    .foregroundColor(.tertiary)
                            }
                        }
                    }
                }

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
                    enableRecurrence = true
                    recurrenceIntervalMinutes = rule.intervalMinutes
                    recurrenceRepeatCount = rule.repeatCount
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                isTitleFocused = true
            }
        }
    }

    private func saveEvent() {
        let event = CalendarEvent(
            id: editingEvent?.id ?? UUID().uuidString,
            title: title,
            startDate: date,
            endDate: endDate,
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
