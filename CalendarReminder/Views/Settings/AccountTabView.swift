import SwiftUI

struct AccountTabView: View {
    @ObservedObject var settings: ReminderSettings
    @ObservedObject var reminderService: ReminderService
    @ObservedObject var viewModel: SettingsViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // Yandex Calendar
                SettingsCard(icon: "calendar.circle.fill", title: "Yandex Calendar", description: "Connect your Yandex account") {
                    VStack(spacing: 10) {
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

                        Divider()

                        HStack {
                            Button {
                                viewModel.checkConnection(settings: settings, reminderService: reminderService)
                            } label: {
                                Label("Test Connection", systemImage: "antenna.radiowaves.left.and.right")
                                    .font(.system(.caption, design: .rounded).weight(.medium))
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)

                            Spacer()
                            connectionStatusView
                        }
                    }
                }

                // Google Calendar
                SettingsCard(icon: "g.circle.fill", title: "Google Calendar", description: "Connect your Google account") {
                    VStack(spacing: 10) {
                        Toggle(isOn: $settings.googleEnabled) {
                            Text("Enable Google Calendar")
                                .font(.system(.subheadline, design: .rounded))
                        }
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .onChange(of: settings.googleEnabled) { _ in save() }

                        if settings.googleEnabled {
                            googleAccountSection
                        }
                    }
                }
            }
            .padding(20)
        }
    }

    // MARK: - Yandex App Password

    private var appPasswordSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Login", text: Binding(
                get: { settings.yandexLogin },
                set: { settings.yandexLogin = $0 }
            ))
            .textFieldStyle(.roundedBorder)
            .font(.system(.subheadline, design: .rounded))

            SecureField("App Password", text: Binding(
                get: { settings.yandexAppPassword },
                set: { settings.yandexAppPassword = $0 }
            ))
            .textFieldStyle(.roundedBorder)
            .font(.system(.subheadline, design: .rounded))

            Text("Create an app password: id.yandex.ru \u{2192} Security \u{2192} App Passwords")
                .font(.caption2)
                .foregroundColor(.secondary)

            HStack(spacing: 4) {
                Image(systemName: "lock.shield.fill")
                    .foregroundColor(.green)
                    .font(.caption2)
                Text("Password is stored in Keychain")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
    }

    // MARK: - Yandex OAuth

    private var oauthSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Yandex Login", text: Binding(
                get: { settings.yandexLogin },
                set: { settings.yandexLogin = $0 }
            ))
            .textFieldStyle(.roundedBorder)
            .font(.system(.subheadline, design: .rounded))

            if YandexOAuthService.isAuthenticated {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.seal.fill")
                        .foregroundColor(.green)
                    Text("Authenticated via OAuth")
                        .font(.system(.subheadline, design: .rounded))
                    Spacer()
                    Button("Log Out") {
                        YandexOAuthService.logout()
                        viewModel.oauthStatus = .idle
                    }
                    .font(.system(.caption, design: .rounded))
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                .padding(8)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.green.opacity(0.06))
                )
            } else {
                Button {
                    YandexOAuthService.startAuthFlow()
                } label: {
                    Label("Open authorization in browser", systemImage: "safari")
                        .font(.system(.subheadline, design: .rounded))
                }
                .buttonStyle(.bordered)

                Text("After authorization, copy the code and paste it below:")
                    .font(.caption2)
                    .foregroundColor(.secondary)

                HStack(spacing: 8) {
                    TextField("Authorization code", text: $viewModel.oauthCode)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.subheadline, design: .rounded))

                    Button("Confirm") {
                        viewModel.exchangeOAuthCode()
                    }
                    .disabled(viewModel.oauthCode.isEmpty)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }

                oauthStatusView(viewModel.oauthStatus)
            }

            HStack(spacing: 4) {
                Image(systemName: "shield.checkered")
                    .font(.caption2)
                    .foregroundColor(.accentColor)
                Text("OAuth is more secure: the app does not store your password")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
    }

    // MARK: - Google Account

    private var googleAccountSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            if GoogleOAuthService.isAuthenticated {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.seal.fill")
                        .foregroundColor(.green)
                    Text("Google account connected")
                        .font(.system(.subheadline, design: .rounded))
                    Spacer()
                    Button("Disconnect") {
                        GoogleOAuthService.logout()
                        settings.googleEnabled = false
                        viewModel.googleOAuthStatus = .idle
                        save()
                    }
                    .font(.system(.caption, design: .rounded))
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                .padding(8)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.green.opacity(0.06))
                )
            } else {
                Button {
                    GoogleOAuthService.startAuthFlow()
                } label: {
                    Label("Sign in with Google", systemImage: "safari")
                        .font(.system(.subheadline, design: .rounded))
                }
                .buttonStyle(.bordered)

                Text("After authorization, copy the code and paste it below:")
                    .font(.caption2)
                    .foregroundColor(.secondary)

                HStack(spacing: 8) {
                    TextField("Authorization code", text: $viewModel.googleOAuthCode)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.subheadline, design: .rounded))

                    Button("Confirm") {
                        viewModel.exchangeGoogleOAuthCode(settings: settings, reminderService: reminderService)
                    }
                    .disabled(viewModel.googleOAuthCode.isEmpty)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }

                oauthStatusView(viewModel.googleOAuthStatus)
            }

            Text("Requires a Google Cloud Console project with Calendar API enabled")
                .font(.caption2)
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
            ProgressView()
                .scaleEffect(0.6)
        case .success:
            Label("Connected", systemImage: "checkmark.circle.fill")
                .font(.system(.caption, design: .rounded).weight(.medium))
                .foregroundColor(.green)
        case .failed(let error):
            Label(error, systemImage: "xmark.circle.fill")
                .font(.caption2)
                .foregroundColor(.red)
        }
    }

    @ViewBuilder
    private func oauthStatusView(_ status: SettingsViewModel.OAuthStatus) -> some View {
        switch status {
        case .idle: EmptyView()
        case .exchanging:
            ProgressView()
                .scaleEffect(0.6)
        case .success:
            Label("Authorization successful!", systemImage: "checkmark.circle.fill")
                .font(.system(.caption, design: .rounded).weight(.medium))
                .foregroundColor(.green)
        case .failed(let error):
            Label(error, systemImage: "xmark.circle.fill")
                .font(.caption2)
                .foregroundColor(.red)
        }
    }

    private func save() {
        viewModel.saveSettings(settings, reminderService)
    }
}
