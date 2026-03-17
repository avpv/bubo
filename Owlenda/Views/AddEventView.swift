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
    @State private var recurrenceRule: RecurrenceRule? = nil

    @FocusState private var isTitleFocused: Bool

    private static let presetReminders = [1, 2, 3, 5, 10, 15, 20, 30, 45, 60]

    /// Time slot model for the dropdown.
    private struct TimeSlot: Identifiable {
        let id: Int // total minutes from midnight
        let hour: Int
        let minute: Int
        var label: String { String(format: "%02d:%02d", hour, minute) }
    }

    /// Generate time slots for dropdown (every 30 min, 00:00–23:30).
    private static let timeSlots: [TimeSlot] = (0..<48).map { i in
        TimeSlot(id: i * 30, hour: i / 2, minute: (i % 2) * 30)
    }

    private var isEditing: Bool { editingEvent != nil }

    private var isTitleValid: Bool {
        !title.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private var eventEndDate: Date {
        date.addingTimeInterval(duration * 60)
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
                        timeInput
                    }

                    if !isPomodoroMode {
                        Picker("Duration", selection: $duration) {
                            Text("15 min").tag(15.0)
                            Text("30 min").tag(30.0)
                            Text("45 min").tag(45.0)
                            Text("1 hour").tag(60.0)
                            Text("1.5 hours").tag(90.0)
                            Text("2 hours").tag(120.0)
                            Text("3 hours").tag(180.0)
                        }
                    }

                    LabeledContent("Ends at") {
                        Text(DS.timeFormatter.string(from: eventEndDate))
                            .foregroundColor(.secondary)
                    }
                }

                Section("Details") {
                    TextField("Location", text: $location, prompt: Text("Optional"))
                        .textFieldStyle(.roundedBorder)

                    VStack(alignment: .leading, spacing: DS.Spacing.xs) {
                        Text("Notes")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        TextEditor(text: $description)
                            .font(.body)
                            .frame(minHeight: 60, maxHeight: 120)
                            .overlay(
                                RoundedRectangle(cornerRadius: DS.Size.cornerRadius)
                                    .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
                            )
                            .overlay(alignment: .topLeading) {
                                if description.isEmpty {
                                    Text("Optional")
                                        .foregroundColor(.secondary.opacity(0.5))
                                        .padding(.horizontal, 5)
                                        .padding(.vertical, 8)
                                        .allowsHitTesting(false)
                                }
                            }
                    }
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
                recurrenceRule = event.recurrenceRule
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                isTitleFocused = true
            }
        }
    }

    // MARK: - Time Input with Dropdown

    /// Time picker that shows a dropdown of 30-min slots while preserving manual entry via native DatePicker.
    private var timeInput: some View {
        HStack(spacing: DS.Spacing.xs) {
            // Native DatePicker for manual keyboard entry
            DatePicker("", selection: $date, displayedComponents: .hourAndMinute)
                .labelsHidden()

            // Dropdown menu for quick 30-min slot selection
            Menu {
                ForEach(Self.timeSlots) { slot in
                    Button(slot.label) {
                        var cal = Calendar.current
                        cal.timeZone = .current
                        var comps = cal.dateComponents([.year, .month, .day], from: date)
                        comps.hour = slot.hour
                        comps.minute = slot.minute
                        comps.second = 0
                        if let newDate = cal.date(from: comps) {
                            date = newDate
                        }
                    }
                }
            } label: {
                Image(systemName: "clock")
                    .font(.system(size: DS.Size.iconMedium))
                    .foregroundColor(.secondary)
                    .padding(DS.Spacing.xs)
                    .background(
                        RoundedRectangle(cornerRadius: DS.Size.cornerRadius)
                            .fill(Color.secondary.opacity(0.08))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: DS.Size.cornerRadius)
                            .stroke(Color.secondary.opacity(0.25), lineWidth: 1)
                    )
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Quick time slots (30 min intervals)")
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
