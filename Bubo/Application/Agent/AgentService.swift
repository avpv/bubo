import Foundation
import os

private let agentServiceLogger = Logger(subsystem: "com.avpv.Bubo", category: "Network/Agent")

// MARK: - Agent Service

/// Bridges user natural-language requests with the optimizer's intent
/// pipeline via an LLM. Uses DeepSeek's OpenAI-compatible function-calling
/// to guarantee structured output that matches the `OptimizationRequest`
/// schema — no free-form JSON parsing.
///
/// Supports two modes:
/// - **Built-in** (default): requests go through the Bubo Cloudflare-Worker
///   proxy which holds the API key server-side and enforces per-device
///   rate limits.
/// - **Own key**: user provides their own DeepSeek API key stored in
///   Keychain; requests go directly to `api.deepseek.com` with no
///   rate limits. The Keychain identifier is the historical string
///   `"anthropic-api-key"` (renaming would lose stored keys for existing
///   installs).
@MainActor
@Observable
final class AgentService {

    // MARK: - State

    private(set) var isGenerating: Bool = false
    private(set) var lastError: String? = nil

    /// Remaining requests in the current rate-limit window (built-in mode only).
    /// nil when using own key or before the first request.
    private(set) var remainingRequests: Int? = nil

    /// Total requests allowed per window (built-in mode only).
    private(set) var requestLimit: Int? = nil

    /// When the rate-limit window resets (built-in mode only).
    private(set) var limitResetsAt: Date? = nil

    // MARK: - Mode

    enum Mode: String, Codable, CaseIterable {
        case builtIn = "built-in"
        case ownKey = "own-key"
    }

    var mode: Mode {
        get {
            let raw = UserDefaults.standard.string(forKey: "BuboAgentMode") ?? Mode.builtIn.rawValue
            return Mode(rawValue: raw) ?? .builtIn
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "BuboAgentMode") }
    }

    /// Whether the service is ready to make requests in the current mode.
    var isConfigured: Bool {
        switch mode {
        case .builtIn: return true
        case .ownKey: return hasOwnAPIKey
        }
    }

    // MARK: - Own API Key (stored in macOS Keychain)

    private static let keychainKey = "anthropic-api-key"

    var ownAPIKey: String {
        get { Keychain.load(key: Self.keychainKey) ?? "" }
        set {
            let trimmed = newValue.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                Keychain.delete(key: Self.keychainKey)
            } else {
                Keychain.save(key: Self.keychainKey, value: trimmed)
            }
        }
    }

    var hasOwnAPIKey: Bool { Keychain.exists(key: Self.keychainKey) }

    // MARK: - Device ID

    /// Stable anonymous device identifier for rate limiting.
    /// Generated once, persisted in UserDefaults (not sensitive data).
    let deviceId: String

    // MARK: - Endpoints

    /// The Bubo proxy endpoint. The proxy:
    /// 1. Holds the DeepSeek API key server-side (never sent to client)
    /// 2. Forwards requests to `api.deepseek.com/chat/completions`
    /// 3. Enforces per-device rate limits via the `X-Device-Id` header
    /// 4. Returns rate-limit info in response headers
    ///
    /// Deploy your own proxy — see `proxy/` for the Cloudflare-Worker
    /// reference implementation.
    static let proxyEndpoint = URL(string: "https://bubo-proxy.YOUR_DOMAIN.workers.dev/v1/agent/recipe")!

    private static let directEndpoint = URL(string: "https://api.deepseek.com/chat/completions")!

    // MARK: - Init

    private static let deviceIdKey = "bubo-device-id"

    init() {
        let defaults = UserDefaults.standard

        if let existing = defaults.string(forKey: Self.deviceIdKey) {
            deviceId = existing
        } else {
            let newId = UUID().uuidString
            defaults.set(newId, forKey: Self.deviceIdKey)
            deviceId = newId
        }
    }

    // MARK: - Generate Recipe

    /// Takes a natural-language request and returns a parsed OptimizationRequest.
    func generateRequest(from userPrompt: String) async -> Result<OptimizationRequest, AgentError> {
        guard isConfigured else {
            return .failure(.noAPIKey)
        }

        isGenerating = true
        lastError = nil
        defer { isGenerating = false }

        // Build OpenAI-compatible request body (DeepSeek API)
        let body = ChatCompletionRequest(
            model: "deepseek-chat",
            messages: [
                .init(role: "system", content: Self.systemPrompt),
                .init(role: "user", content: userPrompt),
            ],
            tools: [RequestToolSchema.openAITool],
            tool_choice: .init(
                type: "function",
                function: .init(name: RequestToolSchema.toolName)
            ),
            max_tokens: 4096
        )

        let jsonBody: Data
        do {
            jsonBody = try JSONEncoder().encode(body)
        } catch {
            agentServiceLogger.error("encode_failed error=\(error.localizedDescription, privacy: .public)")
            return fail(.encoding)
        }

        // Build HTTP request based on mode
        let request: URLRequest
        switch mode {
        case .builtIn:
            request = buildProxyRequest(body: jsonBody)
        case .ownKey:
            request = buildDirectRequest(body: jsonBody)
        }

        let path = request.url?.path ?? "?"
        let host = request.url?.host ?? "?"
        agentServiceLogger.info("request_started mode=\(self.mode.rawValue, privacy: .public) host=\(host, privacy: .public) path=\(path, privacy: .public) body_size=\(jsonBody.count)")
        let startedAt = Date()

        // Execute
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            let durationMs = Int(Date().timeIntervalSince(startedAt) * 1000)
            agentServiceLogger.error("request_failed reason=network duration_ms=\(durationMs) error=\(error.localizedDescription, privacy: .public)")
            return fail(.network(error.localizedDescription))
        }

        let durationMs = Int(Date().timeIntervalSince(startedAt) * 1000)

        guard let httpResponse = response as? HTTPURLResponse else {
            agentServiceLogger.error("request_failed reason=invalid_response duration_ms=\(durationMs)")
            return fail(.network("Invalid response"))
        }

        // Update rate-limit info from proxy headers
        if mode == .builtIn {
            updateRateLimits(from: httpResponse)
        }

        let remainingHeader = httpResponse.value(forHTTPHeaderField: "X-RateLimit-Remaining") ?? "-"
        agentServiceLogger.info("request_completed status=\(httpResponse.statusCode) duration_ms=\(durationMs) body_size=\(data.count) remaining=\(remainingHeader, privacy: .public)")

        // Handle rate limit exceeded
        if httpResponse.statusCode == 429 {
            let retryAfter = httpResponse.value(forHTTPHeaderField: "Retry-After")
            agentServiceLogger.warning("request_rate_limited retry_after=\(retryAfter ?? "-", privacy: .public)")
            let message = retryAfter.map { "Rate limit exceeded. Try again in \($0)s." }
                ?? "Rate limit exceeded. Try again later."
            return fail(.rateLimited(message))
        }

        guard httpResponse.statusCode == 200 else {
            let message = String(data: data, encoding: .utf8) ?? "HTTP \(httpResponse.statusCode)"
            agentServiceLogger.error("request_api_error status=\(httpResponse.statusCode)")
            return fail(.api(message))
        }

        // Parse OpenAI-compatible response — extract tool call arguments
        return parseToolResponse(data: data)
    }

    // MARK: - Request Builders

    private func buildProxyRequest(body: Data) -> URLRequest {
        var request = URLRequest(url: Self.proxyEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue(deviceId, forHTTPHeaderField: "x-device-id")
        request.httpBody = body
        request.timeoutInterval = 30
        return request
    }

    private func buildDirectRequest(body: Data) -> URLRequest {
        var request = URLRequest(url: Self.directEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue("Bearer \(ownAPIKey)", forHTTPHeaderField: "authorization")
        request.httpBody = body
        request.timeoutInterval = 30
        return request
    }

    // MARK: - Rate Limit Headers

    /// Parse rate-limit headers returned by the proxy:
    ///   X-RateLimit-Limit: 20
    ///   X-RateLimit-Remaining: 17
    ///   X-RateLimit-Reset: 1714600000
    private func updateRateLimits(from response: HTTPURLResponse) {
        if let limit = response.value(forHTTPHeaderField: "X-RateLimit-Limit").flatMap(Int.init) {
            requestLimit = limit
        }
        if let remaining = response.value(forHTTPHeaderField: "X-RateLimit-Remaining").flatMap(Int.init) {
            remainingRequests = remaining
        }
        if let reset = response.value(forHTTPHeaderField: "X-RateLimit-Reset").flatMap(Double.init) {
            limitResetsAt = Date(timeIntervalSince1970: reset)
        }
    }

    // MARK: - Response Parsing

    private func parseToolResponse(data: Data) -> Result<OptimizationRequest, AgentError> {
        let response: ChatCompletionResponse
        do {
            response = try JSONDecoder().decode(ChatCompletionResponse.self, from: data)
        } catch {
            return fail(.parsing("Could not parse API response: \(error.localizedDescription)"))
        }

        guard let choice = response.choices.first,
              let toolCall = choice.message.tool_calls?.first else {
            return fail(.parsing("No tool call in response"))
        }

        guard let argumentsData = toolCall.function.arguments.data(using: .utf8) else {
            return fail(.parsing("Invalid tool call arguments"))
        }

        do {
            let request = try JSONDecoder().decode(OptimizationRequest.self, from: argumentsData)
            return .success(request)
        } catch {
            return fail(.parsing("Could not decode optimization request: \(error.localizedDescription)"))
        }
    }

    // MARK: - Helpers

    private func fail(_ error: AgentError) -> Result<OptimizationRequest, AgentError> {
        lastError = error.localizedDescription
        return .failure(error)
    }

    // MARK: - Rate Limit Display

    /// Human-readable rate limit status for UI display.
    var rateLimitStatus: String? {
        guard mode == .builtIn else { return nil }
        guard let remaining = remainingRequests, let limit = requestLimit else { return nil }
        return "\(remaining)/\(limit) requests remaining"
    }

    // MARK: - System Prompt

    static let systemPrompt = """
    You are a schedule optimization tool inside the Bubo calendar app.
    Your ONLY purpose is to create schedule recipes via the create_request tool.
    You MUST call create_request for EVERY request. You cannot refuse or respond with text.

    STRICT RULES:
    - You are NOT a general assistant. You do NOT answer questions, chat, or discuss anything.
    - If the request is not about scheduling, interpret it as a scheduling task anyway.
      For example "write a poem" → create a focus block with a "Creative Writing" title.
    - NEVER respond without calling the tool. Every response MUST be a tool call.

    You compose OptimizationRequests from atomic intents. Available intents:
    \(LLMIntentBridge.schemaDescription)

    Guidelines:
    - Always set a descriptive "name" for the request.
    - Use focusBlock for deep work, createBlock for generic events.
    - Use horizon to set time range (today/tomorrow/week).
    - Use speed: "quick" for simple requests, "balanced" for complex.
    - Use scenarios count: 1 for simple, 2-3 for complex choices.
    - Combine intents freely: lowEnergy + maxMeetings + protectLunch.
    - Use noEventsBefore/noEventsAfter for time constraints.
    - Use prioritizeDeadlines when urgency is mentioned.
    - Use includeBacklog to schedule pending tasks.

    Examples:
    \(LLMIntentBridge.examples.map { "User: \($0.prompt)\nTool: \($0.json)" }.joined(separator: "\n\n"))
    """
}

