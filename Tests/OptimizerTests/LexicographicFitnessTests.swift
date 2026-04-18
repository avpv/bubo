import Foundation
import Testing
@testable import Bubo

// MARK: - Lex Fitness Tests (Wave 1 / п.7)

@Suite("Lexicographic fitness comparator")
struct LexicographicFitnessTests {

    @Test("hard-tier dominance trumps soft-tier gains")
    func hardTierDominates() {
        let comparator = LexicographicComparator()
        let weakHardStrongSoft = LexFitness(hardTier: 0.5, softTier: 0.95)
        let strongHardWeakSoft = LexFitness(hardTier: 0.9, softTier: 0.2)
        #expect(comparator.isBetter(strongHardWeakSoft, than: weakHardStrongSoft))
        #expect(!comparator.isBetter(weakHardStrongSoft, than: strongHardWeakSoft))
    }

    @Test("soft tier decides when hard tier ties within epsilon")
    func softTieBreak() {
        let comparator = LexicographicComparator(epsilon: 1e-3)
        let a = LexFitness(hardTier: 0.80, softTier: 0.5)
        let b = LexFitness(hardTier: 0.8005, softTier: 0.9)
        // hardTier differs by 5e-4 < epsilon → treated equal, soft wins
        #expect(comparator.isBetter(b, than: a))
    }

    @Test("extractor splits objective cache into hard/soft tiers")
    func extractorSplitsCache() {
        let weights: [String: Double] = [
            "Precedence": 1.0,
            "Conflict": 10.0,
            "FocusBlock": 1.0,
            "Deadline": 3.0,
        ]
        let extractor = LexicographicExtractor(weights: weights)
        let cache: [String: Double] = [
            "Precedence": 0.5,
            "Conflict": 1.0,
            "FocusBlock": 0.8,
            "Deadline": 0.9,
        ]
        let lex = extractor.extract(fromCache: cache)
        // hardTier: (0.5 * 1 + 1.0 * 10) / 11 ≈ 0.9545
        // softTier: (0.8 * 1 + 0.9 * 3) / 4 = 0.875
        #expect(abs(lex.hardTier - 0.9545) < 1e-3)
        #expect(abs(lex.softTier - 0.875) < 1e-3)
    }

    @Test("empty tier returns 1.0 (neutral)")
    func emptyTierNeutral() {
        let extractor = LexicographicExtractor(weights: ["FocusBlock": 1.0])
        let cache: [String: Double] = ["FocusBlock": 0.5]
        let lex = extractor.extract(fromCache: cache)
        // No hard-tier objectives wired → hardTier = 1.0
        #expect(lex.hardTier == 1.0)
        #expect(abs(lex.softTier - 0.5) < 1e-9)
    }

    @Test("bestByLex picks hard-tier winner even with lower scalar")
    func bestByLexPicksHardWinner() {
        let ext = LexicographicExtractor(weights: [
            "Conflict": 10.0, "FocusBlock": 1.0,
        ])
        var a = ScheduleChromosome(genes: [])
        a.rawFitness = 0.95
        a.fitness = 0.95
        a.objectiveCache = ["Conflict": 0.4, "FocusBlock": 1.0]

        var b = ScheduleChromosome(genes: [])
        b.rawFitness = 0.60
        b.fitness = 0.60
        b.objectiveCache = ["Conflict": 1.0, "FocusBlock": 0.1]

        let pop = [a, b]
        let best = pop.bestByLex(using: ext)
        // b wins on hard tier despite lower scalar fitness.
        #expect(best?.rawFitness == 0.60)
    }
}
