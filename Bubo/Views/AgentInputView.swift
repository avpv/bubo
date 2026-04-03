import SwiftUI

// MARK: - Agent Input View

/// Natural-language input for AI-generated recipes.
/// The user types what they want, the LLM produces a ScheduleRecipe.
struct AgentInputView: View {
    @Environment(\.activeSkin) private var skin
    @Environment(\.openSettings) private var openSettings
    var agentService: AgentService
    let onRecipeGenerated: (ScheduleRecipe) -> Void
    let onCancel: () -> Void

    @State private var prompt: String = ""
    @FocusState private var isTextFieldFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Input area
            VStack(alignment: .leading, spacing: DS.Spacing.md) {
                inputHeader
                if !agentService.isConfigured {
                    noAPIKeyBanner
                } else {
                    textInput
                    if let error = agentService.lastError {
                        errorBanner(error)
                    }
                    if let status = agentService.rateLimitStatus {
                        rateLimitBadge(status)
                    }
                    examplePrompts
                }
            }
            .padding(.horizontal, DS.Spacing.lg)
            .padding(.vertical, DS.Spacing.lg)

            Spacer(minLength: 0)

            // Footer
            SkinSeparator()
            footer
        }
        .onAppear { isTextFieldFocused = true }
    }

    // MARK: - Input Header

    private var inputHeader: some View {
        HStack(spacing: DS.Spacing.sm) {
            Image(systemName: "sparkles")
                .font(.title3)
                .foregroundStyle(skin.accentColor)
                .symbolEffect(.pulse, isActive: agentService.isGenerating)

            VStack(alignment: .leading, spacing: 2) {
                Text("AI Assistant")
                    .font(.headline)
                    .foregroundStyle(skin.resolvedTextPrimary)
                Text("Describe what you want to schedule")
                    .font(.caption)
                    .foregroundStyle(skin.resolvedTextSecondary)
            }
        }
    }

    // MARK: - No API Key Banner

    private var noAPIKeyBanner: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.sm) {
            HStack(spacing: DS.Spacing.xs) {
                Image(systemName: "key")
                    .font(.caption)
                    .foregroundStyle(skin.resolvedWarningColor)
                Text("API key required")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(skin.resolvedTextPrimary)
            }

            Text("Add your DeepSeek API key in Settings → AI Assistant → Own API key to enable this feature.")
                .font(.caption)
                .foregroundStyle(skin.resolvedTextSecondary)

            Button("Open Settings") {
                Haptics.tap()
                SettingsViewModel.pendingPane = .ai
                openSettings()
            }
            .buttonStyle(.action(role: .primary, size: .compact))
        }
        .padding(DS.Spacing.md)
        .background(
            RoundedRectangle(cornerRadius: DS.Size.previewSmallRadius)
                .fill(skin.resolvedWarningColor.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: DS.Size.previewSmallRadius)
                .strokeBorder(skin.resolvedWarningColor.opacity(0.2), lineWidth: 1)
        )
    }

    // MARK: - Rate Limit Badge

    private func rateLimitBadge(_ status: String) -> some View {
        HStack(spacing: DS.Spacing.xs) {
            Image(systemName: "chart.bar")
                .font(.caption2)
                .foregroundStyle(skin.resolvedTextTertiary)
            Text(status)
                .font(.caption2)
                .foregroundStyle(skin.resolvedTextTertiary)
        }
    }

    // MARK: - Text Input

    private var textInput: some View {
        VStack(spacing: 0) {
            TextEditor(text: $prompt)
                .font(.body)
                .scrollContentBackground(.hidden)
                .focused($isTextFieldFocused)
                .frame(minHeight: 60, maxHeight: 100)
                .disabled(agentService.isGenerating)
                .accessibilityLabel("Describe what you want to schedule")

            if !prompt.isEmpty {
                HStack {
                    Spacer()
                    Text("\(prompt.count)")
                        .font(.caption2)
                        .foregroundStyle(skin.resolvedTextTertiary)
                }
                .padding(.trailing, DS.Spacing.xs)
                .padding(.bottom, DS.Spacing.xs)
            }
        }
        .padding(DS.Spacing.sm)
        .background(skin.resolvedPlatterMaterial.opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: DS.Size.previewSmallRadius))
        .overlay(
            RoundedRectangle(cornerRadius: DS.Size.previewSmallRadius)
                .strokeBorder(
                    isTextFieldFocused ? skin.accentColor.opacity(0.4) : .clear,
                    lineWidth: 1
                )
        )
    }

    // MARK: - Error Banner

    private func errorBanner(_ message: String) -> some View {
        HStack(spacing: DS.Spacing.xs) {
            Image(systemName: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(skin.resolvedWarningColor)

            Text(message)
                .font(.caption2)
                .foregroundStyle(skin.resolvedTextSecondary)
                .lineLimit(3)
        }
        .padding(DS.Spacing.sm)
        .background(
            RoundedRectangle(cornerRadius: DS.Size.previewSmallRadius)
                .fill(skin.resolvedWarningColor.opacity(0.08))
        )
    }

    // MARK: - Example Prompts

    private var examplePrompts: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.sm) {
            Text("Try something like:")
                .font(.caption2.weight(.medium))
                .foregroundStyle(skin.resolvedTextTertiary)

            FlowLayout(spacing: DS.Spacing.xs) {
                ForEach(Self.examples, id: \.self) { example in
                    Button {
                        prompt = example
                        Haptics.tap()
                    } label: {
                        Text(example)
                            .font(.caption2)
                            .foregroundStyle(skin.accentColor)
                            .padding(.horizontal, DS.Spacing.sm)
                            .padding(.vertical, DS.Spacing.xs)
                            .background(
                                Capsule().fill(skin.accentColor.opacity(0.08))
                            )
                    }
                    .buttonStyle(.plain)
                    .disabled(agentService.isGenerating)
                }
            }
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            Button(action: onCancel) {
                Text("Cancel")
            }
            .buttonStyle(.action(role: .secondary))
            .keyboardShortcut(.cancelAction)

            Spacer()

            Button {
                Haptics.tap()
                generate()
            } label: {
                if agentService.isGenerating {
                    HStack(spacing: DS.Spacing.xs) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Generating…")
                    }
                } else {
                    Label("Generate", systemImage: "sparkles")
                }
            }
            .buttonStyle(.action(role: .primary))
            .disabled(prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || agentService.isGenerating)
            .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, DS.Spacing.lg)
        .frame(height: DS.Size.actionFooterHeight)
        .skinBarBackground(skin)
    }

    // MARK: - Generate

    private func generate() {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        Task {
            let result = await agentService.generateRecipe(from: trimmed)
            switch result {
            case .success(let recipe):
                onRecipeGenerated(recipe)
            case .failure:
                // Error is already set in agentService.lastError
                break
            }
        }
    }

    // MARK: - Examples

    static let examples: [String] = [
        "2 hours of deep work tomorrow morning",
        "Fit 5 tasks into my week",
        "30 min yoga before lunch",
        "3 pomodoro sessions for a report",
        "Batch my meetings in the afternoon",
    ]
}

