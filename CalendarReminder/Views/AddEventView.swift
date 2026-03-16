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
            calendarName: "Local"
        )
        reminderService.addLocalEvent(event)
        isPresented = false
    }
}
