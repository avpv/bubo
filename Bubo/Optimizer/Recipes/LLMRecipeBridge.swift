import Foundation

// MARK: - LLM Recipe Bridge

/// Bridges LLM-generated JSON with the recipe execution system.
/// The LLM constructs a ScheduleRecipe as JSON, the bridge
/// parses and executes it through RecipeExecutor.
@MainActor
struct LLMRecipeBridge {

    let optimizerService: OptimizerService
    let reminderService: ReminderService

    // MARK: - Execute from JSON

    /// Parse LLM-generated JSON into a ScheduleRecipe and execute it.
    func executeFromJSON(_ json: String) async -> RecipeResult {
        guard let data = json.data(using: .utf8) else {
            return .infeasible(reason: "Invalid JSON string")
        }

        let recipe: ScheduleRecipe
        do {
            recipe = try JSONDecoder().decode(ScheduleRecipe.self, from: data)
        } catch {
            return .infeasible(reason: "Could not parse recipe: \(error.localizedDescription)")
        }

        return await optimizerService.executeRecipe(
            recipe,
            reminderService: reminderService
        )
    }

    /// Parse and validate without executing (for preview).
    struct ParseError: Error, LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    func parseRecipe(from json: String) -> Result<ScheduleRecipe, ParseError> {
        guard let data = json.data(using: .utf8) else {
            return .failure(ParseError(message: "Invalid JSON string"))
        }

        do {
            let recipe = try JSONDecoder().decode(ScheduleRecipe.self, from: data)
            return .success(recipe)
        } catch {
            return .failure(ParseError(message: "Parse error: \(error.localizedDescription)"))
        }
    }

    // MARK: - Schema for LLM System Prompt

    /// A concise schema description to include in the LLM system prompt.
    /// The LLM uses this to generate valid ScheduleRecipe JSON.
    ///
    /// Note: For structured output, prefer `RecipeToolSchema` (used by AgentService)
    /// which provides a full JSON Schema with enum constraints via Claude tool_use.
    /// This text description is kept for contexts where tool_use is not available.
    static let schemaDescription = """
    You can create schedule optimization recipes as JSON objects.

    ## ScheduleRecipe
    {
      "name": "string (required)",
      "description": "string (optional)",
      "events": [EventSpec array (required, at least 1)],
      "includeExistingEvents": bool (default: true),
      "horizon": "today" | "tomorrow" | "week" (default: "today"),
      "weights": { WeightKey: double } (optional overrides),
      "speed": "quick" | "balanced" | "thorough" (default: "quick"),
      "stability": "full" | "normal" | "conservative" (default: "normal"),
      "maxScenarios": int 1-5 (default: 3),
      "workingHours": {"start": 0-23, "end": 0-23} (optional),
      "maxMeetingsPerDay": int 0-20 (optional),
      "peakEnergyHour": int 0-23 (optional)
    }

    ## EventSpec
    {
      "title": "string (required)",
      "minutes": int 5-480 (required),
      "count": int 1-10 (default: 1, creates N copies),
      "priority": 0.0-1.0 (default: 0.5),
      "energy": 0.0-1.0 (default: 0.5, cognitive load),
      "context": "string (optional, project/category tag)",
      "period": "morning" | "afternoon" | "evening" (optional preferred time),
      "focus": bool (default: false, marks as uninterruptible),
      "pomodoro": "classic" | "deepWork" (optional),
      "chainGap": int 0-60 (optional, minutes after previous event; creates sequential chain),
      "segments": [EventSegment array] (optional, sub-structure within event)
    }

    ## EventSegment
    {
      "title": "string",
      "minutes": int 1-120,
      "type": "work" | "rest" | "transition"
    }

    ## WeightKey values (all optional, number type)
    "focusBlock", "pomodoroFit", "conflict", "taskPlacement",
    "weekBalance", "energyCurve", "multiPerson", "break",
    "deadline", "contextSwitch", "buffer"

    ## Chain events
    Use "chainGap" to create sequential events. Only the first event
    (without chainGap) is optimized; the rest follow it sequentially.
    Example: 3 training rounds with 5 min rest between:
    "events": [
      {"title": "Round 1", "minutes": 15, "energy": 0.9},
      {"title": "Rest", "minutes": 5, "energy": 0.0, "chainGap": 0},
      {"title": "Round 2", "minutes": 15, "energy": 0.9, "chainGap": 0},
      {"title": "Rest", "minutes": 5, "energy": 0.0, "chainGap": 0},
      {"title": "Round 3", "minutes": 15, "energy": 0.9, "chainGap": 0}
    ]

    ## Segments (internal structure, single calendar event)
    Use "segments" for detailed internal structure like circuit exercises:
    "events": [{
      "title": "Circuit Training",
      "minutes": 48,
      "segments": [
        {"title": "Squats", "minutes": 3, "type": "work"},
        {"title": "Rest", "minutes": 1, "type": "rest"},
        {"title": "Push-ups", "minutes": 3, "type": "work"},
        {"title": "Rest", "minutes": 1, "type": "rest"}
      ]
    }]
    """

    // MARK: - Examples

    /// Example recipes that demonstrate common patterns for LLM reference.
    static let examples: [(prompt: String, json: String)] = [
        (
            "Schedule a 2-hour focus block tomorrow morning",
            """
            {
              "name": "Focus Block",
              "icon": "brain.head.profile",
              "events": [{"title": "Focus Time", "minutes": 120, "priority": 0.9, "energy": 0.7, "period": "morning", "focus": true}],
              "horizon": "tomorrow",
              "weights": {"focusBlock": 2.0}
            }
            """
        ),
        (
            "Circuit training: 3 rounds of 4 exercises (3 min each, 1 min rest), 3 min rest between rounds",
            """
            {
              "name": "Circuit Training",
              "icon": "figure.run",
              "events": [
                {"title": "Round 1", "minutes": 15, "energy": 0.9, "segments": [
                  {"title": "Squats", "minutes": 3, "type": "work"},
                  {"title": "Rest", "minutes": 1, "type": "rest"},
                  {"title": "Push-ups", "minutes": 3, "type": "work"},
                  {"title": "Rest", "minutes": 1, "type": "rest"},
                  {"title": "Plank", "minutes": 3, "type": "work"},
                  {"title": "Rest", "minutes": 1, "type": "rest"},
                  {"title": "Lunges", "minutes": 3, "type": "work"}
                ]},
                {"title": "Round Break", "minutes": 3, "energy": 0.0, "chainGap": 0},
                {"title": "Round 2", "minutes": 15, "energy": 0.9, "chainGap": 0},
                {"title": "Round Break", "minutes": 3, "energy": 0.0, "chainGap": 0},
                {"title": "Round 3", "minutes": 15, "energy": 0.9, "chainGap": 0}
              ],
              "weights": {"energyCurve": 2.0},
              "speed": "quick"
            }
            """
        ),
        (
            "I have 5 tasks to fit into this week",
            """
            {
              "name": "Weekly Tasks",
              "events": [
                {"title": "Write report", "minutes": 120, "priority": 0.9, "energy": 0.8, "focus": true},
                {"title": "Code review", "minutes": 60, "priority": 0.7, "energy": 0.6},
                {"title": "Update docs", "minutes": 90, "priority": 0.5, "energy": 0.4},
                {"title": "Team sync prep", "minutes": 30, "priority": 0.8, "energy": 0.3},
                {"title": "Research", "minutes": 60, "priority": 0.6, "energy": 0.7, "focus": true}
              ],
              "horizon": "week",
              "speed": "balanced",
              "weights": {"weekBalance": 1.5, "energyCurve": 1.5}
            }
            """
        ),
        (
            "Yoga session: warm-up 10 min, main practice 40 min, savasana 10 min",
            """
            {
              "name": "Yoga Session",
              "icon": "figure.yoga",
              "events": [{
                "title": "Yoga",
                "minutes": 60,
                "energy": 0.4,
                "period": "morning",
                "segments": [
                  {"title": "Warm-up", "minutes": 10, "type": "transition"},
                  {"title": "Main Practice", "minutes": 40, "type": "work"},
                  {"title": "Savasana", "minutes": 10, "type": "rest"}
                ]
              }],
              "weights": {"energyCurve": 1.5}
            }
            """
        ),
    ]
}
