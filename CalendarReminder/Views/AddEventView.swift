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
        VStack(spacing: 0) {
            // Header
            HStack(spacing: 8) {
                Button {
                    isPresented = false
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)

                OwlIcon(size: 18)
                Text("New Event")
                    .font(.system(.headline, design: .rounded))
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 8)

            Divider()
                .padding(.horizontal, 8)

            // Scrollable form
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    // Title
                    FormSection(icon: "pencil", title: "Title") {
                        TextField("What's the event?", text: $title)
                            .textFieldStyle(.plain)
                            .font(.system(.body, design: .rounded))
                            .padding(8)
                            .background(
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(Color(nsColor: .controlBackgroundColor))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(showValidation && !isTitleValid
                                        ? Color.red.opacity(0.6) : Color.primary.opacity(0.06),
                                        lineWidth: 1)
                            )

                        if showValidation && !isTitleValid {
                            Label("Title is required", systemImage: "exclamationmark.circle.fill")
                                .font(.caption2)
                                .foregroundColor(.red)
                        }
                    }

                    // Date & Time
                    FormSection(icon: "calendar.badge.clock", title: "Date & Time") {
                        DatePicker("Start", selection: $date, displayedComponents: [.date, .hourAndMinute])
                            .font(.system(.subheadline, design: .rounded))

                        HStack {
                            Text("Duration")
                                .font(.system(.subheadline, design: .rounded))
                            Spacer()
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
                            .frame(width: 100)
                        }

                        HStack(spacing: 4) {
                            Image(systemName: "arrow.right.circle.fill")
                                .font(.caption2)
                                .foregroundColor(.accentColor)
                            Text("Ends at \(Self.timeFormatter.string(from: endDate))")
                                .font(.system(.caption, design: .rounded))
                        }
                        .foregroundColor(.secondary)
                    }

                    // Location
                    FormSection(icon: "location.fill", title: "Location") {
                        TextField("Add location", text: $location)
                            .textFieldStyle(.plain)
                            .font(.system(.subheadline, design: .rounded))
                            .padding(8)
                            .background(
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(Color(nsColor: .controlBackgroundColor))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(Color.primary.opacity(0.06), lineWidth: 1)
                            )
                    }

                    // Notes
                    FormSection(icon: "text.alignleft", title: "Notes") {
                        TextField("Add notes", text: $description)
                            .textFieldStyle(.plain)
                            .font(.system(.subheadline, design: .rounded))
                            .padding(8)
                            .background(
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(Color(nsColor: .controlBackgroundColor))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(Color.primary.opacity(0.06), lineWidth: 1)
                            )
                    }

                    // Reminders
                    FormSection(icon: "bell.badge", title: "Reminders") {
                        Toggle(isOn: $useCustomReminders) {
                            Text("Custom reminders")
                                .font(.system(.subheadline, design: .rounded))
                        }
                        .toggleStyle(.switch)
                        .controlSize(.small)

                        if useCustomReminders {
                            VStack(spacing: 4) {
                                ForEach(reminderMinutes.sorted(), id: \.self) { minutes in
                                    HStack(spacing: 6) {
                                        Image(systemName: "bell.fill")
                                            .font(.system(size: 9))
                                            .foregroundColor(.accentColor)
                                        Text("\(Self.formatMinutes(minutes)) before")
                                            .font(.system(.caption, design: .rounded))
                                        Spacer()
                                        Button {
                                            withAnimation(.easeOut(duration: 0.15)) {
                                                reminderMinutes.removeAll { $0 == minutes }
                                            }
                                        } label: {
                                            Image(systemName: "xmark.circle.fill")
                                                .font(.caption2)
                                                .foregroundColor(.secondary)
                                        }
                                        .buttonStyle(.plain)
                                    }
                                    .padding(.vertical, 3)
                                    .padding(.horizontal, 8)
                                    .background(
                                        RoundedRectangle(cornerRadius: 6)
                                            .fill(Color.accentColor.opacity(0.06))
                                    )
                                }
                            }

                            HStack {
                                Stepper(
                                    Self.formatMinutes(newReminderValue),
                                    value: $newReminderValue,
                                    in: 1...120
                                )
                                .font(.system(.caption, design: .rounded))

                                Button {
                                    if !reminderMinutes.contains(newReminderValue) {
                                        withAnimation(.easeOut(duration: 0.15)) {
                                            reminderMinutes.append(newReminderValue)
                                        }
                                    }
                                } label: {
                                    Image(systemName: "plus.circle.fill")
                                        .foregroundColor(.green)
                                }
                                .buttonStyle(.plain)
                            }

                            // Quick presets
                            let available = Self.presetReminders.filter { !reminderMinutes.contains($0) }
                            if !available.isEmpty {
                                ScrollView(.horizontal, showsIndicators: false) {
                                    HStack(spacing: 4) {
                                        ForEach(available.prefix(6), id: \.self) { preset in
                                            Button {
                                                withAnimation(.easeOut(duration: 0.15)) {
                                                    reminderMinutes.append(preset)
                                                }
                                            } label: {
                                                Text(Self.formatMinutes(preset))
                                                    .font(.system(size: 10, weight: .medium, design: .rounded))
                                                    .padding(.horizontal, 8)
                                                    .padding(.vertical, 3)
                                                    .background(
                                                        Capsule()
                                                            .fill(Color.primary.opacity(0.06))
                                                    )
                                            }
                                            .buttonStyle(.plain)
                                        }
                                    }
                                }
                            }
                        } else {
                            HStack(spacing: 4) {
                                Image(systemName: "bell")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                                Text("Default: 5 min before")
                                    .font(.system(.caption, design: .rounded))
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                }
                .padding(12)
            }
            .frame(maxHeight: 340)

            Divider()
                .padding(.horizontal, 8)

            // Actions
            HStack(spacing: 8) {
                Button("Cancel") {
                    isPresented = false
                }
                .keyboardShortcut(.cancelAction)
                .buttonStyle(.plain)
                .font(.system(.subheadline, design: .rounded))
                .foregroundColor(.secondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.primary.opacity(0.05))
                )

                Spacer()

                Button {
                    if isTitleValid {
                        addEvent()
                    } else {
                        showValidation = true
                    }
                } label: {
                    Label("Add Event", systemImage: "plus")
                        .font(.system(.subheadline, design: .rounded).weight(.semibold))
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
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

// MARK: - Form Section

private struct FormSection<Content: View>: View {
    let icon: String
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: icon)
                .font(.system(.caption, design: .rounded).weight(.semibold))
                .foregroundColor(.secondary)

            content
        }
    }
}
