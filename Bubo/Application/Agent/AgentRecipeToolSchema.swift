import Foundation

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
                - "pomodoroSession" — pomodoro block (optimizer picks work/break/rounds)
                - {"focusBurst": {"maxTasks": 4, "contextFilter": "..."}} — pack up to N small related tasks into one pomodoro, one task per work round
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

