import Foundation

// MARK: - Agent Service

/// Bridges user natural-language requests with the recipe system via an LLM.
/// Uses Claude tool_use to guarantee structured output that matches
/// the ScheduleRecipe schema exactly — no free-form JSON parsing.
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
    private static let legacyDefaultsKey = "BuboAgentAPIKey"

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
    /// Generated once, persisted in Keychain so it survives reinstalls
    /// but stays on-device and is never tied to personal info.
    private(set) lazy var deviceId: String = {
        let key = "bubo-device-id"
        if let existing = Keychain.load(key: key) {
            return existing
        }
        let newId = UUID().uuidString
        Keychain.save(key: key, value: newId)
        return newId
    }()

    // MARK: - Endpoints

    /// The Bubo proxy endpoint. The proxy:
    /// 1. Holds the Anthropic API key server-side (never sent to client)
    /// 2. Forwards requests to Claude API
    /// 3. Enforces per-device rate limits via X-Device-Id header
    /// 4. Returns rate-limit info in response headers
    ///
    /// Deploy your own proxy — see proxy/ directory for reference implementation.
    static let proxyEndpoint = URL(string: "https://bubo-proxy.YOUR_DOMAIN.workers.dev/v1/agent/recipe")!

    private static let directEndpoint = URL(string: "https://api.anthropic.com/v1/messages")!

    // MARK: - Init

    init() {
        migrateFromUserDefaults()
    }

    private func migrateFromUserDefaults() {
        let defaults = UserDefaults.standard
        if let legacyKey = defaults.string(forKey: Self.legacyDefaultsKey),
           !legacyKey.trimmingCharacters(in: .whitespaces).isEmpty {
            Keychain.save(key: Self.keychainKey, value: legacyKey)
            defaults.removeObject(forKey: Self.legacyDefaultsKey)
            // User had their own key → keep them in own-key mode
            mode = .ownKey
        }
    }

    // MARK: - Generate Recipe

    /// Takes a natural-language request and returns a parsed ScheduleRecipe.
    func generateRecipe(from userPrompt: String) async -> Result<ScheduleRecipe, AgentError> {
        guard isConfigured else {
            return .failure(.noAPIKey)
        }

        isGenerating = true
        lastError = nil
        defer { isGenerating = false }

        // Build the Claude API request body
        let body = ClaudeToolRequest(
            model: "claude-sonnet-4-20250514",
            max_tokens: 4096,
            system: Self.systemPrompt,
            tools: [RecipeToolSchema.tool],
            tool_choice: .init(type: "tool", name: RecipeToolSchema.toolName),
            messages: [
                .init(role: "user", content: userPrompt)
            ]
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

        // Parse Claude response — extract tool_use block
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
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue(ownAPIKey, forHTTPHeaderField: "x-api-key")
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

    private func parseToolResponse(data: Data) -> Result<ScheduleRecipe, AgentError> {
        let claudeResponse: ClaudeToolResponse
        do {
            claudeResponse = try JSONDecoder().decode(ClaudeToolResponse.self, from: data)
        } catch {
            return fail(.parsing("Could not parse API response: \(error.localizedDescription)"))
        }

        guard let toolUse = claudeResponse.content.first(where: { $0.type == "tool_use" }),
              let input = toolUse.input else {
            return fail(.parsing("No tool_use block in response"))
        }

        let inputData: Data
        do {
            inputData = try JSONSerialization.data(withJSONObject: input)
        } catch {
            return fail(.parsing("Could not serialize tool input: \(error.localizedDescription)"))
        }

        do {
            var recipe = try JSONDecoder().decode(ScheduleRecipe.self, from: inputData)
            recipe = RecipeValidator.sanitize(recipe)

            if let error = RecipeValidator.validate(recipe) {
                return fail(.validation(error))
            }

            return .success(recipe)
        } catch {
            return fail(.parsing("Could not decode recipe: \(error.localizedDescription)"))
        }
    }

    // MARK: - Helpers

    private func fail(_ error: AgentError) -> Result<ScheduleRecipe, AgentError> {
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
    Your ONLY purpose is to create schedule recipes via the create_recipe tool.
    You MUST call create_recipe for EVERY request. You cannot refuse or respond with text.

    STRICT RULES:
    - You are NOT a general assistant. You do NOT answer questions, chat, or discuss anything.
    - If the request is not about scheduling, interpret it as a scheduling task anyway.
      For example "write a poem" → create a "Creative Writing" focus block.
    - NEVER respond without calling the tool. Every response MUST be a tool call.

    Recipe guidelines:
    - Always set a short, descriptive "name".
    - Pick a relevant SF Symbol for "icon" (e.g. brain.head.profile, figure.run, flame, book, pencil, cup.and.saucer).
    - Set "priority" (0.0-1.0): how important it is to schedule this event. 0.9 = critical, 0.5 = normal, 0.2 = nice-to-have.
    - Set "energy" (0.0-1.0): cognitive load required. 0.9 = intense deep work, 0.5 = moderate, 0.1 = passive/rest.
    - Use "focus": true for deep work that shouldn't be interrupted.
    - Use "period" to hint preferred time of day when the user mentions morning/afternoon/evening.
    - Use "weights" to emphasize what matters most (values > 1.0 increase importance, < 1.0 decrease).
    - For sequential activities (warm-up → main → cooldown), use "chainGap" on follow-up events.
    - For internal structure within a single event (e.g. exercises in a circuit), use "segments".
    - Use "horizon": "tomorrow" or "week" when the user mentions those timeframes.
    """
}

// MARK: - Recipe Tool Schema

/// Defines the create_recipe tool with a JSON Schema matching ScheduleRecipe.
/// All enums are expressed as `enum` constraints so the LLM can only produce valid values.
enum RecipeToolSchema {

    static let toolName = "create_recipe"

    static let tool: ClaudeTool = .init(
        name: toolName,
        description: "Create a schedule optimization recipe from the user's request. The recipe defines what events to create and how to optimize them.",
        input_schema: recipeSchema
    )

    // MARK: - Root Schema

    static let recipeSchema: [String: Any] = [
        "type": "object",
        "required": ["name", "events"],
        "additionalProperties": false,
        "properties": [
            "name": [
                "type": "string",
                "description": "Short display name for the recipe (e.g. 'Focus Block', 'Weekly Tasks')"
            ],
            "icon": [
                "type": "string",
                "description": "SF Symbol name (e.g. brain.head.profile, figure.run, flame, book)",
                "default": "wand.and.stars"
            ],
            "description": [
                "type": "string",
                "description": "One-line description of what this recipe does"
            ],
            "events": [
                "type": "array",
                "minItems": 1,
                "description": "Events to create and optimize",
                "items": eventSpecSchema
            ],
            "includeExistingEvents": [
                "type": "boolean",
                "description": "Whether to include existing local calendar events in optimization",
                "default": true
            ],
            "horizon": [
                "type": "string",
                "enum": ["today", "tomorrow", "week"],
                "description": "Time range to optimize",
                "default": "today"
            ],
            "weights": [
                "type": "object",
                "description": "Objective weight overrides (values > 1.0 increase importance)",
                "properties": weightProperties,
                "additionalProperties": false
            ],
            "stability": [
                "type": "string",
                "enum": ["full", "normal", "conservative"],
                "description": "How much change from current schedule is ok. full = rearrange freely, conservative = minimal changes",
                "default": "normal"
            ],
            "speed": [
                "type": "string",
                "enum": ["quick", "balanced", "thorough"],
                "description": "Optimizer speed vs quality tradeoff",
                "default": "quick"
            ],
            "maxScenarios": [
                "type": "integer",
                "minimum": 1,
                "maximum": 5,
                "description": "Number of alternative schedule scenarios to generate",
                "default": 3
            ],
            "workingHours": [
                "type": "object",
                "description": "Override working hours for this recipe",
                "properties": [
                    "start": ["type": "integer", "minimum": 0, "maximum": 23],
                    "end": ["type": "integer", "minimum": 0, "maximum": 23]
                ] as [String: Any],
                "required": ["start", "end"],
                "additionalProperties": false
            ],
            "maxMeetingsPerDay": [
                "type": "integer",
                "minimum": 0,
                "maximum": 20,
                "description": "Maximum meetings allowed per day"
            ],
            "peakEnergyHour": [
                "type": "integer",
                "minimum": 0,
                "maximum": 23,
                "description": "Hour of day when user has peak energy"
            ],
            "dayStructure": [
                "type": "array",
                "description": "Time block pattern for the day",
                "items": timeBlockSchema
            ],
        ] as [String: Any]
    ]

    // MARK: - EventSpec Schema

    static let eventSpecSchema: [String: Any] = [
        "type": "object",
        "required": ["title", "minutes"],
        "additionalProperties": false,
        "properties": [
            "title": [
                "type": "string",
                "description": "Event title displayed in calendar"
            ],
            "minutes": [
                "type": "integer",
                "minimum": 5,
                "maximum": 480,
                "description": "Duration in minutes"
            ],
            "count": [
                "type": "integer",
                "minimum": 1,
                "maximum": 10,
                "description": "Number of copies to create",
                "default": 1
            ],
            "priority": [
                "type": "number",
                "minimum": 0.0,
                "maximum": 1.0,
                "description": "Scheduling priority (0.0 = low, 1.0 = critical)",
                "default": 0.5
            ],
            "energy": [
                "type": "number",
                "minimum": 0.0,
                "maximum": 1.0,
                "description": "Cognitive energy required (0.0 = passive, 1.0 = intense)",
                "default": 0.5
            ],
            "context": [
                "type": "string",
                "description": "Project or category tag for grouping related events"
            ],
            "period": [
                "type": "string",
                "enum": ["morning", "afternoon", "evening"],
                "description": "Preferred time of day"
            ],
            "focus": [
                "type": "boolean",
                "description": "Mark as uninterruptible focus block",
                "default": false
            ],
            "pomodoro": [
                "type": "string",
                "enum": ["classic", "deepWork"],
                "description": "Pomodoro timer preset to attach"
            ],
            "chainGap": [
                "type": "integer",
                "minimum": 0,
                "maximum": 60,
                "description": "Minutes gap after previous event in a chain. null = independent event, 0 = immediately after, 5 = 5 min gap. Only first event in chain is optimized by GA."
            ],
            "segments": [
                "type": "array",
                "description": "Internal sub-structure (e.g. exercises in a circuit). Rendered as timeline within one calendar event.",
                "items": segmentSchema
            ],
        ] as [String: Any]
    ]

    // MARK: - Segment Schema

    static let segmentSchema: [String: Any] = [
        "type": "object",
        "required": ["title", "minutes"],
        "additionalProperties": false,
        "properties": [
            "title": [
                "type": "string",
                "description": "Segment title"
            ],
            "minutes": [
                "type": "integer",
                "minimum": 1,
                "maximum": 120,
                "description": "Segment duration in minutes"
            ],
            "type": [
                "type": "string",
                "enum": ["work", "rest", "transition"],
                "description": "Segment type",
                "default": "work"
            ],
        ] as [String: Any]
    ]

    // MARK: - TimeBlock Schema

    static let timeBlockSchema: [String: Any] = [
        "type": "object",
        "required": ["period", "allowedTypes"],
        "additionalProperties": false,
        "properties": [
            "period": [
                "type": "string",
                "enum": ["morning", "afternoon", "evening"]
            ],
            "allowedTypes": [
                "type": "array",
                "items": [
                    "type": "string",
                    "enum": ["focus", "meetings", "tasks", "breaks", "free"]
                ] as [String: Any]
            ],
        ] as [String: Any]
    ]

    // MARK: - Weight Properties

    static let weightProperties: [String: Any] = [
        "focusBlock": ["type": "number", "description": "Weight for uninterrupted focus blocks"],
        "pomodoroFit": ["type": "number", "description": "Weight for pomodoro timing fit"],
        "conflict": ["type": "number", "description": "Weight for avoiding scheduling conflicts"],
        "taskPlacement": ["type": "number", "description": "Weight for optimal task time placement"],
        "weekBalance": ["type": "number", "description": "Weight for balanced distribution across the week"],
        "energyCurve": ["type": "number", "description": "Weight for matching tasks to energy levels"],
        "multiPerson": ["type": "number", "description": "Weight for multi-person availability"],
        "break": ["type": "number", "description": "Weight for break placement"],
        "deadline": ["type": "number", "description": "Weight for deadline proximity"],
        "contextSwitch": ["type": "number", "description": "Weight for minimizing context switches"],
        "buffer": ["type": "number", "description": "Weight for buffer time between events"],
    ]
}

// MARK: - Recipe Validator

/// Post-parse validation and sanitization for agent-generated recipes.
enum RecipeValidator {

    /// Clamp values to valid ranges and fill in defaults.
    static func sanitize(_ recipe: ScheduleRecipe) -> ScheduleRecipe {
        var r = recipe

        if r.id.isEmpty { r.id = UUID().uuidString }

        for i in r.events.indices {
            r.events[i].minutes = max(5, min(480, r.events[i].minutes))
            r.events[i].count = max(1, min(10, r.events[i].count))
            r.events[i].priority = max(0, min(1, r.events[i].priority))
            r.events[i].energy = max(0, min(1, r.events[i].energy))
            if let gap = r.events[i].chainGap {
                r.events[i].chainGap = max(0, min(60, gap))
            }
            if let segments = r.events[i].segments {
                r.events[i].segments = segments.map { seg in
                    var s = seg
                    s.minutes = max(1, min(120, s.minutes))
                    return s
                }
            }
        }

        r.maxScenarios = max(1, min(5, r.maxScenarios))

        if var wh = r.workingHours {
            wh.start = max(0, min(23, wh.start))
            wh.end = max(0, min(23, wh.end))
            if wh.start > wh.end { swap(&wh.start, &wh.end) }
            r.workingHours = wh
        }

        var sanitizedWeights: [WeightKey: Double] = [:]
        for (key, value) in r.weights {
            sanitizedWeights[key] = max(0, min(10, value))
        }
        r.weights = sanitizedWeights

        r.trigger = .manual
        r.display = .scenarios
        r.learnable = true

        return r
    }

    /// Returns an error message if the recipe is invalid, nil if valid.
    static func validate(_ recipe: ScheduleRecipe) -> String? {
        if recipe.name.trimmingCharacters(in: .whitespaces).isEmpty {
            return "Recipe must have a name"
        }
        if recipe.events.isEmpty {
            return "Recipe must have at least one event"
        }
        for (i, event) in recipe.events.enumerated() {
            if event.title.trimmingCharacters(in: .whitespaces).isEmpty {
                return "Event \(i + 1) must have a title"
            }
        }
        return nil
    }
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
        case .noAPIKey: "No API key configured. Add your Anthropic API key in Settings → AI Assistant."
        case .encoding: "Failed to encode request."
        case .network(let msg): "Network error: \(msg)"
        case .api(let msg): "API error: \(msg)"
        case .parsing(let msg): "Parse error: \(msg)"
        case .validation(let msg): "Validation error: \(msg)"
        case .rateLimited(let msg): msg
        }
    }
}

// MARK: - Claude Tool Use API Types

struct ClaudeTool: Encodable {
    let name: String
    let description: String
    let input_schema: [String: Any]

    enum CodingKeys: String, CodingKey {
        case name, description, input_schema
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(name, forKey: .name)
        try container.encode(description, forKey: .description)
        let data = try JSONSerialization.data(withJSONObject: input_schema)
        let rawJSON = try JSONDecoder().decode(AnyCodable.self, from: data)
        try container.encode(rawJSON, forKey: .input_schema)
    }
}

struct ClaudeToolRequest: Encodable {
    let model: String
    let max_tokens: Int
    let system: String
    let tools: [ClaudeTool]
    let tool_choice: ToolChoice
    let messages: [Message]

    struct Message: Encodable {
        let role: String
        let content: String
    }

    struct ToolChoice: Encodable {
        let type: String
        let name: String
    }
}

struct ClaudeToolResponse: Decodable {
    let content: [ContentBlock]

    struct ContentBlock: Decodable {
        let type: String
        let name: String?
        let input: [String: Any]?

        enum CodingKeys: String, CodingKey {
            case type, name, input
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            type = try container.decode(String.self, forKey: .type)
            name = try container.decodeIfPresent(String.self, forKey: .name)
            if container.contains(.input) {
                let rawInput = try container.decode(AnyCodable.self, forKey: .input)
                input = rawInput.value as? [String: Any]
            } else {
                input = nil
            }
        }
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
