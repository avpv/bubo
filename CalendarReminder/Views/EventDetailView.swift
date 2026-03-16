import SwiftUI

struct EventDetailView: View {
    let event: CalendarEvent
    @Binding var isPresented: Bool
    var onEdit: ((CalendarEvent) -> Void)? = nil
    var onDelete: ((CalendarEvent) -> Void)? = nil

    private var isLocal: Bool {
        event.calendarName == "Local"
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Button {
                    isPresented = false
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.body)
                }
                .buttonStyle(.borderless)

                OwlIcon(size: 18)
                Text("Event Details")
                    .font(.headline)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider()

            // Event info
            VStack(alignment: .leading, spacing: 12) {
                Text(event.title)
                    .font(.title3)
                    .fontWeight(.semibold)

                Label(event.formattedDate, systemImage: "calendar")
                    .font(.subheadline)
                    .foregroundColor(.secondary)

                Label(event.formattedTimeRange, systemImage: "clock")
                    .font(.subheadline)
                    .foregroundColor(.secondary)

                if let location = event.location, !location.isEmpty {
                    Label(location, systemImage: "location.fill")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }

                if let description = event.description, !description.isEmpty {
                    Label(description, systemImage: "note.text")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .lineLimit(4)
                }

                if let calName = event.calendarName {
                    Label(calName, systemImage: "tray.full")
                        .font(.caption)
                        .foregroundColor(.blue)
                }

                if let reminders = event.customReminderMinutes, !reminders.isEmpty {
                    HStack(spacing: 4) {
                        Image(systemName: "bell.fill")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        ForEach(reminders.sorted(), id: \.self) { min in
                            Text(formatMinutes(min))
                                .font(.caption)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(.secondary.opacity(0.15))
                                .cornerRadius(4)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)

            Spacer()

            // Actions (only for local events)
            if isLocal {
                Divider()

                HStack {
                    Button(role: .destructive) {
                        onDelete?(event)
                        isPresented = false
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }

                    Spacer()

                    Button {
                        onEdit?(event)
                    } label: {
                        Label("Edit", systemImage: "pencil")
                    }
                    .buttonStyle(.borderedProminent)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
        }
        .frame(width: 340, minHeight: 200)
    }

    private func formatMinutes(_ minutes: Int) -> String {
        if minutes >= 60 {
            let h = minutes / 60
            let m = minutes % 60
            return m == 0 ? "\(h) h" : "\(h) h \(m) min"
        }
        return "\(minutes) min"
    }
}
