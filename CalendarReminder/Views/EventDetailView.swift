import SwiftUI

struct EventDetailView: View {
    let event: CalendarEvent
    @Binding var isPresented: Bool
    var onEdit: ((CalendarEvent) -> Void)? = nil
    var onDelete: ((CalendarEvent) -> Void)? = nil

    @State private var showDeleteConfirmation = false

    private var isLocal: Bool {
        event.calendarName == "Local"
    }

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
                .keyboardShortcut(.escape, modifiers: [])

                Spacer()

                OwlIcon(size: 18)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.bar)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // Title
                    Text(event.title)
                        .font(.title3)
                        .fontWeight(.semibold)

                    // Date & Time group
                    VStack(alignment: .leading, spacing: 8) {
                        Label(event.formattedDate, systemImage: "calendar")
                            .font(.subheadline)
                            .foregroundColor(.secondary)

                        Label(event.formattedTimeRange, systemImage: "clock")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }

                    // Location
                    if let location = event.location, !location.isEmpty {
                        Label(location, systemImage: "location.fill")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }

                    // Description
                    if let description = event.description, !description.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Label("Notes", systemImage: "note.text")
                                .font(.caption)
                                .fontWeight(.medium)
                                .foregroundColor(.tertiary)
                            Text(description)
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                                .lineLimit(6)
                        }
                    }

                    // Calendar name
                    if let calName = event.calendarName {
                        Label(calName, systemImage: "tray.full")
                            .font(.caption)
                            .foregroundColor(.blue)
                    }

                    // Custom reminders
                    if let reminders = event.customReminderMinutes, !reminders.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Label("Reminders", systemImage: "bell.fill")
                                .font(.caption)
                                .fontWeight(.medium)
                                .foregroundColor(.tertiary)

                            HStack(spacing: 4) {
                                ForEach(reminders.sorted(), id: \.self) { min in
                                    Text(formatMinutes(min))
                                        .font(.caption)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(.secondary.opacity(0.12))
                                        .clipShape(RoundedRectangle(cornerRadius: 4))
                                }
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
            }
            .frame(maxHeight: 300)

            Spacer(minLength: 0)

            // Actions (only for local events)
            if isLocal {
                Divider()

                HStack {
                    Button(role: .destructive) {
                        showDeleteConfirmation = true
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                    .alert("Delete Event", isPresented: $showDeleteConfirmation) {
                        Button("Cancel", role: .cancel) { }
                        Button("Delete", role: .destructive) {
                            onDelete?(event)
                            isPresented = false
                        }
                    } message: {
                        Text("Are you sure you want to delete \"\(event.title)\"? This action cannot be undone.")
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
                .background(.bar)
            }
        }
        .frame(width: 340)
        .frame(minHeight: 200)
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
