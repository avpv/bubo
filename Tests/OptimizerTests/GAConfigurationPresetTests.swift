import Foundation
import Testing
@testable import Bubo

@Suite("GAConfiguration Preset Crossover Strategies")
struct GAConfigurationPresetTests {

    @Test("Default preset uses contextual crossover")
    func defaultPresetConfigured() {
        let c = GAConfiguration.default
        if case .contextual = c.crossoverStrategy { #expect(true) }
        else { Issue.record("Expected .contextual crossover strategy on .default") }
    }

    @Test("Thorough preset uses contextual crossover")
    func thoroughPresetConfigured() {
        let c = GAConfiguration.thorough
        if case .contextual = c.crossoverStrategy { #expect(true) }
        else { Issue.record("Expected .contextual crossover strategy on .thorough") }
    }

    @Test("Polish preset uses contextual crossover")
    func polishPresetConfigured() {
        let c = GAConfiguration.polish
        if case .contextual = c.crossoverStrategy { #expect(true) }
        else { Issue.record("Expected .contextual crossover strategy on .polish") }
    }

    @Test("Refine preset uses contextual crossover")
    func refinePresetConfigured() {
        let c = GAConfiguration.refine
        if case .contextual = c.crossoverStrategy { #expect(true) }
        else { Issue.record("Expected .contextual crossover strategy on .refine") }
    }

    @Test("Instant preset keeps single-point crossover for preview latency")
    func instantPresetStaysFast() {
        let c = GAConfiguration.instant
        if case .singlePoint = c.crossoverStrategy { #expect(true) }
        else { Issue.record("Expected .singlePoint crossover on .instant") }
    }
}
