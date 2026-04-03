import XCTest
@testable import Bubo

final class RecipeTests: XCTestCase {

    // MARK: - ScheduleRecipe Model

    func testRecipeDefaultsAreReasonable() {
        let recipe = ScheduleRecipe()
        XCTAssertTrue(recipe.events.isEmpty)
        XCTAssertTrue(recipe.includeExistingEvents)
        XCTAssertEqual(recipe.horizon, .today)
        XCTAssertTrue(recipe.weights.isEmpty)
        XCTAssertEqual(recipe.stability, .normal)
        XCTAssertEqual(recipe.speed, .quick)
        XCTAssertTrue(recipe.eventRules.isEmpty)
        XCTAssertTrue(recipe.conditions.isEmpty)
        XCTAssertTrue(recipe.dayStructure.isEmpty)
        XCTAssertEqual(recipe.trigger, .manual)
        XCTAssertEqual(recipe.display, .scenarios)
        XCTAssertTrue(recipe.params.isEmpty)
        XCTAssertEqual(recipe.maxScenarios, 3)
        XCTAssertTrue(recipe.learnable)
    }

    func testRecipeCodableRoundTrip() throws {
        let recipe = ScheduleRecipe.needFocus(minutes: 90)
        let data = try JSONEncoder().encode(recipe)
        let decoded = try JSONDecoder().decode(ScheduleRecipe.self, from: data)

        XCTAssertEqual(decoded.id, recipe.id)
        XCTAssertEqual(decoded.name, "Need Focus")
        XCTAssertEqual(decoded.events.count, 1)
        XCTAssertEqual(decoded.events.first?.minutes, 90)
        XCTAssertEqual(decoded.events.first?.focus, true)
        XCTAssertEqual(decoded.weights[.focusBlock], 2.0)
        XCTAssertEqual(decoded.params.count, 1)
    }

    func testRecipeWithWeightsCodable() throws {
        var recipe = ScheduleRecipe()
        recipe.weights = [.focusBlock: 3.0, .deadline: 8.0, .breakPlacement: 0.5]

        let data = try JSONEncoder().encode(recipe)
        let decoded = try JSONDecoder().decode(ScheduleRecipe.self, from: data)

        XCTAssertEqual(decoded.weights[.focusBlock], 3.0)
        XCTAssertEqual(decoded.weights[.deadline], 8.0)
        XCTAssertEqual(decoded.weights[.breakPlacement], 0.5)
        XCTAssertNil(decoded.weights[.buffer])
    }

    // MARK: - Param Application

    func testApplyParamMinutes() {
        var recipe = ScheduleRecipe.needFocus(minutes: 120)
        XCTAssertEqual(recipe.events.first?.minutes, 120)

        recipe.applyParamValues(["minutes": 60])
        XCTAssertEqual(recipe.events.first?.minutes, 60)
    }

    func testApplyParamCount() {
        var recipe = ScheduleRecipe.deepWorkDay(count: 2, minutes: 120)
        XCTAssertEqual(recipe.events.first?.count, 2)

        recipe.applyParamValues(["count": 4])
        XCTAssertEqual(recipe.events.first?.count, 4)
    }

    func testApplyParamWorkingHours() {
        var recipe = ScheduleRecipe.shortDay(endHour: 15)
        XCTAssertEqual(recipe.workingHours?.end, 15)

        recipe.applyParamValues(["end": 13])
        XCTAssertEqual(recipe.workingHours?.end, 13)
        XCTAssertEqual(recipe.workingHours?.start, 9)
    }

    func testApplyParamPlaceholder() {
        var recipe = ScheduleRecipe.prioritizeProject()
        XCTAssertEqual(recipe.eventRules.first?.match, .context("$project"))

        recipe.applyParamValues(["project": "MyApp"])
        XCTAssertEqual(recipe.eventRules.first?.match, .context("MyApp"))
    }

    func testApplyParamPlaceholderInCreationMode() {
        var recipe = ScheduleRecipe.splitLargeTask()
        if case .splitEvent(let id) = recipe.events.first?.creation {
            XCTAssertEqual(id, "$eventId")
        } else {
            XCTFail("Expected splitEvent creation mode")
        }

        recipe.applyParamValues(["eventId": "abc-123"])
        if case .splitEvent(let id) = recipe.events.first?.creation {
            XCTAssertEqual(id, "abc-123")
        } else {
            XCTFail("Expected splitEvent creation mode")
        }
    }

    func testApplyParamPlaceholderInPostActions() {
        var recipe = ScheduleRecipe.splitLargeTask()
        let hasRemoveAction = recipe.postActions.contains { action in
            if case .removeOriginalEvent(let id) = action { return id == "$eventId" }
            return false
        }
        XCTAssertTrue(hasRemoveAction)

        recipe.applyParamValues(["eventId": "xyz"])
        let hasResolvedAction = recipe.postActions.contains { action in
            if case .removeOriginalEvent(let id) = action { return id == "xyz" }
            return false
        }
        XCTAssertTrue(hasResolvedAction)
    }

    // MARK: - Catalog

    func testCatalogQuickActionsNotEmpty() {
        XCTAssertFalse(RecipeCatalog.quickActions.isEmpty)
    }

    func testCatalogAllCategoriesHaveRecipes() {
        for category in RecipeCatalog.allCategories {
            XCTAssertFalse(category.recipes.isEmpty, "Category '\(category.name)' has no recipes")
        }
    }

    func testCatalogRecipesHaveUniqueIds() {
        let allRecipes = RecipeCatalog.allCategories.flatMap(\.recipes)
        let ids = allRecipes.map(\.id)
        let uniqueIds = Set(ids)
        XCTAssertEqual(ids.count, uniqueIds.count, "Duplicate recipe IDs found")
    }

    func testCatalogAllRecipesHaveNames() {
        let allRecipes = RecipeCatalog.allCategories.flatMap(\.recipes)
        for recipe in allRecipes {
            XCTAssertFalse(recipe.name.isEmpty, "Recipe \(recipe.id) has no name")
        }
    }

    func testCatalogReactionsHaveNonManualTriggers() {
        for recipe in RecipeCatalog.reactions {
            XCTAssertNotEqual(recipe.trigger, .manual, "Reaction \(recipe.id) should have a non-manual trigger")
        }
    }

    // MARK: - EventSpec

    func testEventSpecDefaults() {
        let spec = EventSpec()
        XCTAssertEqual(spec.title, "Event")
        XCTAssertEqual(spec.minutes, 60)
        XCTAssertEqual(spec.count, 1)
        XCTAssertEqual(spec.priority, 0.5)
        XCTAssertEqual(spec.energy, 0.5)
        XCTAssertFalse(spec.focus)
        XCTAssertEqual(spec.creation, .fixed)
    }

    // MARK: - Speed → GA Config

    func testSpeedMapsToGAConfiguration() {
        XCTAssertEqual(Speed.quick.gaConfiguration.populationSize, 50)
        XCTAssertEqual(Speed.balanced.gaConfiguration.populationSize, 100)
        XCTAssertEqual(Speed.thorough.gaConfiguration.populationSize, 200)
    }

    // MARK: - Period → Hour Range

    func testPeriodHourRanges() {
        XCTAssertEqual(Period.morning.hourRange, 7...12)
        XCTAssertEqual(Period.afternoon.hourRange, 12...17)
        XCTAssertEqual(Period.evening.hourRange, 17...21)
    }

    // MARK: - HourRange

    func testHourRangeCodable() throws {
        let range = HourRange(start: 9, end: 15)
        let data = try JSONEncoder().encode(range)
        let decoded = try JSONDecoder().decode(HourRange.self, from: data)
        XCTAssertEqual(decoded.start, 9)
        XCTAssertEqual(decoded.end, 15)
        XCTAssertEqual(decoded.closedRange, 9...15)
    }

    // MARK: - Preset Recipes Smoke Tests

    func testOrganizeDayPreset() {
        let recipe = ScheduleRecipe.organizeDay
        XCTAssertEqual(recipe.horizon, .today)
        XCTAssertEqual(recipe.speed, .quick)
        XCTAssertTrue(recipe.includeExistingEvents)
        XCTAssertTrue(recipe.params.isEmpty) // 1-click
    }

    func testPlanWeekPreset() {
        let recipe = ScheduleRecipe.planWeek
        XCTAssertEqual(recipe.horizon, .week)
        XCTAssertEqual(recipe.speed, .balanced)
        XCTAssertTrue(recipe.params.isEmpty)
    }

    func testDeadlineModePreset() {
        let recipe = ScheduleRecipe.deadlineMode
        XCTAssertEqual(recipe.weights[.deadline], 8.0)
        XCTAssertFalse(recipe.conditions.isEmpty)
        XCTAssertFalse(recipe.eventRules.isEmpty)
    }

    func testFreeFridayPreset() {
        let recipe = ScheduleRecipe.freeFriday
        XCTAssertEqual(recipe.horizon, .week)
        XCTAssertFalse(recipe.eventRules.isEmpty)
        // Should restrict all events to Mon-Thu (days 2-5)
        if case .restrictToDays(let days) = recipe.eventRules.first?.action {
            XCTAssertEqual(days, [2, 3, 4, 5])
        } else {
            XCTFail("Expected restrictToDays action")
        }
    }

    func testFocusMeetingSplitPreset() {
        let recipe = ScheduleRecipe.focusMeetingSplit
        XCTAssertEqual(recipe.speed, .thorough)
        XCTAssertEqual(recipe.eventRules.count, 2)
    }

    func testAutopilotReaction() {
        let recipe = ScheduleRecipe.onEventDeleted
        XCTAssertEqual(recipe.trigger, .eventDeleted)
        XCTAssertEqual(recipe.stability, .conservative)
        XCTAssertFalse(recipe.learnable)
    }

    func testLikeYesterdayUsesLearnedWeights() {
        let recipe = ScheduleRecipe.likeYesterday
        XCTAssertNotNil(recipe.weights[.useLearned])
    }

    // MARK: - Chain Events

    func testChainGapDefault() {
        let spec = EventSpec()
        XCTAssertNil(spec.chainGap, "Default chainGap should be nil (independent)")
    }

    func testChainedEventsInCircuitTraining() {
        let recipe = ScheduleRecipe.circuitTraining(rounds: 3)
        // Should have: Round1, Break, Round2, Break, Round3 = 5 events
        XCTAssertEqual(recipe.events.count, 5)

        // First event: no chain (it's the head)
        XCTAssertNil(recipe.events[0].chainGap)

        // Rest are chained
        for i in 1..<recipe.events.count {
            XCTAssertEqual(recipe.events[i].chainGap, 0, "Event \(i) should be chained")
        }
    }

    func testCircuitTrainingSegments() {
        let recipe = ScheduleRecipe.circuitTraining(rounds: 3, exercises: 4)
        // First round should have segments (detailed exercise breakdown)
        XCTAssertNotNil(recipe.events.first?.segments)
        let segments = recipe.events.first!.segments!
        // 4 exercises + 3 rests = 7 segments
        XCTAssertEqual(segments.count, 7)
        XCTAssertEqual(segments.filter { $0.type == .work }.count, 4)
        XCTAssertEqual(segments.filter { $0.type == .rest }.count, 3)
    }

    func testYogaSessionSegments() {
        let recipe = ScheduleRecipe.yogaSession(minutes: 60)
        XCTAssertEqual(recipe.events.count, 1)
        let segments = recipe.events.first?.segments
        XCTAssertNotNil(segments)
        XCTAssertEqual(segments?.count, 3) // warm-up, practice, savasana
        XCTAssertEqual(segments?[0].type, .transition) // warm-up
        XCTAssertEqual(segments?[1].type, .work)       // practice
        XCTAssertEqual(segments?[2].type, .rest)        // savasana
    }

    func testIntervalTrainingSegments() {
        let recipe = ScheduleRecipe.intervalTraining(intervals: 6)
        XCTAssertEqual(recipe.events.count, 1)
        let segments = recipe.events.first?.segments
        XCTAssertNotNil(segments)
        // warm-up + 6 intervals + 5 recoveries + cool-down = 13
        XCTAssertEqual(segments?.count, 13)
        XCTAssertEqual(segments?.first?.type, .transition) // warm-up
        XCTAssertEqual(segments?.last?.type, .transition)  // cool-down
    }

    // MARK: - Event Segments

    func testEventSegmentCodable() throws {
        let segment = EventSegment(title: "Squats", minutes: 3, type: .work)
        let data = try JSONEncoder().encode(segment)
        let decoded = try JSONDecoder().decode(EventSegment.self, from: data)
        XCTAssertEqual(decoded.title, "Squats")
        XCTAssertEqual(decoded.minutes, 3)
        XCTAssertEqual(decoded.type, .work)
    }

    func testEventSpecWithSegmentsCodable() throws {
        let spec = EventSpec(
            title: "Workout",
            minutes: 30,
            segments: [
                EventSegment(title: "Warm-up", minutes: 5, type: .transition),
                EventSegment(title: "Exercise", minutes: 20, type: .work),
                EventSegment(title: "Cool-down", minutes: 5, type: .rest),
            ]
        )
        let data = try JSONEncoder().encode(spec)
        let decoded = try JSONDecoder().decode(EventSpec.self, from: data)
        XCTAssertEqual(decoded.segments?.count, 3)
        XCTAssertEqual(decoded.segments?[1].title, "Exercise")
    }

    // MARK: - LLM Bridge

    func testLLMBridgeSchemaNotEmpty() {
        XCTAssertFalse(LLMRecipeBridge.schemaDescription.isEmpty)
        XCTAssertTrue(LLMRecipeBridge.schemaDescription.contains("chainGap"))
        XCTAssertTrue(LLMRecipeBridge.schemaDescription.contains("segments"))
    }

    func testLLMBridgeExamplesAreValidJSON() throws {
        for (prompt, json) in LLMRecipeBridge.examples {
            guard let data = json.data(using: .utf8) else {
                XCTFail("Example for '\(prompt)' is not valid UTF-8")
                continue
            }
            do {
                _ = try JSONDecoder().decode(ScheduleRecipe.self, from: data)
            } catch {
                XCTFail("Example for '\(prompt)' doesn't decode: \(error)")
            }
        }
    }

    func testChainedRecipeCodableRoundTrip() throws {
        let recipe = ScheduleRecipe.circuitTraining(rounds: 2)
        let data = try JSONEncoder().encode(recipe)
        let decoded = try JSONDecoder().decode(ScheduleRecipe.self, from: data)
        XCTAssertEqual(decoded.events.count, recipe.events.count)
        XCTAssertNil(decoded.events[0].chainGap)
        XCTAssertEqual(decoded.events[1].chainGap, 0)
    }

    // MARK: - Partial JSON Decoding (LLM responses)

    func testPartialJSONDecodesWithDefaults() throws {
        // LLM typically returns only name + events — all other fields should get defaults
        let json = """
        {
            "name": "Событие",
            "events": [
                {"title": "Встреча", "minutes": 30}
            ]
        }
        """
        let data = json.data(using: .utf8)!
        let recipe = try JSONDecoder().decode(ScheduleRecipe.self, from: data)

        XCTAssertEqual(recipe.name, "Событие")
        XCTAssertEqual(recipe.events.count, 1)
        XCTAssertEqual(recipe.events[0].title, "Встреча")
        XCTAssertEqual(recipe.events[0].minutes, 30)
        // Defaults
        XCTAssertEqual(recipe.events[0].count, 1)
        XCTAssertEqual(recipe.events[0].priority, 0.5)
        XCTAssertFalse(recipe.events[0].focus)
        XCTAssertEqual(recipe.horizon, .today)
        XCTAssertEqual(recipe.stability, .normal)
        XCTAssertEqual(recipe.speed, .quick)
        XCTAssertTrue(recipe.includeExistingEvents)
        XCTAssertEqual(recipe.maxScenarios, 3)
        XCTAssertTrue(recipe.learnable)
    }

    func testMinimalEventSpecDecodes() throws {
        let json = """
        {"title": "Test", "minutes": 15}
        """
        let data = json.data(using: .utf8)!
        let spec = try JSONDecoder().decode(EventSpec.self, from: data)
        XCTAssertEqual(spec.title, "Test")
        XCTAssertEqual(spec.minutes, 15)
        XCTAssertEqual(spec.count, 1)
        XCTAssertEqual(spec.energy, 0.5)
        XCTAssertNil(spec.period)
        XCTAssertNil(spec.chainGap)
        XCTAssertNil(spec.startOffsetMinutes)
        XCTAssertEqual(spec.creation, .fixed)
    }

    // MARK: - startOffsetMinutes

    func testStartOffsetMinutesDecodes() throws {
        let json = """
        {"title": "Think", "minutes": 30, "startOffsetMinutes": 5}
        """
        let data = json.data(using: .utf8)!
        let spec = try JSONDecoder().decode(EventSpec.self, from: data)
        XCTAssertEqual(spec.startOffsetMinutes, 5)
    }

    func testStartOffsetMinutesDefaultsToNil() throws {
        let json = """
        {"title": "Think", "minutes": 30}
        """
        let data = json.data(using: .utf8)!
        let spec = try JSONDecoder().decode(EventSpec.self, from: data)
        XCTAssertNil(spec.startOffsetMinutes)
    }

    func testStartOffsetMinutesCodableRoundTrip() throws {
        let spec = EventSpec(title: "Later", minutes: 45, startOffsetMinutes: 10)
        let data = try JSONEncoder().encode(spec)
        let decoded = try JSONDecoder().decode(EventSpec.self, from: data)
        XCTAssertEqual(decoded.startOffsetMinutes, 10)
    }

    func testLLMBridgeSchemaContainsStartOffset() {
        XCTAssertTrue(LLMRecipeBridge.schemaDescription.contains("startOffsetMinutes"))
    }
}
