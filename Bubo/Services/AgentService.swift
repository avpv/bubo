import Foundation

// MARK: - Agent Service

/// Bridges user natural-language requests with the recipe system via an LLM.
/// Sends the user prompt + ScheduleRecipe schema to Claude, parses the
/// returned JSON into a ScheduleRecipe, and feeds it into the existing
/// optimizer pipeline.
@MainActor
@Observable
final class AgentService {

    // MARK: - State

    private(set) var isGenerating: Bool = false
    private(set) var lastError: String? = nil

    // MARK: - API Key (persisted in UserDefaults; move to Keychain for production)

    var apiKey: String {
        get { UserDefaults.standard.string(forKey: apiKeyKey) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: apiKeyKey) }
    }

    var hasAPIKey: Bool { !apiKey.trimmingCharacters(in: .whitespaces).isEmpty }

    private let apiKeyKey = "BuboAgentAPIKey"
    private let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!

    // MARK: - Generate Recipe

    /// Takes a natural-language request and returns a parsed ScheduleRecipe.
    func generateRecipe(from userPrompt: String) async -> Result<ScheduleRecipe, AgentError> {
        guard hasAPIKey else {
            return .failure(.noAPIKey)
        }

        isGenerating = true
        lastError = nil
        defer { isGenerating = false }

        let systemPrompt = Self.buildSystemPrompt()
        let body = ClaudeRequest(
            model: "claude-sonnet-4-20250514",
            max_tokens: 1024,
            system: systemPrompt,
            messages: [
                .init(role: "user", content: userPrompt)
            ]
        )

        guard let jsonBody = try? JSONEncoder().encode(body) else {
            let err = AgentError.encoding
            lastError = err.localizedDescription
            return .failure(err)
        }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.httpBody = jsonBody
        request.timeoutInterval = 30

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            let err = AgentError.network(error.localizedDescription)
            lastError = err.localizedDescription
            return .failure(err)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            let err = AgentError.network("Invalid response")
            lastError = err.localizedDescription
            return .failure(err)
        }

        guard httpResponse.statusCode == 200 else {
            let message = String(data: data, encoding: .utf8) ?? "HTTP \(httpResponse.statusCode)"
            let err = AgentError.api(message)
            lastError = err.localizedDescription
            return .failure(err)
        }

        // Parse Claude response
        let claudeResponse: ClaudeResponse
        do {
            claudeResponse = try JSONDecoder().decode(ClaudeResponse.self, from: data)
        } catch {
            let err = AgentError.parsing("Could not parse API response: \(error.localizedDescription)")
            lastError = err.localizedDescription
            return .failure(err)
        }

        guard let text = claudeResponse.content.first(where: { $0.type == "text" })?.text else {
            let err = AgentError.parsing("No text in API response")
            lastError = err.localizedDescription
            return .failure(err)
        }

        // Extract JSON from response (LLM may wrap it in ```json ... ```)
        let jsonString = Self.extractJSON(from: text)

        guard let recipeData = jsonString.data(using: .utf8) else {
            let err = AgentError.parsing("Invalid JSON string")
            lastError = err.localizedDescription
            return .failure(err)
        }

        do {
            let recipe = try JSONDecoder().decode(ScheduleRecipe.self, from: recipeData)
            return .success(recipe)
        } catch {
            let err = AgentError.parsing("Could not parse recipe: \(error.localizedDescription)")
            lastError = err.localizedDescription
            return .failure(err)
        }
    }

    // MARK: - System Prompt

    static func buildSystemPrompt() -> String {
        var prompt = """
        You are a schedule optimization assistant inside the Bubo calendar app.
        The user describes what they want to schedule in natural language.
        You MUST respond with ONLY a valid JSON object — no explanation, no markdown fences, no text before or after.

        \(LLMRecipeBridge.schemaDescription)

        ## Important rules
        - Respond with ONLY the JSON object, nothing else.
        - Always include "name" and at least one event in "events".
        - Pick a relevant SF Symbol for "icon" (e.g. brain.head.profile, figure.run, flame, book, pencil).
        - Set "priority" and "energy" realistically (0.0-1.0).
        - Use "focus": true for deep work that shouldn't be interrupted.
        - Use "period" to hint preferred time of day.
        - Use "weights" to emphasize what matters most for this request.
        - For multiple related events, consider using "chainGap" for sequential scheduling.

        ## Examples
        """

        for example in LLMRecipeBridge.examples {
            prompt += "\n\nUser: \(example.prompt)\n\(example.json)"
        }

        return prompt
    }

    // MARK: - JSON Extraction

    /// Extracts JSON from LLM response, handling markdown code fences.
    static func extractJSON(from text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)

        // Try to extract from ```json ... ``` or ``` ... ```
        if let range = trimmed.range(of: "```json") ?? trimmed.range(of: "```") {
            let afterFence = trimmed[range.upperBound...]
            if let endRange = afterFence.range(of: "```") {
                return String(afterFence[..<endRange.lowerBound])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }

        // Already plain JSON
        return trimmed
    }
}

// MARK: - Errors

enum AgentError: Error, LocalizedError {
    case noAPIKey
    case encoding
    case network(String)
    case api(String)
    case parsing(String)

    var errorDescription: String? {
        switch self {
        case .noAPIKey: "No API key configured. Add your Anthropic API key in Settings → AI Assistant."
        case .encoding: "Failed to encode request."
        case .network(let msg): "Network error: \(msg)"
        case .api(let msg): "API error: \(msg)"
        case .parsing(let msg): "Parse error: \(msg)"
        }
    }
}

// MARK: - Claude API Types

private struct ClaudeRequest: Encodable {
    let model: String
    let max_tokens: Int
    let system: String
    let messages: [Message]

    struct Message: Encodable {
        let role: String
        let content: String
    }
}

private struct ClaudeResponse: Decodable {
    let content: [ContentBlock]

    struct ContentBlock: Decodable {
        let type: String
        let text: String?
    }
}
