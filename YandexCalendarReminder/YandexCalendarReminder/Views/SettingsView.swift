import SwiftUI

struct SettingsView: View {
    @ObservedObject var settings: ReminderSettings
    @ObservedObject var reminderService: ReminderService

    @State private var newIntervalMinutes = 10
    @State private var connectionStatus: ConnectionStatus = .unknown
    @State private var oauthCode = ""
    @State private var oauthStatus: OAuthStatus = .idle

    enum ConnectionStatus {
        case unknown, checking, success, failed(String)
    }

    enum OAuthStatus {
        case idle, exchanging, success, failed(String)
    }

    var body: some View {
        TabView {
            accountTab
                .tabItem { Label("Аккаунт", systemImage: "person.circle") }

            remindersTab
                .tabItem { Label("Напоминания", systemImage: "bell") }

            generalTab
                .tabItem { Label("Основные", systemImage: "gear") }
        }
        .frame(width: 480, height: 420)
    }

    // MARK: - Account Tab

    private var accountTab: some View {
        Form {
            Section("Способ авторизации") {
                Picker("", selection: $settings.authMethod) {
                    Text("Пароль приложения").tag(AuthMethod.appPassword)
                    Text("OAuth 2.0").tag(AuthMethod.oauth)
                }
                .pickerStyle(.segmented)
                .onChange(of: settings.authMethod) { _ in saveSettings() }
            }

            if settings.authMethod == .appPassword {
                appPasswordSection
            } else {
                oauthSection
            }

            Section {
                HStack {
                    Button("Проверить подключение") {
                        checkConnection()
                    }

                    Spacer()

                    connectionStatusView
                }
            }
        }
        .padding()
    }

    private var appPasswordSection: some View {
        Section("Яндекс аккаунт") {
            TextField("Логин", text: Binding(
                get: { settings.yandexLogin },
                set: { settings.yandexLogin = $0 }
            ))
            .textFieldStyle(.roundedBorder)

            SecureField("Пароль приложения", text: Binding(
                get: { settings.yandexAppPassword },
                set: { settings.yandexAppPassword = $0 }
            ))
            .textFieldStyle(.roundedBorder)

            Text("Создайте пароль приложения: id.yandex.ru → Безопасность → Пароли приложений")
                .font(.caption)
                .foregroundColor(.secondary)

            HStack(spacing: 4) {
                Image(systemName: "lock.shield.fill")
                    .foregroundColor(.green)
                    .font(.caption)
                Text("Пароль хранится в Keychain")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }

    private var oauthSection: some View {
        Section("OAuth 2.0") {
            // Login is still needed for CalDAV path
            TextField("Логин Яндекса", text: Binding(
                get: { settings.yandexLogin },
                set: { settings.yandexLogin = $0 }
            ))
            .textFieldStyle(.roundedBorder)

            if YandexOAuthService.isAuthenticated {
                HStack {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)
                    Text("Авторизовано через OAuth")
                    Spacer()
                    Button("Выйти") {
                        YandexOAuthService.logout()
                        oauthStatus = .idle
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    Button("Открыть авторизацию в браузере") {
                        YandexOAuthService.startAuthFlow()
                    }

                    Text("После авторизации скопируйте код и вставьте ниже:")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    HStack {
                        TextField("Код авторизации", text: $oauthCode)
                            .textFieldStyle(.roundedBorder)

                        Button("Подтвердить") {
                            exchangeOAuthCode()
                        }
                        .disabled(oauthCode.isEmpty)
                    }

                    switch oauthStatus {
                    case .idle: EmptyView()
                    case .exchanging: ProgressView().scaleEffect(0.7)
                    case .success:
                        Label("Авторизация успешна!", systemImage: "checkmark.circle.fill")
                            .foregroundColor(.green)
                    case .failed(let error):
                        Label(error, systemImage: "xmark.circle.fill")
                            .foregroundColor(.red)
                            .font(.caption)
                    }
                }
            }

            Text("OAuth безопаснее: приложение не хранит ваш пароль")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    @ViewBuilder
    private var connectionStatusView: some View {
        switch connectionStatus {
        case .unknown:
            EmptyView()
        case .checking:
            ProgressView().scaleEffect(0.7)
        case .success:
            Label("Подключено", systemImage: "checkmark.circle.fill")
                .foregroundColor(.green)
        case .failed(let error):
            Label(error, systemImage: "xmark.circle.fill")
                .foregroundColor(.red)
                .font(.caption)
        }
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

            Section("Не беспокоить") {
                Toggle("Включить режим «Не беспокоить»", isOn: $settings.doNotDisturbEnabled)
                    .onChange(of: settings.doNotDisturbEnabled) { _ in saveSettings() }

                if settings.doNotDisturbEnabled {
                    DatePicker("С", selection: $settings.doNotDisturbFrom, displayedComponents: .hourAndMinute)
                        .onChange(of: settings.doNotDisturbFrom) { _ in saveSettings() }

                    DatePicker("До", selection: $settings.doNotDisturbTo, displayedComponents: .hourAndMinute)
                        .onChange(of: settings.doNotDisturbTo) { _ in saveSettings() }

                    if settings.isDoNotDisturbActive {
                        Label("Сейчас активен", systemImage: "moon.fill")
                            .foregroundColor(.indigo)
                            .font(.caption)
                    }
                }
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

            Section("Статус") {
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

                if reminderService.isUsingCache {
                    Label("Данные из кэша", systemImage: "internaldrive")
                        .foregroundColor(.orange)
                        .font(.caption)
                }
            }
        }
        .padding()
    }

    // MARK: - Actions

    private func saveSettings() {
        settings.save()
        reminderService.updateSettings(settings)
    }

    private func checkConnection() {
        connectionStatus = .checking
        saveSettings()
        reminderService.setupCalDAVService()

        let authMode: YandexCalDAVService.AuthMode
        switch settings.authMethod {
        case .appPassword:
            authMode = .appPassword(login: settings.yandexLogin, password: settings.yandexAppPassword)
        case .oauth:
            authMode = .oauth
        }

        let service = YandexCalDAVService(authMode: authMode)

        Task {
            do {
                let now = Date()
                let end = Calendar.current.date(byAdding: .day, value: 1, to: now)!
                _ = try await service.fetchEvents(from: now, to: end)
                connectionStatus = .success
            } catch {
                connectionStatus = .failed(error.localizedDescription)
            }
        }
    }

    private func exchangeOAuthCode() {
        oauthStatus = .exchanging
        Task {
            do {
                _ = try await YandexOAuthService.exchangeCode(oauthCode)
                oauthStatus = .success
                oauthCode = ""
            } catch {
                oauthStatus = .failed(error.localizedDescription)
            }
        }
    }
}
