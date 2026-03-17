import SwiftUI

struct AccountTabView: View {
    @EnvironmentObject var settings: ReminderSettings
    @EnvironmentObject var viewModel: SettingsViewModel

    var body: some View {
        Form {
            Section("Yandex Calendar") {
                Picker("Authorization", selection: $settings.authMethod) {
                    Text("App Password").tag(AuthMethod.appPassword)
                    Text("OAuth 2.0").tag(AuthMethod.oauth)
                }
                .pickerStyle(.segmented)

                if settings.authMethod == .appPassword {
                    appPasswordSection
                } else {
                    oauthSection
                }

                HStack {
                    Button("Test Connection") {
                        viewModel.checkConnection(settings: settings)
                    }
                    Spacer()
                    connectionStatusView
                }
            }

            Section("Google Calendar") {
                Toggle("Enable Google Calendar", isOn: $settings.googleEnabled)

                if settings.googleEnabled {
                    googleAccountSection
                }
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Yandex App Password

    @ViewBuilder
    private var appPasswordSection: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
            Text("Login")
                .font(.caption)
                .foregroundColor(.secondary)
            TextField("Enter your Yandex login", text: Binding(
                get: { settings.yandexLogin },
                set: { settings.yandexLogin = $0 }
            ))
            .textFieldStyle(.roundedBorder)
        }

        VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
            Text("App Password")
                .font(.caption)
                .foregroundColor(.secondary)
            SecureField("Enter your app password", text: Binding(
                get: { settings.yandexAppPassword },
                set: { settings.yandexAppPassword = $0 }
            ))
            .textFieldStyle(.roundedBorder)
        }

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

    // MARK: - Yandex OAuth

    @ViewBuilder
    private var oauthSection: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
            Text("Yandex Login")
                .font(.caption)
                .foregroundColor(.secondary)
            TextField("Enter your Yandex login", text: Binding(
                get: { settings.yandexLogin },
                set: { settings.yandexLogin = $0 }
            ))
            .textFieldStyle(.roundedBorder)
        }

        if YandexOAuthService.isAuthenticated {
            HStack {
                Label("Authenticated via OAuth", systemImage: "checkmark.circle.fill")
                    .foregroundColor(.green)
                Spacer()
                Button("Log Out") {
                    YandexOAuthService.logout()
                    viewModel.oauthStatus = .idle
                }
            }
        } else {
            Button {
                YandexOAuthService.startAuthFlow()
            } label: {
                Label("Open Authorization in Browser", systemImage: "safari")
            }
            .buttonStyle(.borderedProminent)

            Text("After authorization, copy the code and paste it below:")
                .font(.caption)
                .foregroundColor(.secondary)

            HStack {
                TextField("Paste authorization code here", text: $viewModel.oauthCode)
                    .textFieldStyle(.roundedBorder)

                Button("Confirm") {
                    viewModel.exchangeOAuthCode()
                }
                .disabled(viewModel.oauthCode.isEmpty)
            }

            oauthStatusView(viewModel.oauthStatus)
        }

        Text("OAuth is more secure: the app does not store your password")
            .font(.caption)
            .foregroundColor(.secondary)
    }

    // MARK: - Google Account

    @ViewBuilder
    private var googleAccountSection: some View {
        if GoogleOAuthService.isAuthenticated {
            HStack {
                Label("Google account connected", systemImage: "checkmark.circle.fill")
                    .foregroundColor(.green)
                Spacer()
                Button("Disconnect") {
                    GoogleOAuthService.logout()
                    settings.googleEnabled = false
                    viewModel.googleOAuthStatus = .idle
                }
            }
        } else {
            Button {
                GoogleOAuthService.startAuthFlow()
            } label: {
                Label("Sign in with Google", systemImage: "safari")
            }
            .buttonStyle(.borderedProminent)

            Text("After authorization, copy the code and paste it below:")
                .font(.caption)
                .foregroundColor(.secondary)

            HStack {
                TextField("Paste authorization code here", text: $viewModel.googleOAuthCode)
                    .textFieldStyle(.roundedBorder)

                Button("Confirm") {
                    viewModel.exchangeGoogleOAuthCode()
                }
                .disabled(viewModel.googleOAuthCode.isEmpty)
            }

            oauthStatusView(viewModel.googleOAuthStatus)
        }

        Text("Requires a Google Cloud Console project with Calendar API enabled")
            .font(.caption)
            .foregroundColor(.secondary)
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
}
