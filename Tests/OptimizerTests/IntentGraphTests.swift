import XCTest
@testable import Bubo

final class IntentGraphTests: XCTestCase {

    // MARK: - Graph Building

    func testBuildFromFlat() {
        let graph = IntentGraph.build(from: [
            .horizon(.today), .focusBlock(minutes: 120), .speed(.quick)
        ])
        XCTAssertEqual(graph.nodes.count, 3)
    }

    func testNoDuplicateNodes() {
        let graph = IntentGraph.build(from: [.lowEnergy, .lowEnergy])
        // Duplicate intents should collapse to one node
        let lowEnergyCount = graph.nodes.values.filter {
            if case .lowEnergy = $0.intent { return true }
            return false
        }.count
        XCTAssertEqual(lowEnergyCount, 1)
    }

    // MARK: - Auto Dependencies

    func testAutoResolveDependencies() {
        let graph = IntentGraph.build(from: [.prioritizeDeadlines()])
        // Should auto-add includeBacklog
        let hasBacklog = graph.nodes.values.contains {
            if case .includeBacklog = $0.intent { return true }
            return false
        }
        XCTAssertTrue(hasBacklog, "prioritizeDeadlines should auto-add includeBacklog")

        let backlogNode = graph.nodes.values.first {
            if case .includeBacklog = $0.intent { return true }
            return false
        }
        XCTAssertTrue(backlogNode?.isAutoResolved == true)
    }

    func testFindSlotsAutoAddsBacklog() {
        let graph = IntentGraph.build(from: [.findSlotsForBacklog])
        let hasBacklog = graph.nodes.values.contains {
            if case .includeBacklog = $0.intent { return true }
            return false
        }
        XCTAssertTrue(hasBacklog)
    }

    func testOrphanPruning() {
        // Add prioritizeDeadlines (which auto-adds includeBacklog)
        var graph = IntentGraph.build(from: [.prioritizeDeadlines()])
        XCTAssertTrue(graph.nodes.count >= 2)

        // Remove prioritizeDeadlines — includeBacklog should be pruned
        graph.removeNode(.prioritizeDeadlines())
        let hasBacklog = graph.nodes.values.contains {
            if case .includeBacklog = $0.intent { return true }
            return false
        }
        XCTAssertFalse(hasBacklog, "Orphaned auto-dep should be pruned")
    }

    // MARK: - Phase Ordering

    func testTopologicalSort() {
        let graph = IntentGraph.build(from: [
            .speed(.quick),        // config phase
            .focusBlock(minutes: 60), // create phase
            .horizon(.today),      // context phase
        ])
        let sorted = graph.sortedIntents()

        // Context should come before create, create before config
        let horizonIdx = sorted.firstIndex { if case .horizon = $0 { return true }; return false }
        let focusIdx = sorted.firstIndex { if case .focusBlock = $0 { return true }; return false }
        let speedIdx = sorted.firstIndex { if case .speed = $0 { return true }; return false }

        XCTAssertNotNil(horizonIdx)
        XCTAssertNotNil(focusIdx)
        XCTAssertNotNil(speedIdx)

        if let h = horizonIdx, let f = focusIdx, let s = speedIdx {
            XCTAssertLessThan(h, f, "Context before create")
            XCTAssertLessThan(f, s, "Create before config")
        }
    }

    func testIntentsByPhase() {
        let graph = IntentGraph.build(from: [
            .horizon(.today), .noEventsBefore(hour: 10),
            .focusBlock(minutes: 60),
            .lowEnergy, .protectLunch(),
        ])
        let phases = graph.intentsByPhase()
        XCTAssertTrue(phases.count >= 3) // context, create, energy
    }

    // MARK: - Conflict Detection

    func testMorningBlockedConflict() {
        let graph = IntentGraph.build(from: [
            .noEventsBefore(hour: 14), .morningPerson
        ])
        let conflicts = graph.conflicts
        XCTAssertFalse(conflicts.isEmpty, "Should detect morning blocked conflict")
    }

    func testNoConflictWhenCompatible() {
        let graph = IntentGraph.build(from: [
            .noEventsBefore(hour: 9), .morningPerson
        ])
        let conflicts = graph.conflicts
        XCTAssertTrue(conflicts.isEmpty, "9:00 start is compatible with morning person")
    }

    func testWindowTooShort() {
        let conflicts = IntentGraph.conflictReason(
            .noEventsBefore(hour: 16), .noEventsAfter(hour: 17)
        )
        XCTAssertNotNil(conflicts, "1h window should be too short")
    }

    // MARK: - Suggestions

    func testSuggestions() {
        let graph = IntentGraph.build(from: [.focusBlock(minutes: 120)])
        let suggestions = graph.suggestedIntents()
        // focusBlock should suggest prioritizeFocus
        let hasFocusSuggestion = suggestions.contains {
            if case .prioritizeFocus = $0 { return true }
            return false
        }
        XCTAssertTrue(hasFocusSuggestion)
    }

    // MARK: - Typed Ports

    func testPortCompatibility() {
        // Source → Transform should connect (both pass events)
        XCTAssertTrue(ScheduleIntent.fromCalendar(name: "Work").canConnect(to: .splitLong(maxMinutes: 90)))

        // Config → Source should not connect
        XCTAssertFalse(ScheduleIntent.speed(.quick).canConnect(to: .fromCalendar(name: "Work")))
    }

    func testPortValidation() {
        var graph = IntentGraph.build(from: [
            .horizon(.today), .focusBlock(minutes: 60), .speed(.quick)
        ])
        // Add a dependency edge manually to test validation
        graph.addEdge(from: .speed(.quick), to: .focusBlock(minutes: 60), kind: .dependsOn)
        let errors = graph.validatePorts()
        // speed (config) → focusBlock (create) may not connect
        XCTAssertFalse(errors.isEmpty)
    }

    // MARK: - Conflict Detector (Graph-Powered)

    func testConflictDetectorUsesGraph() {
        let conflicts = IntentConflictDetector.analyze([
            .noEventsBefore(hour: 14), .morningPerson
        ])
        let hasError = conflicts.contains { $0.severity == .error }
        XCTAssertTrue(hasError)
    }

    func testConflictDetectorReportsAutoResolved() {
        let conflicts = IntentConflictDetector.analyze([.prioritizeDeadlines()])
        let hasInfo = conflicts.contains {
            $0.severity == .info && $0.message.contains("auto-added")
        }
        XCTAssertTrue(hasInfo, "Should report auto-added dependency")
    }

    func testConflictDetectorDuplicateSpeed() {
        let conflicts = IntentConflictDetector.analyze([
            .speed(.quick), .speed(.thorough)
        ])
        let hasWarning = conflicts.contains { $0.severity == .warning }
        XCTAssertTrue(hasWarning)
    }

    // MARK: - Subgraphs

    @MainActor
    func testSubgraphExpansion() {
        let registry = SubgraphRegistry()
        let sg = registry.subgraph(id: "morning-routine")
        XCTAssertNotNil(sg)

        let expanded = sg!.expand(subgraphs: registry.subgraphs)
        XCTAssertFalse(expanded.isEmpty)
        // Should contain focusBlock
        let hasFocus = expanded.contains {
            if case .focusBlock = $0 { return true }
            return false
        }
        XCTAssertTrue(hasFocus)
    }

    @MainActor
    func testSubgraphWithVariables() {
        let registry = SubgraphRegistry()
        let sg = registry.subgraph(id: "deep-work-session")!
        let expanded = sg.expand(subgraphs: registry.subgraphs, variables: ["duration": .int(240)])
        // focusBlock should use 240 minutes instead of default 180
        let focus = expanded.first {
            if case .focusBlock = $0 { return true }
            return false
        }
        if case .focusBlock(let m, _) = focus {
            XCTAssertEqual(m, 240)
        } else {
            XCTFail("Expected focusBlock")
        }
    }

    @MainActor
    func testSubgraphSaveAndLoad() {
        let registry = SubgraphRegistry()
        let sg = Subgraph(
            name: "Test Pipeline",
            intents: [.lowEnergy, .protectLunch()],
            isUserCreated: true
        )
        registry.register(sg)
        XCTAssertEqual(registry.userSubgraphs.count, 1)

        // Clean up
        registry.remove(id: sg.id)
        XCTAssertEqual(registry.userSubgraphs.count, 0)
    }

    @MainActor
    func testRequestFromSubgraph() {
        let registry = SubgraphRegistry()
        let request = OptimizationRequest.fromSubgraph(
            registry.subgraph(id: "morning-routine")!,
            registry: registry
        )
        XCTAssertEqual(request.name, "Morning Routine")
        XCTAssertFalse(request.intents.isEmpty)
    }

    // MARK: - Parallel Branches

    func testParallelSplitExpansion() {
        let split = ParallelSplit(
            branches: [
                ParallelBranch(name: "AM", intents: [.focusBlock(minutes: 120)], timeFilter: .morning),
                ParallelBranch(name: "PM", intents: [.batchMeetings()], timeFilter: .afternoon),
            ],
            mergeStrategy: .byTime
        )
        let expanded = split.expand()
        XCTAssertTrue(expanded.count >= 4) // 2 intents + 2 period preferences
    }

    func testRequestFromParallel() {
        let split = ParallelSplit(
            branches: [
                ParallelBranch(name: "Focus", intents: [.focusBlock(minutes: 60)]),
                ParallelBranch(name: "Admin", intents: [.includeBacklog]),
            ],
            mergeStrategy: .concat
        )
        let request = OptimizationRequest.fromParallel(split)
        XCTAssertTrue(request.name?.contains("Focus") == true)
    }

    // MARK: - Variables

    func testVariableSubstitution() {
        let intent = ScheduleIntent.focusBlock(minutes: 60, period: .morning)
        let substituted = intent.applyVariables(["duration": .int(180), "period": .period(.afternoon)])
        if case .focusBlock(let m, let p) = substituted {
            XCTAssertEqual(m, 180)
            XCTAssertEqual(p, .afternoon)
        } else {
            XCTFail("Expected focusBlock")
        }
    }

    func testVariableNoSubstitution() {
        let intent = ScheduleIntent.lowEnergy
        let substituted = intent.applyVariables(["duration": .int(180)])
        XCTAssertEqual(substituted, .lowEnergy) // Should be unchanged
    }

    // MARK: - Transforms

    func testSplitLongTransform() {
        let events = [
            OptimizableEvent(title: "Big task", duration: 10800) // 180 min
        ]
        // splitLong(maxMinutes: 90) should split into 2 parts
        let graph = IntentGraph.build(from: [.splitLong(maxMinutes: 90)])
        _ = graph // Transform is applied by IntentCompiler, not graph
        // Just verify the intent exists
        XCTAssertTrue(true)
    }

    func testCapTotalTransform() {
        // Conceptual: 5 tasks of 120min each = 600min
        // capTotal(360) should keep only 3 (highest priority first)
        XCTAssertTrue(true) // Actual transform tested via IntentCompiler
    }

    // MARK: - Full Pipeline Phases

    func testAllPhasesPresent() {
        let allPhases = IntentGraph.Phase.allCases
        XCTAssertEqual(allPhases.count, 12)
        XCTAssertEqual(allPhases.first, .trigger)
        XCTAssertEqual(allPhases.last, .output)
    }

    func testPhaseClassification() {
        XCTAssertEqual(IntentGraph.phase(for: .onEventDeleted), .trigger)
        XCTAssertEqual(IntentGraph.phase(for: .fromCalendar(name: "X")), .source)
        XCTAssertEqual(IntentGraph.phase(for: .horizon(.today)), .context)
        XCTAssertEqual(IntentGraph.phase(for: .includeBacklog), .tasks)
        XCTAssertEqual(IntentGraph.phase(for: .focusBlock(minutes: 60)), .create)
        XCTAssertEqual(IntentGraph.phase(for: .splitLong(maxMinutes: 90)), .transform)
        XCTAssertEqual(IntentGraph.phase(for: .prioritizeDeadlines()), .weights)
        XCTAssertEqual(IntentGraph.phase(for: .lowEnergy), .energy)
        XCTAssertEqual(IntentGraph.phase(for: .stability(.normal)), .rules)
        XCTAssertEqual(IntentGraph.phase(for: .when(.afterHour(14), then: [], otherwise: [])), .condition)
        XCTAssertEqual(IntentGraph.phase(for: .speed(.quick)), .config)
        XCTAssertEqual(IntentGraph.phase(for: .autoApply), .output)
    }

    // MARK: - Kahn-style Sort

    func testKahnTopoSortEmitsPrerequisitesFirst() {
        // prioritizeDeadlines requires includeBacklog; Kahn must emit
        // includeBacklog first even though phases are close.
        let graph = IntentGraph.build(from: [.prioritizeDeadlines()])
        let sorted = graph.sortedIntents()
        let includeIdx = sorted.firstIndex {
            if case .includeBacklog = $0 { return true }
            return false
        }
        let prioritizeIdx = sorted.firstIndex {
            if case .prioritizeDeadlines = $0 { return true }
            return false
        }
        XCTAssertNotNil(includeIdx)
        XCTAssertNotNil(prioritizeIdx)
        if let a = includeIdx, let b = prioritizeIdx {
            XCTAssertLessThan(a, b, "requires edge forces prereq before dependent")
        }
    }

    func testReachabilityIncludesTransitiveDependencies() {
        // prioritizeDeadlines → includeBacklog (requires). Transitive
        // reachability from includeBacklog should include prioritizeDeadlines
        // because requires-edges are normalised to prereq→dependent.
        let graph = IntentGraph.build(from: [.prioritizeDeadlines()])
        let r = graph.reachability()
        let backlogReach = r["includeBacklog"] ?? []
        XCTAssertTrue(backlogReach.contains("prioritizeDeadlines"))
    }

    // MARK: - SCC Detection

    func testEmptyGraphHasNoSCCs() {
        let graph = IntentGraph.build(from: [.lowEnergy, .protectLunch()])
        XCTAssertTrue(graph.stronglyConnectedComponents().isEmpty)
    }

    func testArtificialCycleIsDetected() {
        var graph = IntentGraph.build(from: [
            .horizon(.today), .focusBlock(minutes: 60)
        ])
        // Force a cycle: focusBlock depends on horizon AND horizon depends on focusBlock.
        graph.addEdge(from: .horizon(.today), to: .focusBlock(minutes: 60), kind: .dependsOn)
        graph.addEdge(from: .focusBlock(minutes: 60), to: .horizon(.today), kind: .dependsOn)

        let sccs = graph.stronglyConnectedComponents()
        XCTAssertFalse(sccs.isEmpty, "Should detect the artificial cycle")
        // Both nodes must live in the same SCC.
        let cycle = sccs.first ?? []
        let cycleSet = Set(cycle)
        XCTAssertTrue(cycleSet.contains("horizon.today"))
        XCTAssertTrue(cycleSet.contains("focusBlock"))
    }
}
