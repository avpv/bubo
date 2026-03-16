import SwiftUI

struct AccountTabView: View {
    @ObservedObject var settings: ReminderSettings
    @ObservedObject var reminderService: ReminderService
    @ObservedObject var viewModel: SettingsViewModel

    var body: some View {
        ScrollView {
            Form {
                Section("Yandex Calendar") {
                    Picker("Authorization", selection: $settings.authMethod) {
                        Text("App Password").tag(AuthMethod.appPassword)
                        Text("OAuth 2.0").tag(AuthMethod.oauth)
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: settings.authMethod) { _ in save() }

                    if settings.authMethod == .appPassword {
                        appPasswordSection
                    } else {
                        oauthSection
                    }

                    HStack {
                        Button("Test Yandex") {
                            viewModel.checkConnection(settings: settings, reminderService: reminderService)
                        }
                        Spacer()
                        connectionStatusView
                    }
                }

                Divider()

                Section("Google Calendar") {
                    Toggle("Enable Google Calendar", isOn: $settings.googleEnabled)
                        .onChange(of: settings.googleEnabled) { _ in save() }

                    if settings.googleEnabled {
                        googleAccountSection
                    }
                }
            }
            .padding()
        }
    }

    // MARK: - Yandex App Password

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

            Text("Create an app password: id.yandex.ru \u{2192} Security \u{2192} App Passwords")
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

    // MARK: - Yandex OAuth

    private var oauthSection: some View {
        Section("OAuth 2.0") {
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
                        viewModel.oauthStatus = .idle
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
                        TextField("Authorization code", text: $viewModel.oauthCode)
                            .textFieldStyle(.roundedBorder)

                        Button("Confirm") {
                            viewModel.exchangeOAuthCode()
                        }
                        .disabled(viewModel.oauthCode.isEmpty)
                    }

                    oauthStatusView(viewModel.oauthStatus)
                }
            }

            Text("OAuth is more secure: the app does not store your password")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    // MARK: - Google Account

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
                        viewModel.googleOAuthStatus = .idle
                        save()
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
                        TextField("Authorization code", text: $viewModel.googleOAuthCode)
                            .textFieldStyle(.roundedBorder)

                        Button("Confirm") {
                            viewModel.exchangeGoogleOAuthCode(settings: settings, reminderService: reminderService)
                        }
                        .disabled(viewModel.googleOAuthCode.isEmpty)
                    }

                    oauthStatusView(viewModel.googleOAuthStatus)
                }
            }

            Text("Requires a Google Cloud Console project with Calendar API enabled")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    // MARK: - Status Views

    @ViewBuilder
    private var connectionStatusView: some View {
        switch viewModel.connectionStatus {
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

    @ViewBuilder
    private func oauthStatusView(_ status: SettingsViewModel.OAuthStatus) -> some View {
        switch status {
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

    private func save() {
        viewModel.saveSettings(settings, reminderService)
    }
}
