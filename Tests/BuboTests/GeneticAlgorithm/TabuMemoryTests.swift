import Foundation
import Testing
@testable import Bubo
@testable import BuboDomain
@testable import BuboOptimizer

// MARK: - Tabu Memory Tests (Wave 1 / item 14)

@Suite("Tabu memory behaviour")
struct TabuMemoryTests {

    @Test("recently moved event is tabu within tenure")
    func tabuWithinTenure() {
        let mem = TabuMemory(config: .init(
            tenure: 3,
            frequencyCapacity: 16,
            tabuPenalty: 0.1,
            frequencyWeight: 0.3
        ))
        mem.step()
        mem.markMoves(eventIds: ["E1"])
        #expect(mem.isTabu(eventId: "E1"))
        mem.step()
        mem.step()
        #expect(mem.isTabu(eventId: "E1"))
        mem.step()
        mem.step()
        #expect(!mem.isTabu(eventId: "E1"))
    }

    @Test("frequency counter grows across moves")
    func frequencyGrows() {
        let mem = TabuMemory()
        for _ in 0..<5 {
            mem.step()
            mem.markMoves(eventIds: ["E1"])
        }
        #expect(mem.longTermFrequency(eventId: "E1") == 5)
    }

    @Test("score reflects tabu penalty")
    func scoreReflectsTabu() {
        let mem = TabuMemory(config: .init(
            tenure: 10,
            frequencyCapacity: 16,
            tabuPenalty: 0.2,
            frequencyWeight: 0
        ))
        mem.step()
        mem.markMoves(eventIds: ["E1"])
        let s = mem.score(eventId: "E1")
        #expect(abs(s - 0.2) < 1e-9)
        let untouched = mem.score(eventId: "E99")
        #expect(abs(untouched - 1.0) < 1e-9)
    }

    @Test("aspiration lets through moves beating the best")
    func aspiration() {
        let mem = TabuMemory()
        mem.noteBest(hardTier: 0.9, softTier: 0.5)
        #expect(mem.aspires(hardTier: 0.91, softTier: 0))
        #expect(!mem.aspires(hardTier: 0.9, softTier: 0.4))
        #expect(mem.aspires(hardTier: 0.9, softTier: 0.6))
    }

    @Test("frequency-based diversification downweights over-touched events")
    func diversification() {
        let mem = TabuMemory(config: .init(
            tenure: 1,
            frequencyCapacity: 16,
            tabuPenalty: 1.0,         // no short-term effect
            frequencyWeight: 0.5
        ))
        for _ in 0..<10 {
            mem.step()
            mem.markMoves(eventIds: ["hot"])
        }
        mem.markMoves(eventIds: ["cold"])
        // Advance step so short-term tabu expires.
        mem.step(); mem.step(); mem.step()
        let hotScore = mem.score(eventId: "hot")
        let coldScore = mem.score(eventId: "cold")
        #expect(coldScore > hotScore)
    }
}
