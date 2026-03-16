import SwiftUI

struct AddEventView: View {
    @ObservedObject var reminderService: ReminderService
    @Binding var isPresented: Bool

    @State private var title = ""
    @State private var date = Date()
    @State private var duration: Double = 60
    @State private var isAllDay = false
    @State private var location = ""
    @State private var description = ""
    @State private var showValidation = false

    private var endDate: Date {
        date.addingTimeInterval(duration * 60)
    }

    private var endTimeFormatted: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: endDate)
    }

    private var isTitleValid: Bool {
        !title.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            header

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // Title field
                    titleSection

                    // Date & time section
                    dateTimeSection

                    // Location
                    locationSection

                    // Description
                    descriptionSection
                }
                .padding(20)
            }

            Divider()

            // Actions
            actionButtons
        }
        .frame(width: 380, height: 460)
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Image(systemName: "calendar.badge.plus")
                .font(.title3)
                .foregroundColor(.blue)
            Text("New Event")
                .font(.headline)
            Spacer()
            Button(action: { isPresented = false }) {
                Image(systemName: "xmark.circle.fill")
                    .font(.title3)
                    .foregroundColor(.secondary.opacity(0.6))
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    // MARK: - Title

    private var titleSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("Event title", text: $title)
                .textFieldStyle(.plain)
                .font(.title3)
                .padding(10)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color(nsColor: .controlBackgroundColor))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(showValidation && !isTitleValid ? Color.red.opacity(0.6) : Color.clear, lineWidth: 1)
                )

            if showValidation && !isTitleValid {
                Text("Title is required")
                    .font(.caption)
                    .foregroundColor(.red)
            }
        }
    }

    // MARK: - Date & Time

    private var dateTimeSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionLabel("Date & Time", icon: "clock")

            VStack(spacing: 8) {
                Toggle(isOn: $isAllDay) {
                    Text("All day")
                        .font(.subheadline)
                }
                .toggleStyle(.switch)
                .controlSize(.small)

                if isAllDay {
                    DatePicker("Date", selection: $date, displayedComponents: [.date])
                        .labelsHidden()
                } else {
                    HStack(spacing: 12) {
                        DatePicker("", selection: $date, displayedComponents: [.date, .hourAndMinute])
                            .labelsHidden()

                        Spacer()

                        HStack(spacing: 4) {
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
                    }

                    // End time preview
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.right")
                            .font(.caption2)
                        Text("Ends at \(endTimeFormatted)")
                            .font(.caption)
                    }
                    .foregroundColor(.secondary)
                }
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(nsColor: .controlBackgroundColor))
            )
        }
    }

    // MARK: - Location

    private var locationSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionLabel("Location", icon: "location")

            TextField("Add location", text: $location)
                .textFieldStyle(.plain)
                .font(.subheadline)
                .padding(10)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color(nsColor: .controlBackgroundColor))
                )
        }
    }

    // MARK: - Description

    private var descriptionSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionLabel("Notes", icon: "text.alignleft")

            TextEditor(text: $description)
                .font(.subheadline)
                .scrollContentBackground(.hidden)
                .padding(6)
                .frame(minHeight: 60, maxHeight: 80)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color(nsColor: .controlBackgroundColor))
                )
        }
    }

    // MARK: - Actions

    private var actionButtons: some View {
        HStack {
            Button("Cancel") {
                isPresented = false
            }
            .keyboardShortcut(.cancelAction)

            Spacer()

            Button(action: {
                if isTitleValid {
                    addEvent()
                } else {
                    showValidation = true
                }
            }) {
                HStack(spacing: 4) {
                    Image(systemName: "plus.circle.fill")
                    Text("Add Event")
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(isTitleValid ? Color.blue : Color.gray.opacity(0.4))
                .foregroundColor(.white)
                .cornerRadius(8)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    // MARK: - Helpers

    private func sectionLabel(_ text: String, icon: String) -> some View {
        Label(text, systemImage: icon)
            .font(.subheadline)
            .fontWeight(.medium)
            .foregroundColor(.secondary)
    }

    private func addEvent() {
        let eventEndDate: Date
        if isAllDay {
            let calendar = Calendar.current
            let startOfDay = calendar.startOfDay(for: date)
            let endOfDay = calendar.date(byAdding: .day, value: 1, to: startOfDay) ?? startOfDay
            eventEndDate = endOfDay
        } else {
            eventEndDate = date.addingTimeInterval(duration * 60)
        }

        let event = CalendarEvent(
            id: UUID().uuidString,
            title: title,
            startDate: isAllDay ? Calendar.current.startOfDay(for: date) : date,
            endDate: eventEndDate,
            location: location.isEmpty ? nil : location,
            description: description.isEmpty ? nil : description,
            calendarName: "Local"
        )
        reminderService.addLocalEvent(event)
        isPresented = false
    }
}
