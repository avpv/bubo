import Foundation

// MARK: - Agent Service

/// Bridges user natural-language requests with the recipe system via an LLM.
/// Uses Claude tool_use to guarantee structured output that matches
/// the OptimizationRequest schema — no free-form JSON parsing.
///
/// Supports two modes:
/// - **Built-in** (default): requests go through the Bubo proxy which holds
///   the API key server-side and enforces per-device rate limits.
/// - **Own key**: user provides their own Anthropic API key stored in Keychain;
///   requests go directly to the Anthropic API with no rate limits.
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
    /// 1. Holds the Anthropic API key server-side (never sent to client)
    /// 2. Forwards requests to Claude API
    /// 3. Enforces per-device rate limits via X-Device-Id header
    /// 4. Returns rate-limit info in response headers
    ///
    /// Deploy your own proxy — see proxy/ directory for reference implementation.
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

        guard let jsonBody = try? JSONEncoder().encode(body) else {
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

        // Execute
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            return fail(.network(error.localizedDescription))
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            return fail(.network("Invalid response"))
        }

        // Update rate-limit info from proxy headers
        if mode == .builtIn {
            updateRateLimits(from: httpResponse)
        }

        // Handle rate limit exceeded
        if httpResponse.statusCode == 429 {
            let retryAfter = httpResponse.value(forHTTPHeaderField: "Retry-After")
            let message = retryAfter.map { "Rate limit exceeded. Try again in \($0)s." }
                ?? "Rate limit exceeded. Try again later."
            return fail(.rateLimited(message))
        }

        guard httpResponse.statusCode == 200 else {
            let message = String(data: data, encoding: .utf8) ?? "HTTP \(httpResponse.statusCode)"
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

// MARK: - Recipe Tool Schema

/// Defines the create_request tool with a JSON Schema matching OptimizationRequest.
enum RequestToolSchema {

    static let toolName = "create_request"

    /// Tool definition in OpenAI-compatible format (used by DeepSeek API).
    static let openAITool = OpenAITool(
        function: .init(
            name: toolName,
            description: "Create a schedule optimization request from composable intents. Each intent is an atomic scheduling instruction.",
            parameters: requestSchema
        )
    )

    // MARK: - Root Schema

    static let requestSchema: [String: Any] = [
        "type": "object",
        "required": ["intents"],
        "additionalProperties": false,
        "properties": [
            "name": [
                "type": "string",
                "description": "Short display name (e.g. 'Focus Block', 'Weekly Plan')"
            ],
            "intents": [
                "type": "array",
                "description": """
                Composable scheduling intents. Each intent is an object with one key.
                Available intents:
                - {"focusBlock": {"minutes": 120, "period": "morning"}} — create focus time
                - {"createBlock": {"title": "...", "minutes": 60, "period": "afternoon"}} — generic event
                - {"pomodoroSession": {"preset": "classic"}} — pomodoro block
                - {"noEventsBefore": {"hour": 11}} — block early hours
                - {"noEventsAfter": {"hour": 17}} — block late hours
                - {"horizon": "today"} — today/tomorrow/week
                - {"prioritizeDeadlines": {"weight": 2.0}} — boost deadline urgency
                - {"prioritizeFocus": {"weight": 2.0}} — boost focus quality
                - {"minimizeContextSwitching": {"weight": 1.5}} — reduce context switches
                - {"batchMeetings": {"weight": 1.5}} — cluster meetings
                - "lowEnergy" — low energy mode
                - "morningPerson" — prefer morning schedule
                - {"peakEnergy": {"hour": 10}} — peak energy time
                - {"protectLunch": {"start": 12, "end": 14}} — keep lunch free
                - {"breakEvery": {"workMinutes": 60, "breakMinutes": 10}} — regular breaks
                - {"maxMeetings": {"perDay": 3}} — meeting cap
                - {"stability": "conservative"} — full/normal/conservative
                - "includeBacklog" — include pending tasks
                - "findSlotsForBacklog" — find slots for tasks
                - {"speed": "quick"} — quick/balanced/thorough
                - {"scenarios": {"count": 1}} — how many options (1-3)
                """,
                "minItems": 1,
                "items": ["type": "object"] as [String: Any]
            ],
        ] as [String: Any]
    ]
}

// MARK: - Errors

enum AgentError: Error, LocalizedError {
    case noAPIKey
    case encoding
    case network(String)
    case api(String)
    case parsing(String)
    case validation(String)
    case rateLimited(String)

    var errorDescription: String? {
        switch self {
        case .noAPIKey: "No API key configured. Add your DeepSeek API key in Settings → AI Assistant."
        case .encoding: "Failed to encode request."
        case .network(let msg): "Network error: \(msg)"
        case .api(let msg): "API error: \(msg)"
        case .parsing(let msg): "Parse error: \(msg)"
        case .validation(let msg): "Validation error: \(msg)"
        case .rateLimited(let msg): msg
        }
    }
}

// MARK: - OpenAI-Compatible API Types (DeepSeek)

/// Tool definition in OpenAI format (wraps function in a type envelope).
struct OpenAITool: Encodable {
    let type = "function"
    let function: FunctionDef

    struct FunctionDef: Encodable {
        let name: String
        let description: String
        let parameters: [String: Any]

        enum CodingKeys: String, CodingKey {
            case name, description, parameters
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(name, forKey: .name)
            try container.encode(description, forKey: .description)
            let data = try JSONSerialization.data(withJSONObject: parameters)
            let rawJSON = try JSONDecoder().decode(AnyCodable.self, from: data)
            try container.encode(rawJSON, forKey: .parameters)
        }
    }
}

struct ChatCompletionRequest: Encodable {
    let model: String
    let messages: [Message]
    let tools: [OpenAITool]
    let tool_choice: ToolChoice
    let max_tokens: Int

    struct Message: Encodable {
        let role: String
        let content: String
    }

    struct ToolChoice: Encodable {
        let type: String
        let function: FunctionName

        struct FunctionName: Encodable {
            let name: String
        }
    }
}

struct ChatCompletionResponse: Decodable {
    let choices: [Choice]

    struct Choice: Decodable {
        let message: ResponseMessage
    }

    struct ResponseMessage: Decodable {
        let tool_calls: [ToolCall]?
    }

    struct ToolCall: Decodable {
        let function: FunctionCall
    }

    struct FunctionCall: Decodable {
        let name: String
        let arguments: String // JSON string
    }
}

// MARK: - AnyCodable (for encoding/decoding arbitrary JSON)

struct AnyCodable: Codable {
    let value: Any

    init(_ value: Any) { self.value = value }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            value = NSNull()
        } else if let b = try? container.decode(Bool.self) {
            value = b
        } else if let i = try? container.decode(Int.self) {
            value = i
        } else if let d = try? container.decode(Double.self) {
            value = d
        } else if let s = try? container.decode(String.self) {
            value = s
        } else if let arr = try? container.decode([AnyCodable].self) {
            value = arr.map(\.value)
        } else if let dict = try? container.decode([String: AnyCodable].self) {
            value = dict.mapValues(\.value)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported JSON type")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch value {
        case is NSNull:
            try container.encodeNil()
        case let b as Bool:
            try container.encode(b)
        case let i as Int:
            try container.encode(i)
        case let d as Double:
            try container.encode(d)
        case let s as String:
            try container.encode(s)
        case let arr as [Any]:
            try container.encode(arr.map { AnyCodable($0) })
        case let dict as [String: Any]:
            try container.encode(dict.mapValues { AnyCodable($0) })
        default:
            throw EncodingError.invalidValue(value, .init(codingPath: encoder.codingPath, debugDescription: "Unsupported type"))
        }
    }
}
