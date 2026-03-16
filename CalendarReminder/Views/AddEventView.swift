import SwiftUI

struct AddEventView: View {
    @ObservedObject var reminderService: ReminderService
    @Binding var isPresented: Bool
    var editingEvent: CalendarEvent? = nil

    @State private var title = ""
    @State private var date = Date()
    @State private var duration: Double = 60
    @State private var location = ""
    @State private var description = ""
    @State private var showValidation = false
    @State private var useCustomReminders = false
    @State private var reminderMinutes: [Int] = [5]
    @State private var newReminderValue = 10
    @FocusState private var isTitleFocused: Bool
    @FocusState private var isLocationFocused: Bool
    @FocusState private var isNotesFocused: Bool

    private static let presetReminders = [1, 2, 3, 5, 10, 15, 20, 30, 45, 60]

    private var isEditing: Bool { editingEvent != nil }

    private var isTitleValid: Bool {
        !title.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private var endDate: Date {
        date.addingTimeInterval(duration * 60)
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()

    var body: some View {
        VStack(spacing: 0) {
            // Header with back button
            HStack(spacing: 4) {
                Button {
                    isPresented = false
                } label: {
                    HStack(spacing: 2) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 13, weight: .semibold))
                        Text("Back")
                            .font(.subheadline)
                    }
                }
                .buttonStyle(.borderless)

                Spacer()

                Text(isEditing ? "Edit Event" : "New Event")
                    .font(.headline)

                Spacer()

                OwlIcon(size: 18)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.bar)

            Divider()

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
                        Text(Self.timeFormatter.string(from: endDate))
                            .foregroundColor(.secondary)
                    }
                }

                Section("Details") {
                    TextField("Location (optional)", text: $location)
                        .focused($isLocationFocused)
                        .textFieldStyle(.roundedBorder)

                    TextField("Notes (optional)", text: $description)
                        .focused($isNotesFocused)
                        .textFieldStyle(.roundedBorder)
                }

                Section("Reminders") {
                    Toggle("Custom reminders", isOn: $useCustomReminders)

                    if useCustomReminders {
                        ForEach(reminderMinutes.sorted(), id: \.self) { minutes in
                            HStack {
                                Label("\(Self.formatMinutes(minutes)) before", systemImage: "bell.fill")
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
                            Stepper("\(Self.formatMinutes(newReminderValue))", value: $newReminderValue, in: 1...120)

                            Button("Add") {
                                if !reminderMinutes.contains(newReminderValue) {
                                    reminderMinutes.append(newReminderValue)
                                }
                            }
                        }

                        // Quick presets
                        let available = Self.presetReminders.filter { !reminderMinutes.contains($0) }
                        if !available.isEmpty {
                            HStack(spacing: 4) {
                                ForEach(available.prefix(5), id: \.self) { preset in
                                    Button(Self.formatMinutes(preset)) {
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
            .frame(maxHeight: 340)

            Divider()

            // Actions
            HStack {
                Spacer()
                Button("Cancel") {
                    isPresented = false
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
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.bar)
        }
        .frame(width: 340)
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
            customReminderMinutes: useCustomReminders ? reminderMinutes.sorted() : nil
        )
        if isEditing {
            reminderService.updateLocalEvent(event)
        } else {
            reminderService.addLocalEvent(event)
        }
        isPresented = false
    }

    private static func formatMinutes(_ minutes: Int) -> String {
        if minutes >= 60 {
            let h = minutes / 60
            let m = minutes % 60
            return m == 0 ? "\(h) h" : "\(h) h \(m) min"
        }
        return "\(minutes) min"
    }
}
