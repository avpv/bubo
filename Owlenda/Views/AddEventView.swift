import SwiftUI

struct AddEventView: View {
    var reminderService: ReminderService
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
    @State private var recurrenceRule: RecurrenceRule? = nil

    @FocusState private var isTitleFocused: Bool

    private static let presetReminders = [1, 2, 3, 5, 10, 15, 20, 30, 45, 60]

    private var isEditing: Bool { editingEvent != nil }

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
        recurrenceRule?.frequency == .minutely
    }

    var body: some View {
        VStack(spacing: 0) {
            PopoverHeader(
                title: isEditing ? "Edit Event" : "New Event",
                showBack: true,
                onBack: onDismiss
            )

            Form {
                Section {
                    TextField("Title", text: $title, prompt: Text("Event title"))
                        .textFieldStyle(.roundedBorder)
                        .focused($isTitleFocused)
                        .defaultFocus($isTitleFocused, true)

                    if showValidation && !isTitleValid {
                        Label("Title is required", systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundColor(DS.Colors.error)
                            .transition(.move(edge: .top).combined(with: .opacity))
                    }
                }

                Section("Date & Time") {
                    HStack {
                        InlineTimePicker(selection: $date)

                        DatePicker("", selection: $date,
                                   displayedComponents: .date)
                            .labelsHidden()

                        Text("—")
                            .foregroundColor(DS.Colors.textSecondary)

                        InlineTimePicker(selection: endDateBinding)

                        DatePicker("", selection: endDateBinding, in: date...,
                                   displayedComponents: .date)
                            .labelsHidden()
                    }
                    .datePickerStyle(.stepperField)
                }

                Section("Details") {
                    TextField("Location", text: $location, prompt: Text("Optional"))

                    TextField("Notes", text: $description, prompt: Text("Optional"), axis: .vertical)
                        .lineLimit(3...8)
                }

                RecurrencePickerView(rule: $recurrenceRule, eventDuration: $duration, eventStartDate: date)

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

            HStack {
                Spacer()
                Button("Cancel") { onDismiss() }
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
            .background(DS.Materials.headerBar)
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
                recurrenceRule = event.recurrenceRule
            }
            Task {
                try? await Task.sleep(for: .milliseconds(100))
                isTitleFocused = true
            }
        }
    }

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
            recurrenceRule: recurrenceRule
        )
        if isEditing {
            reminderService.updateLocalEvent(event)
        } else {
            reminderService.addLocalEvent(event)
        }
        onSave(isEditing)
    }
}
