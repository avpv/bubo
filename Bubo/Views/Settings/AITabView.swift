import SwiftUI

// MARK: - AI Assistant Settings Tab

struct AITabView: View {
    @Environment(\.activeSkin) private var skin
    var agentService: AgentService

    @State private var apiKeyInput: String = ""
    @State private var isKeyVisible: Bool = false
    @State private var showSaved: Bool = false

    var body: some View {
        ScrollView {
            VStack(spacing: DS.Spacing.lg) {

                SettingsPlatter("API Key") {
                    VStack(alignment: .leading, spacing: DS.Spacing.md) {
                        Text("Enter your Anthropic API key to enable the AI assistant. The key is stored locally on your device.")
                            .font(.caption)
                            .foregroundStyle(skin.resolvedTextSecondary)

                        HStack(spacing: DS.Spacing.sm) {
                            Group {
                                if isKeyVisible {
                                    TextField("sk-ant-...", text: $apiKeyInput)
                                } else {
                                    SecureField("sk-ant-...", text: $apiKeyInput)
                                }
                            }
                            .textFieldStyle(.plain)
                            .font(.system(.body, design: .monospaced))
                            .padding(DS.Spacing.sm)
                            .background(skin.resolvedPlatterMaterial.opacity(0.5))
                            .clipShape(RoundedRectangle(cornerRadius: DS.Size.previewSmallRadius))

                            Button {
                                isKeyVisible.toggle()
                            } label: {
                                Image(systemName: isKeyVisible ? "eye.slash" : "eye")
                                    .font(.caption)
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(skin.resolvedTextSecondary)
                        }

                        HStack(spacing: DS.Spacing.sm) {
                            Button("Save") {
                                agentService.apiKey = apiKeyInput
                                showSaved = true
                                Haptics.tap()
                                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                                    showSaved = false
                                }
                            }
                            .buttonStyle(.action(role: .primary, size: .compact))
                            .disabled(apiKeyInput.trimmingCharacters(in: .whitespaces).isEmpty)

                            if agentService.hasAPIKey {
                                Button("Clear") {
                                    apiKeyInput = ""
                                    agentService.apiKey = ""
                                    Haptics.tap()
                                }
                                .buttonStyle(.action(role: .destructive, size: .compact))
                            }

                            if showSaved {
                                Label("Saved", systemImage: "checkmark.circle.fill")
                                    .font(.caption)
                                    .foregroundStyle(skin.resolvedSuccessColor)
                                    .transition(.opacity)
                            }
                        }
                    }
                }

                SettingsPlatter("About") {
                    VStack(alignment: .leading, spacing: DS.Spacing.sm) {
                        Text("The AI assistant uses Claude to convert your natural-language descriptions into schedule optimization recipes.")
                            .font(.caption)
                            .foregroundStyle(skin.resolvedTextSecondary)

                        Text("Your schedule data is not sent to the API — only your text prompt and the recipe schema are included in the request.")
                            .font(.caption)
                            .foregroundStyle(skin.resolvedTextSecondary)

                        HStack(spacing: DS.Spacing.xs) {
                            Circle()
                                .fill(agentService.hasAPIKey ? skin.resolvedSuccessColor : skin.resolvedWarningColor)
                                .frame(width: 8, height: 8)
                            Text(agentService.hasAPIKey ? "API key configured" : "No API key")
                                .font(.caption.weight(.medium))
                                .foregroundStyle(skin.resolvedTextPrimary)
                        }
                        .padding(.top, DS.Spacing.xs)
                    }
                }
            }
            .padding(DS.Spacing.lg)
        }
        .scrollContentBackground(.hidden)
        .onAppear {
            apiKeyInput = agentService.apiKey
        }
    }
}
