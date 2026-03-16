import SwiftUI

struct AddEventView: View {
    @ObservedObject var reminderService: ReminderService
    @Binding var isPresented: Bool

    @State private var title = ""
    @State private var date = Date()
    @State private var duration: Double = 60
    @State private var location = ""
    @State private var description = ""
    @State private var showValidation = false
    @State private var useCustomReminders = false
    @State private var reminderMinutes: [Int] = [5]
    @State private var newReminderValue = 10

    private static let presetReminders = [1, 2, 3, 5, 10, 15, 20, 30, 45, 60]

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
        VStack(alignment: .leading, spacing: 12) {
            // Header
            HStack {
                OwlIcon(size: 20)
                Text("New Event")
                    .font(.headline)
                Spacer()
            }

            // Title
            VStack(alignment: .leading, spacing: 4) {
                TextField("Event title", text: $title)
                    .textFieldStyle(.plain)
                    .font(.title3)
                    .padding(8)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color(nsColor: .controlBackgroundColor))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(showValidation && !isTitleValid ? Color.red.opacity(0.5) : .clear, lineWidth: 1)
                    )

                if showValidation && !isTitleValid {
                    Text("Title is required")
                        .font(.caption)
                        .foregroundColor(.red)
                }
            }

            // Date & Time
            VStack(alignment: .leading, spacing: 8) {
                Label("Date & Time", systemImage: "clock")
                    .font(.subheadline)
                    .foregroundColor(.secondary)

                DatePicker("Start", selection: $date, displayedComponents: [.date, .hourAndMinute])

                HStack {
                    Text("Duration")
                    Picker("", selection: $duration) {
                        Text("15 min").tag(15.0)
                        Text("30 min").tag(30.0)
                        Text("45 min").tag(45.0)
                        Text("1 hour").tag(60.0)
                        Text("1.5 hours").tag(90.0)
                        Text("2 hours").tag(120.0)
                        Text("3 hours").tag(180.0)
                    }
                    .labelsHidden()
                }

                HStack(spacing: 4) {
                    Image(systemName: "arrow.right")
                        .font(.caption2)
                    Text("Ends at \(Self.timeFormatter.string(from: endDate))")
                        .font(.caption)
                }
                .foregroundColor(.secondary)
            }

            // Location
            VStack(alignment: .leading, spacing: 4) {
                Label("Location", systemImage: "location")
                    .font(.subheadline)
                    .foregroundColor(.secondary)

                TextField("Add location (optional)", text: $location)
                    .textFieldStyle(.roundedBorder)
            }

            // Notes
            VStack(alignment: .leading, spacing: 4) {
                Label("Notes", systemImage: "text.alignleft")
                    .font(.subheadline)
                    .foregroundColor(.secondary)

                TextField("Add notes (optional)", text: $description)
                    .textFieldStyle(.roundedBorder)
            }

            // Reminders
            VStack(alignment: .leading, spacing: 8) {
                Label("Reminders", systemImage: "bell")
                    .font(.subheadline)
                    .foregroundColor(.secondary)

                Toggle("Custom reminders", isOn: $useCustomReminders)
                    .font(.subheadline)

                if useCustomReminders {
                    // Current reminders list
                    ForEach(reminderMinutes.sorted(), id: \.self) { minutes in
                        HStack {
                            Image(systemName: "bell.fill")
                                .font(.caption)
                                .foregroundColor(.accentColor)
                            Text(Self.formatMinutes(minutes))
                                .font(.caption)
                            Spacer()
                            Button {
                                reminderMinutes.removeAll { $0 == minutes }
                            } label: {
                                Image(systemName: "minus.circle.fill")
                                    .foregroundColor(.red)
                                    .font(.caption)
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    // Add new reminder
                    HStack {
                        Stepper("\(Self.formatMinutes(newReminderValue))", value: $newReminderValue, in: 1...120)
                            .font(.caption)

                        Button {
                            if !reminderMinutes.contains(newReminderValue) {
                                reminderMinutes.append(newReminderValue)
                            }
                        } label: {
                            Image(systemName: "plus.circle.fill")
                                .foregroundColor(.green)
                        }
                        .buttonStyle(.plain)
                    }

                    // Quick presets
                    HStack(spacing: 4) {
                        ForEach(Self.presetReminders.filter { !reminderMinutes.contains($0) }.prefix(5), id: \.self) { preset in
                            Button(Self.formatMinutes(preset)) {
                                reminderMinutes.append(preset)
                            }
                            .font(.caption2)
                            .buttonStyle(.bordered)
                            .controlSize(.mini)
                        }
                    }
                } else {
                    Text("Default: 5 min before")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            Divider()

            // Actions
            HStack {
                Spacer()
                Button("Cancel") {
                    isPresented = false
                }
                .keyboardShortcut(.cancelAction)

                Button("Add Event") {
                    if isTitleValid {
                        addEvent()
                    } else {
                        showValidation = true
                    }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding()
        .frame(width: 340)
    }

    private func addEvent() {
        let event = CalendarEvent(
            id: UUID().uuidString,
            title: title,
            startDate: date,
            endDate: endDate,
            location: location.isEmpty ? nil : location,
            description: description.isEmpty ? nil : description,
            calendarName: "Local",
            customReminderMinutes: useCustomReminders ? reminderMinutes.sorted() : nil
        )
        reminderService.addLocalEvent(event)
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
