import SwiftUI

struct SettingsView: View {
    @ObservedObject var settings: ReminderSettings
    @ObservedObject var reminderService: ReminderService

    @State private var newIntervalMinutes = 10
    @State private var connectionStatus: ConnectionStatus = .unknown

    enum ConnectionStatus {
        case unknown, checking, success, failed(String)
    }

    var body: some View {
        TabView {
            accountTab
                .tabItem {
                    Label("Аккаунт", systemImage: "person.circle")
                }

            remindersTab
                .tabItem {
                    Label("Напоминания", systemImage: "bell")
                }

            generalTab
                .tabItem {
                    Label("Основные", systemImage: "gear")
                }
        }
        .frame(width: 450, height: 350)
        .onChange(of: settings.yandexLogin) { _ in saveSettings() }
        .onChange(of: settings.yandexAppPassword) { _ in saveSettings() }
    }

    // MARK: - Account Tab

    private var accountTab: some View {
        Form {
            Section {
                TextField("Логин Яндекса", text: $settings.yandexLogin)
                    .textFieldStyle(.roundedBorder)

                SecureField("Пароль приложения", text: $settings.yandexAppPassword)
                    .textFieldStyle(.roundedBorder)

                Text("Используйте пароль приложения, а не основной пароль.\nСоздать: id.yandex.ru → Безопасность → Пароли приложений")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Section {
                HStack {
                    Button("Проверить подключение") {
                        checkConnection()
                    }

                    Spacer()

                    switch connectionStatus {
                    case .unknown:
                        EmptyView()
                    case .checking:
                        ProgressView()
                            .scaleEffect(0.7)
                    case .success:
                        Label("Подключено", systemImage: "checkmark.circle.fill")
                            .foregroundColor(.green)
                    case .failed(let error):
                        Label(error, systemImage: "xmark.circle.fill")
                            .foregroundColor(.red)
                            .font(.caption)
                    }
                }
            }
        }
        .padding()
    }

    // MARK: - Reminders Tab

    private var remindersTab: some View {
        Form {
            Section("Интервалы напоминаний") {
                ForEach($settings.intervals) { $interval in
                    HStack {
                        Toggle(isOn: $interval.isEnabled) {
                            Text("За \(interval.displayText) до встречи")
                        }
                        .onChange(of: interval.isEnabled) { _ in saveSettings() }

                        Spacer()

                        Button(action: {
                            settings.intervals.removeAll { $0.id == interval.id }
                            saveSettings()
                        }) {
                            Image(systemName: "minus.circle.fill")
                                .foregroundColor(.red)
                        }
                        .buttonStyle(.plain)
                    }
                }

                HStack {
                    Stepper("Добавить: \(newIntervalMinutes) мин", value: $newIntervalMinutes, in: 1...120)

                    Button(action: {
                        settings.intervals.append(ReminderInterval(minutes: newIntervalMinutes))
                        saveSettings()
                    }) {
                        Image(systemName: "plus.circle.fill")
                            .foregroundColor(.green)
                    }
                    .buttonStyle(.plain)
                }
            }

            Section("Типы уведомлений") {
                Toggle("Полноэкранное уведомление", isOn: $settings.showFullScreenAlert)
                    .onChange(of: settings.showFullScreenAlert) { _ in saveSettings() }

                Toggle("Системное уведомление", isOn: $settings.showSystemNotification)
                    .onChange(of: settings.showSystemNotification) { _ in saveSettings() }

                Toggle("Звуковое уведомление", isOn: $settings.playSound)
                    .onChange(of: settings.playSound) { _ in saveSettings() }
            }
        }
        .padding()
    }

    // MARK: - General Tab

    private var generalTab: some View {
        Form {
            Section("Синхронизация") {
                Picker("Интервал синхронизации", selection: $settings.syncIntervalMinutes) {
                    Text("1 минута").tag(1)
                    Text("3 минуты").tag(3)
                    Text("5 минут").tag(5)
                    Text("10 минут").tag(10)
                    Text("15 минут").tag(15)
                    Text("30 минут").tag(30)
                }
                .onChange(of: settings.syncIntervalMinutes) { _ in
                    saveSettings()
                    reminderService.startSyncTimer()
                }
            }

            Section {
                Toggle("Запускать при входе в систему", isOn: $settings.launchAtLogin)
                    .onChange(of: settings.launchAtLogin) { _ in saveSettings() }
            }

            Section {
                if let lastSync = reminderService.lastSyncDate {
                    LabeledContent("Последняя синхронизация") {
                        Text(lastSync.formatted())
                    }
                }

                LabeledContent("Событий из Яндекса") {
                    Text("\(reminderService.upcomingEvents.count)")
                }

                LabeledContent("Локальных событий") {
                    Text("\(reminderService.localEvents.count)")
                }
            }
        }
        .padding()
    }

    private func saveSettings() {
        settings.save()
        reminderService.updateSettings(settings)
    }

    private func checkConnection() {
        connectionStatus = .checking
        let service = YandexCalDAVService(
            login: settings.yandexLogin,
            appPassword: settings.yandexAppPassword
        )

        Task {
            do {
                let now = Date()
                let end = Calendar.current.date(byAdding: .day, value: 1, to: now)!
                _ = try await service.fetchEvents(from: now, to: end)
                await MainActor.run {
                    connectionStatus = .success
                }
            } catch {
                await MainActor.run {
                    connectionStatus = .failed(error.localizedDescription)
                }
            }
        }
    }
}
