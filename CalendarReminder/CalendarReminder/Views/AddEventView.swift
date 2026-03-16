import SwiftUI

struct AddEventView: View {
    @ObservedObject var reminderService: ReminderService
    @Binding var isPresented: Bool

    @State private var title = ""
    @State private var date = Date()
    @State private var duration: Double = 60 // minutes
    @State private var location = ""
    @State private var description = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("New Event")
                .font(.headline)

            TextField("Meeting title", text: $title)
                .textFieldStyle(.roundedBorder)

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
                }
                .labelsHidden()
            }

            TextField("Location (optional)", text: $location)
                .textFieldStyle(.roundedBorder)

            TextField("Description (optional)", text: $description)
                .textFieldStyle(.roundedBorder)

            HStack {
                Spacer()
                Button("Cancel") {
                    isPresented = false
                }
                .keyboardShortcut(.cancelAction)

                Button("Add") {
                    addEvent()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(title.isEmpty)
            }
        }
        .padding()
        .frame(width: 350)
    }

    private func addEvent() {
        let event = CalendarEvent(
            id: UUID().uuidString,
            title: title,
            startDate: date,
            endDate: date.addingTimeInterval(duration * 60),
            location: location.isEmpty ? nil : location,
            description: description.isEmpty ? nil : description,
            calendarName: "Local"
        )
        reminderService.addLocalEvent(event)
        isPresented = false
    }
}
