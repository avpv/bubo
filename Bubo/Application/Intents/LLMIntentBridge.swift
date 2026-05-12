import Foundation
import os

private let logger = Logger(subsystem: "com.avpv.Bubo", category: "Optimizer/Intents")

// MARK: - LLM Intent Bridge

/// Bridges LLM-generated JSON with the intent execution system.
/// The LLM constructs an array of ScheduleIntents as JSON;
/// the bridge parses and executes through IntentCompiler.
///
/// This is simpler than LLMRecipeBridge because intents are atomic
/// and the LLM doesn't need to understand the full 10-dimensional recipe space.
@MainActor
struct LLMIntentBridge {

    let optimizerService: OptimizerService
    let reminderService: ReminderService

    // MARK: - Execute from JSON

    func executeFromJSON(_ json: String) async -> OptimizationResult {
        guard let data = json.data(using: .utf8) else {
            logger.error("intents_parse_failed source=llm reason=invalid_utf8")
            return .infeasible(reason: "Invalid JSON string")
        }

        let request: OptimizationRequest
        do {
            request = try JSONDecoder().decode(OptimizationRequest.self, from: data)
        } catch {
            logger.error("intents_parse_failed source=llm reason=decode error=\(error.localizedDescription, privacy: .public) body_size=\(data.count)")
            return .infeasible(reason: "Could not parse intents: \(error.localizedDescription)")
        }

        // Interpolated lazily: OSLog captures the map+join call site
        // and only evaluates it when the message is actually recorded.
        logger.info("intents_parsed source=llm count=\(request.intents.count) cases=\(request.intents.map(\.caseName).joined(separator: ","), privacy: .public)")

        return await optimizerService.executeRequest(request, reminderService: reminderService)
    }

    /// Parse and validate without executing (for preview).
    func parseRequest(from json: String) -> Result<OptimizationRequest, ParseError> {
        guard let data = json.data(using: .utf8) else {
            return .failure(ParseError(message: "Invalid JSON string"))
        }
        do {
            let request = try JSONDecoder().decode(OptimizationRequest.self, from: data)
            return .success(request)
        } catch {
            return .failure(ParseError(message: "Parse error: \(error.localizedDescription)"))
        }
    }

    struct ParseError: Error, LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    // MARK: - Schema for LLM System Prompt

    /// Concise schema for the LLM to generate valid intent JSON.
    /// Much simpler than the full ScheduleRecipe schema.
    static let schemaDescription = """
    {
      "intents": [
        // Time constraints
        {"noEventsBefore": {"hour": 11}},
        {"noEventsAfter": {"hour": 17}},
        {"workingHours": {"start": 9, "end": 18}},
        {"horizon": "today" | "tomorrow" | "week"},

        // Create events
        {"focusBlock": {"minutes": 120, "period": "morning"}},
        {"createBlock": {"title": "...", "minutes": 60, "period": "afternoon", "focus": false}},
        "pomodoroSession",
    {"focusBurst": {"maxTasks": 4, "contextFilter": "project-name?"}},

        // Priorities (weight: 0.5-5.0, default 1.0)
        {"prioritizeDeadlines": {"weight": 2.0}},
        {"prioritizeFocus": {"weight": 2.0}},
        {"minimizeContextSwitching": {"weight": 1.5}},
        {"groupByProject": {"weight": 1.5}},
        {"batchMeetings": {"weight": 1.5}},

        // Energy
        "lowEnergy",
        {"peakEnergy": {"hour": 10}},
        "morningPerson",
        {"protectLunch": {"start": 12, "end": 14}},
        {"breakEvery": {"workMinutes": 60, "breakMinutes": 10}},
        {"maxMeetings": {"perDay": 3}},

        // Stability
        {"stability": "full" | "normal" | "conservative"},

        // Tasks
        "includeBacklog",
        "findSlotsForBacklog",

        // Speed
        {"speed": "quick" | "balanced" | "thorough"},

        // Display
        {"scenarios": {"count": 1-3}}
      ],
      "name": "optional preset name"
    }
    """

    /// Example intents for LLM few-shot prompting.
    static let examples: [(prompt: String, json: String)] = [
        (
            "Find 2 hours of focus time tomorrow morning",
            """
            {"intents":[{"focusBlock":{"minutes":120,"period":"morning"}},{"horizon":"tomorrow"},{"speed":"quick"},{"scenarios":{"count":1}}]}
            """
        ),
        (
            "I'm low energy today, protect my lunch, max 3 meetings",
            """
            {"intents":["lowEnergy",{"maxMeetings":{"perDay":3}},{"protectLunch":{"start":12,"end":14}},{"horizon":"today"},{"speed":"balanced"},{"scenarios":{"count":2}}]}
            """
        ),
        (
            "Schedule my backlog tasks for this week, prioritize deadlines",
            """
            {"intents":["includeBacklog",{"horizon":"week"},{"prioritizeDeadlines":{"weight":2.0}},{"speed":"thorough"},{"scenarios":{"count":3}}]}
            """
        ),
        (
            "Late start today, nothing before 11",
            """
            {"intents":[{"noEventsBefore":{"hour":11}},{"horizon":"today"},{"stability":"conservative"},{"speed":"quick"},{"scenarios":{"count":1}}]}
            """
        ),
    ]
}
