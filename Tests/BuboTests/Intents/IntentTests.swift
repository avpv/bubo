import XCTest
@testable import Bubo
@testable import BuboDomain
@testable import BuboOptimizer

final class IntentTests: XCTestCase {

    // MARK: - OptimizationRequest Composition

    func testRequestComposition() {
        var request = OptimizationRequest(.horizon(.today), name: "Test")
        request.add(.focusBlock(minutes: 120))
        request.add(.lowEnergy)

        XCTAssertEqual(request.intents.count, 3)
        XCTAssertEqual(request.name, "Test")
        XCTAssertTrue(request.isCreative)
    }

    func testRequestMerge() {
        var base = OptimizationRequest(.horizon(.today), .speed(.quick))
        let overlay = OptimizationRequest(.lowEnergy, .prioritizeDeadlines())

        base.merge(overlay)
        XCTAssertEqual(base.intents.count, 4)
    }

    func testRequestToggle() {
        var request = OptimizationRequest(.lowEnergy, .morningPerson)
        request.toggle(.lowEnergy)  // remove
        XCTAssertEqual(request.intents.count, 1)

        request.toggle(.lowEnergy)  // add back
        XCTAssertEqual(request.intents.count, 2)
    }

    func testRequestRemoveIntent() {
        var request = OptimizationRequest(.horizon(.today), .lowEnergy, .speed(.quick))
        request.removeIntent(at: 1)
        XCTAssertEqual(request.intents.count, 2)
        // lowEnergy should be removed, leaving horizon and speed
    }

    func testRequestIsCreative() {
        let creative = OptimizationRequest(.focusBlock(minutes: 60))
        XCTAssertTrue(creative.isCreative)

        let nonCreative = OptimizationRequest(.prioritizeDeadlines())
        XCTAssertFalse(nonCreative.isCreative)
    }

    func testRequestFindSlotOnly() {
        let slotFinding = OptimizationRequest(.findSlotsForBacklog)
        XCTAssertTrue(slotFinding.findSlotOnly)

        let normal = OptimizationRequest(.horizon(.today))
        XCTAssertFalse(normal.findSlotOnly)
    }

    func testRequestSpeedAccessor() {
        var request = OptimizationRequest(.speed(.thorough))
        XCTAssertEqual(request.speed, .thorough)

        request.speed = .quick
        XCTAssertEqual(request.speed, .quick)
        // Should only have one speed intent
        let speedCount = request.intents.filter {
            if case .speed = $0 { return true }
            return false
        }.count
        XCTAssertEqual(speedCount, 1)
    }

    func testRequestMatchesSearch() {
        let request = OptimizationRequest(
            .focusBlock(minutes: 120),
            name: "Deep Focus",
            description: "Find a focus slot"
        )
        XCTAssertTrue(request.matchesSearch("focus"))
        XCTAssertTrue(request.matchesSearch("Deep"))
        XCTAssertFalse(request.matchesSearch("meeting"))
    }

    func testRequestAvailableIntents() {
        let request = OptimizationRequest(.lowEnergy)
        let available = request.availableIntents
        // lowEnergy should NOT be in available since it's already present
        XCTAssertFalse(available.contains(.lowEnergy))
        // morningPerson should be available
        XCTAssertTrue(available.contains(.morningPerson))
    }

    // MARK: - Intent Labels

    func testIntentLabels() {
        XCTAssertEqual(ScheduleIntent.lowEnergy.label, "Low energy mode")
        XCTAssertEqual(ScheduleIntent.noEventsBefore(hour: 11).label, "No events before 11:00")
        XCTAssertEqual(ScheduleIntent.focusBlock(minutes: 90, period: .morning).label, "Focus 90 min, morning")
        XCTAssertEqual(ScheduleIntent.speed(.thorough).label, "Speed: thorough")
    }

    func testIntentCategories() {
        XCTAssertEqual(ScheduleIntent.focusBlock(minutes: 60).category, .create)
        XCTAssertEqual(ScheduleIntent.noEventsBefore(hour: 9).category, .time)
        XCTAssertEqual(ScheduleIntent.lowEnergy.category, .energy)
        XCTAssertEqual(ScheduleIntent.prioritizeDeadlines().category, .weights)
        XCTAssertEqual(ScheduleIntent.includeBacklog.category, .tasks)
        XCTAssertEqual(ScheduleIntent.speed(.quick).category, .meta)
    }

    // MARK: - Presets

    func testPresetsHaveNames() {
        for preset in IntentPresets.all {
            XCTAssertNotNil(preset.name, "Preset must have a name")
            XCTAssertFalse(preset.intents.isEmpty, "Preset \(preset.name ?? "?") must have intents")
        }
    }

    func testPresetsAllHaveSpeed() {
        for preset in IntentPresets.all {
            let hasSpeed = preset.intents.contains {
                if case .speed = $0 { return true }
                return false
            }
            XCTAssertTrue(hasSpeed, "Preset \(preset.name ?? "?") should have a speed intent")
        }
    }

    func testPresetsAllHaveScenarios() {
        for preset in IntentPresets.all {
            let hasScenarios = preset.intents.contains {
                if case .scenarios = $0 { return true }
                return false
            }
            XCTAssertTrue(hasScenarios, "Preset \(preset.name ?? "?") should have a scenarios intent")
        }
    }

    func testQuickActionsAreSubsetOfAll() {
        let allNames = Set(IntentPresets.all.compactMap(\.name))
        for action in IntentPresets.quickActions {
            XCTAssertTrue(allNames.contains(action.name ?? ""), "Quick action \(action.name ?? "?") should be in all presets")
        }
    }

    func testCategoriesAreNonEmpty() {
        for category in IntentPresets.allCategories {
            XCTAssertFalse(category.presets.isEmpty, "Category \(category.name) should not be empty")
        }
    }
}
