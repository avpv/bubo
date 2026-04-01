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
            XCTAssertFalse(recipe.icon.isEmpty, "Recipe \(recipe.id) has no icon")
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
}
