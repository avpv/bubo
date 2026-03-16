import SwiftUI

struct SettingsView: View {
    @ObservedObject var settings: ReminderSettings
    @ObservedObject var reminderService: ReminderService

    @State private var newIntervalMinutes = 10
    @State private var connectionStatus: ConnectionStatus = .unknown
    @State private var oauthCode = ""
    @State private var oauthStatus: OAuthStatus = .idle
    @State private var availableCalendars: [CalDAVXMLParser.CalendarInfo] = []
    @State private var isLoadingCalendars = false
    @State private var calendarLoadError: String?
    // Google
    @State private var googleOAuthCode = ""
    @State private var googleOAuthStatus: OAuthStatus = .idle
    @State private var availableGoogleCalendars: [GoogleCalendarService.CalendarListEntry] = []
    @State private var isLoadingGoogleCalendars = false
    @State private var googleCalendarLoadError: String?

    enum ConnectionStatus {
        case unknown, checking, success, failed(String)
    }

    enum OAuthStatus {
        case idle, exchanging, success, failed(String)
    }

    var body: some View {
        TabView {
            accountTab
                .tabItem { Label("Account", systemImage: "person.circle") }

            calendarsTab
                .tabItem { Label("Calendars", systemImage: "calendar") }

            remindersTab
                .tabItem { Label("Reminders", systemImage: "bell") }

            generalTab
                .tabItem { Label("General", systemImage: "gear") }
        }
        .frame(width: 480, height: 460)
    }

    // MARK: - Account Tab

    private var accountTab: some View {
        ScrollView {
            Form {
                // Yandex
                Section("Yandex Calendar") {
                    Picker("Authorization", selection: $settings.authMethod) {
                        Text("App Password").tag(AuthMethod.appPassword)
                        Text("OAuth 2.0").tag(AuthMethod.oauth)
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: settings.authMethod) { _ in saveSettings() }

                    if settings.authMethod == .appPassword {
                        appPasswordSection
                    } else {
                        oauthSection
                    }

                    HStack {
                        Button("Test Yandex") { checkConnection() }
                        Spacer()
                        connectionStatusView
                    }
                }

                Divider()

                // Google
                Section("Google Calendar") {
                    Toggle("Enable Google Calendar", isOn: $settings.googleEnabled)
                        .onChange(of: settings.googleEnabled) { _ in saveSettings() }

                    if settings.googleEnabled {
                        googleAccountSection
                    }
                }
            }
            .padding()
        }
    }

    private var appPasswordSection: some View {
        Section("Yandex Account") {
            TextField("Login", text: Binding(
                get: { settings.yandexLogin },
                set: { settings.yandexLogin = $0 }
            ))
            .textFieldStyle(.roundedBorder)

            SecureField("App Password", text: Binding(
                get: { settings.yandexAppPassword },
                set: { settings.yandexAppPassword = $0 }
            ))
            .textFieldStyle(.roundedBorder)

            Text("Create an app password: id.yandex.ru → Security → App Passwords")
                .font(.caption)
                .foregroundColor(.secondary)

            HStack(spacing: 4) {
                Image(systemName: "lock.shield.fill")
                    .foregroundColor(.green)
                    .font(.caption)
                Text("Password is stored in Keychain")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }

    private var oauthSection: some View {
        Section("OAuth 2.0") {
            // Login is still needed for CalDAV path
            TextField("Yandex Login", text: Binding(
                get: { settings.yandexLogin },
                set: { settings.yandexLogin = $0 }
            ))
            .textFieldStyle(.roundedBorder)

            if YandexOAuthService.isAuthenticated {
                HStack {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)
                    Text("Authenticated via OAuth")
                    Spacer()
                    Button("Log Out") {
                        YandexOAuthService.logout()
                        oauthStatus = .idle
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    Button("Open authorization in browser") {
                        YandexOAuthService.startAuthFlow()
                    }

                    Text("After authorization, copy the code and paste it below:")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    HStack {
                        TextField("Authorization code", text: $oauthCode)
                            .textFieldStyle(.roundedBorder)

                        Button("Confirm") {
                            exchangeOAuthCode()
                        }
                        .disabled(oauthCode.isEmpty)
                    }

                    switch oauthStatus {
                    case .idle: EmptyView()
                    case .exchanging: ProgressView().scaleEffect(0.7)
                    case .success:
                        Label("Authorization successful!", systemImage: "checkmark.circle.fill")
                            .foregroundColor(.green)
                    case .failed(let error):
                        Label(error, systemImage: "xmark.circle.fill")
                            .foregroundColor(.red)
                            .font(.caption)
                    }
                }
            }

            Text("OAuth is more secure: the app does not store your password")
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
            Label("Connected", systemImage: "checkmark.circle.fill")
                .foregroundColor(.green)
        case .failed(let error):
            Label(error, systemImage: "xmark.circle.fill")
                .foregroundColor(.red)
                .font(.caption)
        }
    }

    private var googleAccountSection: some View {
        Group {
            if GoogleOAuthService.isAuthenticated {
                HStack {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)
                    Text("Google account connected")
                    Spacer()
                    Button("Disconnect") {
                        GoogleOAuthService.logout()
                        settings.googleEnabled = false
                        googleOAuthStatus = .idle
                        saveSettings()
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    Button("Sign in with Google") {
                        GoogleOAuthService.startAuthFlow()
                    }

                    Text("After authorization, copy the code and paste it below:")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    HStack {
                        TextField("Authorization code", text: $googleOAuthCode)
                            .textFieldStyle(.roundedBorder)

                        Button("Confirm") {
                            exchangeGoogleOAuthCode()
                        }
                        .disabled(googleOAuthCode.isEmpty)
                    }

                    switch googleOAuthStatus {
                    case .idle: EmptyView()
                    case .exchanging: ProgressView().scaleEffect(0.7)
                    case .success:
                        Label("Google connected!", systemImage: "checkmark.circle.fill")
                            .foregroundColor(.green)
                    case .failed(let error):
                        Label(error, systemImage: "xmark.circle.fill")
                            .foregroundColor(.red)
                            .font(.caption)
                    }
                }
            }

            Text("Requires a Google Cloud Console project with Calendar API enabled")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    // MARK: - Calendars Tab

    private var calendarsTab: some View {
        ScrollView {
            Form {
                // Yandex calendars
                Section("Yandex Calendar") {
                    HStack {
                        Button("Load") { loadYandexCalendars() }
                            .disabled(isLoadingCalendars)
                        if isLoadingCalendars { ProgressView().scaleEffect(0.7) }
                    }

                    if let error = calendarLoadError {
                        Label(error, systemImage: "xmark.circle.fill")
                            .foregroundColor(.red).font(.caption)
                    }

                    if !availableCalendars.isEmpty {
                        calendarToggles(
                            calendars: availableCalendars.map { ($0.href, $0.displayName) },
                            selected: $settings.selectedCalendarHrefs
                        )
                    }
                }

                // Google calendars
                if settings.googleEnabled && GoogleOAuthService.isAuthenticated {
                    Divider()

                    Section("Google Calendar") {
                        HStack {
                            Button("Load") { loadGoogleCalendars() }
                                .disabled(isLoadingGoogleCalendars)
                            if isLoadingGoogleCalendars { ProgressView().scaleEffect(0.7) }
                        }

                        if let error = googleCalendarLoadError {
                            Label(error, systemImage: "xmark.circle.fill")
                                .foregroundColor(.red).font(.caption)
                        }

                        if !availableGoogleCalendars.isEmpty {
                            calendarToggles(
                                calendars: availableGoogleCalendars.map { ($0.id, $0.summary) },
                                selected: $settings.selectedGoogleCalendarIds
                            )
                        }
                    }
                }
            }
            .padding()
        }
    }

    /// Reusable calendar toggle list for any provider
    @ViewBuilder
    private func calendarToggles(
        calendars: [(id: String, name: String)],
        selected: Binding<[String]>
    ) -> some View {
        Toggle("All calendars", isOn: Binding(
            get: { selected.wrappedValue.isEmpty },
            set: { isAll in
                selected.wrappedValue = isAll ? [] : calendars.map { $0.id }
                saveSettings()
            }
        ))
        .fontWeight(.medium)

        if !selected.wrappedValue.isEmpty {
            ForEach(calendars, id: \.id) { cal in
                Toggle(cal.name, isOn: Binding(
                    get: { selected.wrappedValue.contains(cal.id) },
                    set: { isOn in
                        if isOn {
                            if !selected.wrappedValue.contains(cal.id) {
                                selected.wrappedValue.append(cal.id)
                            }
                        } else {
                            selected.wrappedValue.removeAll { $0 == cal.id }
                        }
                        if selected.wrappedValue.count == calendars.count {
                            selected.wrappedValue = []
                        }
                        saveSettings()
                    }
                ))
            }
        }

        Text(selected.wrappedValue.isEmpty
            ? "Syncing all"
            : "Selected: \(selected.wrappedValue.count) of \(calendars.count)")
            .font(.caption)
            .foregroundColor(.secondary)
    }

    private func loadYandexCalendars() {
        isLoadingCalendars = true
        calendarLoadError = nil

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
                let calendars = try await service.listCalendars()
                availableCalendars = calendars.filter { $0.isCalendar }
                isLoadingCalendars = false
            } catch {
                calendarLoadError = error.localizedDescription
                isLoadingCalendars = false
            }
        }
    }

    private func loadGoogleCalendars() {
        isLoadingGoogleCalendars = true
        googleCalendarLoadError = nil

        let service = GoogleCalendarService()
        Task {
            do {
                availableGoogleCalendars = try await service.listCalendars()
                isLoadingGoogleCalendars = false
            } catch {
                googleCalendarLoadError = error.localizedDescription
                isLoadingGoogleCalendars = false
            }
        }
    }

    // MARK: - Reminders Tab

    private var remindersTab: some View {
        Form {
            Section("Reminder Intervals") {
                ForEach($settings.intervals) { $interval in
                    HStack {
                        Toggle(isOn: $interval.isEnabled) {
                            Text("\(interval.displayText) before meeting")
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
                    Stepper("Add: \(newIntervalMinutes) min", value: $newIntervalMinutes, in: 1...120)

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

            Section("Notification Types") {
                Toggle("Full-screen notification", isOn: $settings.showFullScreenAlert)
                    .onChange(of: settings.showFullScreenAlert) { _ in saveSettings() }

                Toggle("System notification", isOn: $settings.showSystemNotification)
                    .onChange(of: settings.showSystemNotification) { _ in saveSettings() }

                Toggle("Sound notification", isOn: $settings.playSound)
                    .onChange(of: settings.playSound) { _ in saveSettings() }
            }

            Section("Do Not Disturb") {
                Toggle("Enable Do Not Disturb", isOn: $settings.doNotDisturbEnabled)
                    .onChange(of: settings.doNotDisturbEnabled) { _ in saveSettings() }

                if settings.doNotDisturbEnabled {
                    DatePicker("From", selection: $settings.doNotDisturbFrom, displayedComponents: .hourAndMinute)
                        .onChange(of: settings.doNotDisturbFrom) { _ in saveSettings() }

                    DatePicker("To", selection: $settings.doNotDisturbTo, displayedComponents: .hourAndMinute)
                        .onChange(of: settings.doNotDisturbTo) { _ in saveSettings() }

                    if settings.isDoNotDisturbActive {
                        Label("Currently active", systemImage: "moon.fill")
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
            Section("Sync") {
                Picker("Sync interval", selection: $settings.syncIntervalMinutes) {
                    Text("1 minute").tag(1)
                    Text("3 minutes").tag(3)
                    Text("5 minutes").tag(5)
                    Text("10 minutes").tag(10)
                    Text("15 minutes").tag(15)
                    Text("30 minutes").tag(30)
                }
                .onChange(of: settings.syncIntervalMinutes) { _ in
                    saveSettings()
                    reminderService.startSyncTimer()
                }
            }

            Section {
                Toggle("Launch at login", isOn: $settings.launchAtLogin)
                    .onChange(of: settings.launchAtLogin) { _ in saveSettings() }
            }

            Section("Status") {
                if let lastSync = reminderService.lastSyncDate {
                    LabeledContent("Last sync") {
                        Text(lastSync.formatted())
                    }
                }

                LabeledContent("Yandex events") {
                    Text("\(reminderService.upcomingEvents.count)")
                }

                LabeledContent("Local events") {
                    Text("\(reminderService.localEvents.count)")
                }

                if reminderService.isUsingCache {
                    Label("Using cached data", systemImage: "internaldrive")
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

    private func exchangeGoogleOAuthCode() {
        googleOAuthStatus = .exchanging
        Task {
            do {
                _ = try await GoogleOAuthService.exchangeCode(googleOAuthCode)
                googleOAuthStatus = .success
                googleOAuthCode = ""
                saveSettings()
            } catch {
                googleOAuthStatus = .failed(error.localizedDescription)
            }
        }
    }
}
