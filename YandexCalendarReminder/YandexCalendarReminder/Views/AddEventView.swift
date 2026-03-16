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
            Text("Новое событие")
                .font(.headline)

            TextField("Название встречи", text: $title)
                .textFieldStyle(.roundedBorder)

            DatePicker("Начало", selection: $date, displayedComponents: [.date, .hourAndMinute])

            HStack {
                Text("Длительность")
                Picker("", selection: $duration) {
                    Text("15 мин").tag(15.0)
                    Text("30 мин").tag(30.0)
                    Text("45 мин").tag(45.0)
                    Text("1 час").tag(60.0)
                    Text("1.5 часа").tag(90.0)
                    Text("2 часа").tag(120.0)
                }
                .labelsHidden()
            }

            TextField("Место (необязательно)", text: $location)
                .textFieldStyle(.roundedBorder)

            TextField("Описание (необязательно)", text: $description)
                .textFieldStyle(.roundedBorder)

            HStack {
                Spacer()
                Button("Отмена") {
                    isPresented = false
                }
                .keyboardShortcut(.cancelAction)

                Button("Добавить") {
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
            calendarName: "Локальное"
        )
        reminderService.addLocalEvent(event)
        isPresented = false
    }
}
