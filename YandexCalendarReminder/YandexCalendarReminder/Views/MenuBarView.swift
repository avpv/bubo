import SwiftUI

struct MenuBarView: View {
    @ObservedObject var settings: ReminderSettings
    @ObservedObject var reminderService: ReminderService
    @ObservedObject var networkMonitor: NetworkMonitor

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

                if !networkMonitor.isConnected {
                    Image(systemName: "wifi.slash")
                        .foregroundColor(.red)
                        .help("Нет подключения к интернету")
                }

                if settings.isDoNotDisturbActive {
                    Image(systemName: "moon.fill")
                        .foregroundColor(.indigo)
                        .help("Не беспокоить")
                }

                if reminderService.isSyncing {
                    ProgressView()
                        .scaleEffect(0.6)
                }
            }
            .padding(.horizontal)
            .padding(.top, 8)

            Divider()

            // Status messages
            if !networkMonitor.isConnected {
                StatusBanner(
                    icon: "wifi.slash",
                    text: "Нет подключения. Показаны кэшированные данные",
                    color: .orange
                )
            } else if reminderService.isUsingCache {
                StatusBanner(
                    icon: "arrow.triangle.2.circlepath",
                    text: "Показаны кэшированные данные",
                    color: .yellow
                )
            }

            if let error = reminderService.syncError, networkMonitor.isConnected {
                StatusBanner(icon: "exclamationmark.triangle.fill", text: error, color: .orange)
            }

            if let lastSync = reminderService.lastSyncDate {
                Text("Обновлено: \(lastSync.formatted(date: .omitted, time: .shortened))")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .padding(.horizontal)
            }

            // Events grouped by day
            if reminderService.eventsByDay.isEmpty {
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
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(reminderService.eventsByDay, id: \.date) { dayGroup in
                            DaySectionView(
                                date: dayGroup.date,
                                events: dayGroup.events,
                                reminderService: reminderService
                            )
                        }
                    }
                }
                .frame(maxHeight: 350)
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
                .disabled(!networkMonitor.isConnected)

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
        .frame(width: 340)
        .sheet(isPresented: $showingAddEvent) {
            AddEventView(reminderService: reminderService, isPresented: $showingAddEvent)
        }
        .onAppear {
            reminderService.setNetworkMonitor(networkMonitor)
            reminderService.updateSettings(settings)
            reminderService.startSync()
        }
    }
}

// MARK: - Supporting Views

struct StatusBanner: View {
    let icon: String
    let text: String
    let color: Color

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.caption)
            Text(text)
                .font(.caption)
        }
        .foregroundColor(color)
        .padding(.horizontal)
    }
}

struct DaySectionView: View {
    let date: Date
    let events: [CalendarEvent]
    let reminderService: ReminderService

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(dayTitle)
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundColor(.secondary)
                .textCase(.uppercase)
                .padding(.horizontal)

            ForEach(events) { event in
                EventRowView(event: event, reminderService: reminderService)
            }
        }
    }

    private var dayTitle: String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) {
            return "Сегодня"
        } else if calendar.isDateInTomorrow(date) {
            return "Завтра"
        } else {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "ru_RU")
            formatter.dateFormat = "d MMMM, EEEE"
            return formatter.string(from: date)
        }
    }
}

struct EventRowView: View {
    let event: CalendarEvent
    let reminderService: ReminderService

    @State private var showSnoozeMenu = false

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
        .contextMenu {
            Button("Напомнить через 5 мин") {
                reminderService.snoozeReminder(for: event, minutes: 5)
            }
            Button("Напомнить через 10 мин") {
                reminderService.snoozeReminder(for: event, minutes: 10)
            }
            Button("Напомнить через 15 мин") {
                reminderService.snoozeReminder(for: event, minutes: 15)
            }
        }
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
