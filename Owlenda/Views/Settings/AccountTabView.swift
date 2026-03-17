import SwiftUI

struct AccountTabView: View {
    @EnvironmentObject var settings: ReminderSettings
    @EnvironmentObject var viewModel: SettingsViewModel
    @EnvironmentObject var reminderService: ReminderService
    @AppStorage("CredentialsMigrationNoticeDismissed") private var migrationDismissed = false

    /// Detects when an existing user's credentials were lost due to keychain migration.
    /// True when: auth is configured (non-default settings exist) but credentials are empty.
    private var needsCredentialReentry: Bool {
        if migrationDismissed { return false }
        switch settings.authMethod {
        case .appPassword:
            // Settings were previously saved (not a fresh install) but credentials vanished
            let hadPreviousConfig = UserDefaults.standard.data(forKey: "ReminderSettings") != nil
            return hadPreviousConfig && settings.yandexLogin.isEmpty && settings.yandexAppPassword.isEmpty
        case .oauth:
            return false // OAuth users just re-authenticate via the button
        }
    }

    var body: some View {
        Form {
            if reminderService.isKeychainDenied {
                Section {
                    VStack(alignment: .leading, spacing: DS.Spacing.md) {
                        Label("Keychain access was denied", systemImage: "key.slash")
                            .foregroundColor(.red)
                            .fontWeight(.medium)
                        Text("Your saved credentials could not be read. Please re-enter them below — they will be stored securely without prompting again.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Button("Retry Keychain Access") {
                            KeychainService.resetAccessDenied()
                            reminderService.setupCalDAVService()
                        }
                        .controlSize(.small)
                    }
                }
            } else if needsCredentialReentry {
                Section {
                    HStack(alignment: .top, spacing: DS.Spacing.md) {
                        Image(systemName: "arrow.up.circle.fill")
                            .foregroundColor(.blue)
                            .font(.title3)
                        VStack(alignment: .leading, spacing: DS.Spacing.xs) {
                            Text("Credentials need to be re-entered")
                                .fontWeight(.medium)
                            Text("The app was updated to use a more secure credential storage. Please re-enter your login and app password below. This is a one-time step.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                        Button {
                            migrationDismissed = true
                        } label: {
                            Image(systemName: "xmark")
                                .foregroundColor(.secondary)
                        }
                        .buttonStyle(.borderless)
                    }
                }
            }

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
        TextField("Login", text: Binding(
            get: { settings.yandexLogin },
            set: { settings.yandexLogin = $0 }
        ), prompt: Text("user@yandex.ru"))

        SecureField("App Password", text: Binding(
            get: { settings.yandexAppPassword },
            set: { settings.yandexAppPassword = $0 }
        ), prompt: Text("Paste app password"))

        Text("Create an app password: id.yandex.ru \u{2192} Security \u{2192} App Passwords")
            .font(.caption)
            .foregroundColor(.secondary)

        HStack(spacing: DS.Spacing.xs) {
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
        TextField("Login", text: Binding(
            get: { settings.yandexLogin },
            set: { settings.yandexLogin = $0 }
        ), prompt: Text("user@yandex.ru"))

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
                TextField("Code", text: $viewModel.oauthCode, prompt: Text("Paste code here"))

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
                TextField("Code", text: $viewModel.googleOAuthCode, prompt: Text("Paste code here"))

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
