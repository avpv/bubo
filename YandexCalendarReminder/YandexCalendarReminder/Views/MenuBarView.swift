import SwiftUI

struct MenuBarView: View {
    @ObservedObject var settings: ReminderSettings
    @ObservedObject var reminderService: ReminderService

    @State private var showingAddEvent = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Header
            HStack {
                Image(systemName: "calendar.badge.clock")
                    .foregroundColor(.blue)
                Text("Reminder")
                    .font(.headline)
                Spacer()
                if reminderService.isSyncing {
                    ProgressView()
                        .scaleEffect(0.6)
                }
            }
            .padding(.horizontal)
            .padding(.top, 8)

            Divider()

            // Sync status
            if let error = reminderService.syncError {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.orange)
                    Text(error)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding(.horizontal)
            }

            if let lastSync = reminderService.lastSyncDate {
                Text("Обновлено: \(lastSync.formatted(date: .omitted, time: .shortened))")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .padding(.horizontal)
            }

            // Events list
            if reminderService.allEvents.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "calendar")
                        .font(.largeTitle)
                        .foregroundColor(.secondary)
                    Text("Нет предстоящих встреч")
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 20)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        ForEach(reminderService.allEvents) { event in
                            EventRowView(event: event)
                        }
                    }
                }
                .frame(maxHeight: 300)
            }

            Divider()

            // Actions
            HStack(spacing: 12) {
                Button(action: { showingAddEvent = true }) {
                    Label("Добавить", systemImage: "plus.circle")
                }
                .buttonStyle(.plain)

                Button(action: { reminderService.syncNow() }) {
                    Label("Обновить", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.plain)

                Spacer()

                SettingsLink {
                    Label("Настройки", systemImage: "gear")
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal)

            Button("Выход") {
                NSApplication.shared.terminate(nil)
            }
            .padding(.horizontal)
            .padding(.bottom, 8)
        }
        .frame(width: 320)
        .sheet(isPresented: $showingAddEvent) {
            AddEventView(reminderService: reminderService, isPresented: $showingAddEvent)
        }
        .onAppear {
            reminderService.updateSettings(settings)
            reminderService.startSync()
        }
    }
}

struct EventRowView: View {
    let event: CalendarEvent

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            // Time indicator
            VStack {
                Text(event.formattedTime)
                    .font(.system(.caption, design: .monospaced))
                    .fontWeight(.bold)
                    .foregroundColor(urgencyColor)
            }
            .frame(width: 50)

            // Event details
            VStack(alignment: .leading, spacing: 2) {
                Text(event.title)
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .lineLimit(2)

                if let location = event.location, !location.isEmpty {
                    HStack(spacing: 2) {
                        Image(systemName: "location.fill")
                            .font(.caption2)
                        Text(location)
                            .font(.caption)
                    }
                    .foregroundColor(.secondary)
                }

                if let calName = event.calendarName {
                    Text(calName)
                        .font(.caption2)
                        .foregroundColor(.blue)
                }

                // Time until
                Text(timeUntilText)
                    .font(.caption2)
                    .foregroundColor(urgencyColor)
            }

            Spacer()
        }
        .padding(.horizontal)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(urgencyColor.opacity(0.05))
        )
        .padding(.horizontal, 4)
    }

    private var urgencyColor: Color {
        let minutes = event.minutesUntilStart
        if minutes <= 5 { return .red }
        if minutes <= 15 { return .orange }
        return .green
    }

    private var timeUntilText: String {
        let minutes = event.minutesUntilStart
        if minutes < 1 { return "Сейчас!" }
        if minutes < 60 { return "через \(minutes) мин" }
        let hours = minutes / 60
        let mins = minutes % 60
        if mins == 0 { return "через \(hours) ч" }
        return "через \(hours) ч \(mins) мин"
    }
}
