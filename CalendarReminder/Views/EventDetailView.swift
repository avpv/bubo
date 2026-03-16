import SwiftUI

struct EventDetailView: View {
    let event: CalendarEvent
    var onBack: () -> Void
    var onEdit: ((CalendarEvent) -> Void)? = nil
    var onDelete: ((CalendarEvent) -> Void)? = nil

    @State private var showDeleteConfirmation = false

    private var isLocal: Bool {
        event.calendarName == "Local"
    }

    var body: some View {
        VStack(spacing: 0) {
            PopoverHeader(
                title: isLocal ? "Event" : nil,
                showBack: true,
                onBack: onBack
            )

            ScrollView {
                VStack(alignment: .leading, spacing: DS.Spacing.xl) {
                    // Title
                    Text(event.title)
                        .font(.title3)
                        .fontWeight(.semibold)
                        .accessibilityAddTraits(.isHeader)

                    // Date & Time group
                    VStack(alignment: .leading, spacing: DS.Spacing.md) {
                        Label(event.formattedDate, systemImage: "calendar")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .accessibilityLabel("Date: \(event.formattedDate)")

                        Label(event.formattedTimeRange, systemImage: "clock")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .accessibilityLabel("Time: \(event.formattedTimeRange)")
                    }

                    // Location
                    if let location = event.location, !location.isEmpty {
                        Label(location, systemImage: "location.fill")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }

                    // Description
                    if let description = event.description, !description.isEmpty {
                        VStack(alignment: .leading, spacing: DS.Spacing.xs) {
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
                        VStack(alignment: .leading, spacing: DS.Spacing.sm) {
                            Label("Reminders", systemImage: "bell.fill")
                                .font(.caption)
                                .fontWeight(.medium)
                                .foregroundColor(.tertiary)

                            HStack(spacing: DS.Spacing.xs) {
                                ForEach(reminders.sorted(), id: \.self) { min in
                                    Text(DS.formatMinutes(min))
                                        .font(.caption)
                                        .padding(.horizontal, DS.Spacing.sm)
                                        .padding(.vertical, DS.Spacing.xxs)
                                        .background(.secondary.opacity(0.12))
                                        .clipShape(RoundedRectangle(cornerRadius: DS.Size.badgeCornerRadius))
                                }
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(DS.Spacing.xl)
            }
            .frame(maxHeight: DS.Popover.detailMaxHeight)

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
                .padding(.horizontal, DS.Spacing.lg)
                .padding(.vertical, DS.Spacing.md)
                .background(.bar)
            }
        }
        .frame(width: DS.Popover.width)
        .frame(minHeight: DS.Popover.detailMinHeight)
    }
}
