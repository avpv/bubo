import SwiftUI

// MARK: - Assistant Settings Tab (AI)
//
// Schedule-side settings (working hours, peak energy, lunch, learning)
// moved to Settings → Optimizer. What remains here is purely about the
// AI assistant: mode, key, usage, privacy — plus a one-off Backlog
// Cleanup nudge when stale tasks pile up.

struct AssistantTabView: View {
    @Environment(ReminderSettings.self) var settings
    @Environment(OptimizerService.self) var optimizerService
    @Environment(\.activeSkin) private var skin
    var agentService: AgentService

    @State private var apiKeyInput: String = ""
    @State private var isKeyVisible: Bool = false
    @State private var showSaved: Bool = false

    var body: some View {
        ScrollView {
            VStack(spacing: DS.Spacing.lg) {

                if let backlogService = optimizerService.backlogService, !backlogService.staleTasks.isEmpty {
                    SettingsPlatter("Backlog Cleanup") {
                        VStack(alignment: .leading, spacing: DS.Spacing.sm) {
                            Text("You have \(backlogService.staleTasks.count) tasks pending for over 14 days.")
                                .font(.footnote)
                                .foregroundStyle(skin.resolvedTextSecondary)
                            
                            Button("Drop Stale Tasks") {
                                withAnimation(DS.Animation.quick) {
                                    backlogService.dropStaleTasks()
                                }
                            }
                            .buttonStyle(.action(role: .destructive, size: .compact))
                        }
                    }
                }

                // Working Hours, Your Day and Learning now live in
                // Settings → Optimizer — this tab is purely about the AI
                // assistant (mode, key, usage, privacy).

                SettingsPlatter("Mode") {
                    VStack(alignment: .leading, spacing: DS.Spacing.md) {
                        Picker("", selection: Binding(
                            get: { agentService.mode },
                            set: { agentService.mode = $0 }
                        )) {
                            Text("Built-in (free, limited)").tag(AgentService.Mode.builtIn)
                            Text("Own API key (unlimited)").tag(AgentService.Mode.ownKey)
                        }
                        .pickerStyle(.radioGroup)
                        .labelsHidden()

                        switch agentService.mode {
                        case .builtIn:
                            builtInDescription
                        case .ownKey:
                            ownKeyDescription
                        }
                    }
                }

                if agentService.mode == .ownKey {
                    SettingsPlatter("API Key") {
                        apiKeySection
                    }
                }

                if agentService.mode == .builtIn {
                    SettingsPlatter("Usage") {
                        usageSection
                    }
                }

                SettingsPlatter("Privacy") {
                    privacySection
                }
            }
            .padding(DS.Spacing.xl)
        }
        .scrollContentBackground(.hidden)
        .onAppear {
            if agentService.mode == .ownKey {
                apiKeyInput = agentService.ownAPIKey
            }
        }
    }

    // MARK: - Mode Descriptions

    private var builtInDescription: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.xs) {
            Label("No setup required", systemImage: "checkmark.circle.fill")
                .font(.footnote.weight(.medium))
                .foregroundStyle(skin.resolvedSuccessColor)

            Text("AI requests go through the Bubo proxy with a daily limit per device. No API key needed.")
                .font(.footnote)
                .foregroundStyle(skin.resolvedTextSecondary)
        }
    }

    private var ownKeyDescription: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.xs) {
            Text("Requests go directly to the DeepSeek API using your key. No rate limits from Bubo, you pay per usage on your DeepSeek account.")
                .font(.footnote)
                .foregroundStyle(skin.resolvedTextSecondary)
        }
    }

    // MARK: - API Key Section

    private var apiKeySection: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.md) {
            Text("Enter your DeepSeek API key. Stored securely in your macOS Keychain.")
                .font(.footnote)
                .foregroundStyle(skin.resolvedTextSecondary)

            HStack(spacing: DS.Spacing.sm) {
                Group {
                    if isKeyVisible {
                        TextField("sk-...", text: $apiKeyInput)
                    } else {
                        SecureField("sk-...", text: $apiKeyInput)
                    }
                }
                .textFieldStyle(.plain)
                .font(.system(.body, design: .monospaced))
                .padding(DS.Spacing.sm)
                .background(skin.resolvedPlatterMaterial.opacity(DS.Opacity.half))
                .clipShape(RoundedRectangle(cornerRadius: DS.Size.previewSmallRadius))

                Button {
                    isKeyVisible.toggle()
                } label: {
                    Image(systemName: isKeyVisible ? "eye.slash" : "eye")
                        .font(.footnote)
                }
                .buttonStyle(.plain)
                .foregroundStyle(skin.resolvedTextSecondary)
                .accessibilityLabel(isKeyVisible ? "Hide API key" : "Show API key")
            }

            HStack(spacing: DS.Spacing.sm) {
                Button("Save") {
                    agentService.ownAPIKey = apiKeyInput
                    showSaved = true
                    Haptics.tap()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                        showSaved = false
                    }
                }
                .buttonStyle(.action(role: .primary, size: .compact))
                .disabled(apiKeyInput.trimmingCharacters(in: .whitespaces).isEmpty)

                if agentService.hasOwnAPIKey {
                    Button("Clear") {
                        apiKeyInput = ""
                        agentService.ownAPIKey = ""
                        Haptics.tap()
                    }
                    .buttonStyle(.action(role: .destructive, size: .compact))
                }

                if showSaved {
                    Label("Saved", systemImage: "checkmark.circle.fill")
                        .font(.footnote)
                        .foregroundStyle(skin.resolvedSuccessColor)
                        .transition(.opacity)
                }
            }

            HStack(spacing: DS.Spacing.xs) {
                Circle()
                    .fill(agentService.hasOwnAPIKey ? skin.resolvedSuccessColor : skin.resolvedWarningColor)
                    .frame(width: 8, height: 8)
                Text(agentService.hasOwnAPIKey ? "API key configured" : "No API key")
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(skin.resolvedTextPrimary)
            }
        }
    }

    // MARK: - Usage Section

    private var usageSection: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.sm) {
            if let status = agentService.rateLimitStatus {
                HStack(spacing: DS.Spacing.xs) {
                    Image(systemName: "chart.bar")
                        .font(.footnote)
                        .foregroundStyle(skin.accentColor)
                    Text(status)
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(skin.resolvedTextPrimary)
                }

                if let resetsAt = agentService.limitResetsAt {
                    Text("Resets \(resetsAt, style: .relative)")
                        .font(.footnote)
                        .foregroundStyle(skin.resolvedTextSecondary)
                }
            } else {
                Text("Usage info will appear after your first request.")
                    .font(.footnote)
                    .foregroundStyle(skin.resolvedTextSecondary)
            }

            Text("Switch to \u{201C}Own API key\u{201D} mode for unlimited usage.")
                .font(.footnote)
                .foregroundStyle(skin.resolvedTextTertiary)
        }
    }

    // MARK: - Privacy Section

    private var privacySection: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.sm) {
            Text("The AI assistant converts your text descriptions into schedule recipes. Here's what is and isn't sent:")
                .font(.footnote)
                .foregroundStyle(skin.resolvedTextSecondary)

            VStack(alignment: .leading, spacing: DS.Spacing.xs) {
                Label("Your text prompt", systemImage: "arrow.up.circle")
                    .font(.footnote)
                    .foregroundStyle(skin.resolvedTextSecondary)
                Label("Recipe schema (how recipes work)", systemImage: "arrow.up.circle")
                    .font(.footnote)
                    .foregroundStyle(skin.resolvedTextSecondary)
                Label {
                    Text("Your calendar events").strikethrough()
                } icon: {
                    Image(systemName: "xmark.circle")
                }
                .font(.footnote)
                .foregroundStyle(skin.resolvedTextTertiary)
                Label {
                    Text("Your personal data").strikethrough()
                } icon: {
                    Image(systemName: "xmark.circle")
                }
                .font(.footnote)
                .foregroundStyle(skin.resolvedTextTertiary)
            }

            if agentService.mode == .builtIn {
                Text("In built-in mode, an anonymous device ID is sent for rate limiting. It is not linked to your identity.")
                    .font(.footnote)
                    .foregroundStyle(skin.resolvedTextTertiary)
            }
        }
    }
}
