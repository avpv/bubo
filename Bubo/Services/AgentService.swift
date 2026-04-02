import Foundation

// MARK: - Agent Service

/// Bridges user natural-language requests with the recipe system via an LLM.
/// Uses Claude tool_use to guarantee structured output that matches
/// the ScheduleRecipe schema exactly — no free-form JSON parsing.
@MainActor
@Observable
final class AgentService {

    // MARK: - State

    private(set) var isGenerating: Bool = false
    private(set) var lastError: String? = nil

    // MARK: - API Key (stored in macOS Keychain)

    private static let keychainKey = "anthropic-api-key"
    private static let legacyDefaultsKey = "BuboAgentAPIKey"

    var apiKey: String {
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

    var hasAPIKey: Bool { Keychain.exists(key: Self.keychainKey) }

    private let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!

    init() {
        migrateFromUserDefaults()
    }

    /// One-time migration: move API key from UserDefaults to Keychain, then delete the plaintext copy.
    private func migrateFromUserDefaults() {
        let defaults = UserDefaults.standard
        if let legacyKey = defaults.string(forKey: Self.legacyDefaultsKey),
           !legacyKey.trimmingCharacters(in: .whitespaces).isEmpty {
            Keychain.save(key: Self.keychainKey, value: legacyKey)
            defaults.removeObject(forKey: Self.legacyDefaultsKey)
        }
    }

    // MARK: - Generate Recipe

    /// Takes a natural-language request and returns a parsed ScheduleRecipe.
    /// Uses tool_use to force structured output matching the recipe schema.
    func generateRecipe(from userPrompt: String) async -> Result<ScheduleRecipe, AgentError> {
        guard hasAPIKey else {
            return .failure(.noAPIKey)
        }

        isGenerating = true
        lastError = nil
        defer { isGenerating = false }

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

        // Parse Claude response — extract tool_use block
        let claudeResponse: ClaudeToolResponse
        do {
            claudeResponse = try JSONDecoder().decode(ClaudeToolResponse.self, from: data)
        } catch {
            let err = AgentError.parsing("Could not parse API response: \(error.localizedDescription)")
            lastError = err.localizedDescription
            return .failure(err)
        }

        guard let toolUse = claudeResponse.content.first(where: { $0.type == "tool_use" }),
              let input = toolUse.input else {
            let err = AgentError.parsing("No tool_use block in response")
            lastError = err.localizedDescription
            return .failure(err)
        }

        // The tool input IS the recipe — already structured by the schema
        let inputData: Data
        do {
            inputData = try JSONSerialization.data(withJSONObject: input)
        } catch {
            let err = AgentError.parsing("Could not serialize tool input: \(error.localizedDescription)")
            lastError = err.localizedDescription
            return .failure(err)
        }

        do {
            var recipe = try JSONDecoder().decode(ScheduleRecipe.self, from: inputData)
            recipe = RecipeValidator.sanitize(recipe)

            if let error = RecipeValidator.validate(recipe) {
                let err = AgentError.validation(error)
                lastError = err.localizedDescription
                return .failure(err)
            }

            return .success(recipe)
        } catch {
            let err = AgentError.parsing("Could not decode recipe: \(error.localizedDescription)")
            lastError = err.localizedDescription
            return .failure(err)
        }
    }

    // MARK: - System Prompt

    static let systemPrompt = """
    You are a schedule optimization assistant inside the Bubo calendar app.
    The user describes what they want to schedule in natural language.
    Use the create_recipe tool to generate a schedule recipe.

    Guidelines:
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

        // Ensure ID
        if r.id.isEmpty { r.id = UUID().uuidString }

        // Clamp event values
        for i in r.events.indices {
            r.events[i].minutes = max(5, min(480, r.events[i].minutes))
            r.events[i].count = max(1, min(10, r.events[i].count))
            r.events[i].priority = max(0, min(1, r.events[i].priority))
            r.events[i].energy = max(0, min(1, r.events[i].energy))
            if let gap = r.events[i].chainGap {
                r.events[i].chainGap = max(0, min(60, gap))
            }
            // Clamp segment minutes
            if let segments = r.events[i].segments {
                r.events[i].segments = segments.map { seg in
                    var s = seg
                    s.minutes = max(1, min(120, s.minutes))
                    return s
                }
            }
        }

        // Clamp scenario count
        r.maxScenarios = max(1, min(5, r.maxScenarios))

        // Clamp working hours
        if var wh = r.workingHours {
            wh.start = max(0, min(23, wh.start))
            wh.end = max(0, min(23, wh.end))
            if wh.start > wh.end { swap(&wh.start, &wh.end) }
            r.workingHours = wh
        }

        // Clamp weight values to reasonable range
        var sanitizedWeights: [WeightKey: Double] = [:]
        for (key, value) in r.weights {
            sanitizedWeights[key] = max(0, min(10, value))
        }
        r.weights = sanitizedWeights

        // Agent recipes are always manual trigger, scenarios display
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

    var errorDescription: String? {
        switch self {
        case .noAPIKey: "No API key configured. Add your Anthropic API key in Settings → AI Assistant."
        case .encoding: "Failed to encode request."
        case .network(let msg): "Network error: \(msg)"
        case .api(let msg): "API error: \(msg)"
        case .parsing(let msg): "Parse error: \(msg)"
        case .validation(let msg): "Validation error: \(msg)"
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
        // Encode the schema dict as raw JSON
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

/// Wraps any JSON-compatible value for Codable round-tripping.
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
