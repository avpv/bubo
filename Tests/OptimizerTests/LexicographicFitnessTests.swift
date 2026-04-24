import Foundation
import Testing
@testable import Bubo

// MARK: - Lex Fitness Tests (Wave 1 / п.7)
//
// Three-tier lexicographic ordering: hard (Precedence, Conflict) →
// mid (Deadline, BacklogOrder) → soft (everything else). These
// tests pin down the intended dominance chain.

@Suite("Lexicographic fitness comparator")
struct LexicographicFitnessTests {

    @Test("hard-tier dominance trumps mid- and soft-tier gains")
    func hardTierDominates() {
        let comparator = LexicographicComparator()
        let weakHardStrongOthers = LexFitness(hardTier: 0.5, midTier: 0.95, softTier: 0.95)
        let strongHardWeakOthers = LexFitness(hardTier: 0.9, midTier: 0.2, softTier: 0.2)
        #expect(comparator.isBetter(strongHardWeakOthers, than: weakHardStrongOthers))
        #expect(!comparator.isBetter(weakHardStrongOthers, than: strongHardWeakOthers))
    }

    @Test("mid-tier dominance trumps soft-tier gains when hard ties")
    func midTierDominatesSoftWhenHardTied() {
        let comparator = LexicographicComparator()
        let weakMidStrongSoft = LexFitness(hardTier: 1.0, midTier: 0.4, softTier: 0.95)
        let strongMidWeakSoft = LexFitness(hardTier: 1.0, midTier: 0.9, softTier: 0.3)
        // Mid wins. This is the scenario the two-tier version failed:
        // a GA would rank `weakMidStrongSoft` (good soft, bad backlog
        // order) above `strongMidWeakSoft` because it only had
        // hard-vs-soft to compare.
        #expect(comparator.isBetter(strongMidWeakSoft, than: weakMidStrongSoft))
    }

    @Test("soft tier decides when hard and mid tie within epsilon")
    func softTieBreak() {
        let comparator = LexicographicComparator(epsilon: 1e-3)
        let a = LexFitness(hardTier: 0.80,   midTier: 0.70,   softTier: 0.5)
        let b = LexFitness(hardTier: 0.8005, midTier: 0.7002, softTier: 0.9)
        // hardTier differs by 5e-4 < epsilon, midTier differs by
        // 2e-4 < epsilon → both treated equal, soft wins.
        #expect(comparator.isBetter(b, than: a))
    }

    @Test("extractor splits objective cache into hard/mid/soft tiers")
    func extractorSplitsCache() {
        let weights: [String: Double] = [
            "Precedence": 1.0,
            "Conflict": 10.0,
            "Deadline": 3.0,
            "BacklogOrder": 1.5,
            "FocusBlock": 1.0,
        ]
        let extractor = LexicographicExtractor(weights: weights)
        let cache: [String: Double] = [
            "Precedence": 0.5,
            "Conflict": 1.0,
            "Deadline": 0.9,
            "BacklogOrder": 0.6,
            "FocusBlock": 0.8,
        ]
        let lex = extractor.extract(fromCache: cache)
        // hard: (0.5*1 + 1.0*10) / 11          ≈ 0.9545
        // mid : (0.9*3 + 0.6*1.5) / 4.5        = 0.8
        // soft: (0.8*1) / 1                     = 0.8
        #expect(abs(lex.hardTier - 0.9545) < 1e-3)
        #expect(abs(lex.midTier - 0.8) < 1e-3)
        #expect(abs(lex.softTier - 0.8) < 1e-3)
    }

    @Test("empty tier returns 1.0 (neutral)")
    func emptyTierNeutral() {
        let extractor = LexicographicExtractor(weights: ["FocusBlock": 1.0])
        let cache: [String: Double] = ["FocusBlock": 0.5]
        let lex = extractor.extract(fromCache: cache)
        // No hard / mid objectives wired → both tiers = 1.0 neutral.
        #expect(lex.hardTier == 1.0)
        #expect(lex.midTier == 1.0)
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

    @Test("bestByLex picks mid-tier winner when hard tiers match")
    func bestByLexPicksMidWinner() {
        let ext = LexicographicExtractor(weights: [
            "Conflict": 10.0, "BacklogOrder": 1.5, "FocusBlock": 1.0,
        ])
        var strongSoftWeakBacklog = ScheduleChromosome(genes: [])
        strongSoftWeakBacklog.rawFitness = 0.92
        strongSoftWeakBacklog.fitness = 0.92
        strongSoftWeakBacklog.objectiveCache = [
            "Conflict": 1.0, "BacklogOrder": 0.3, "FocusBlock": 1.0,
        ]

        var weakSoftStrongBacklog = ScheduleChromosome(genes: [])
        weakSoftStrongBacklog.rawFitness = 0.55
        weakSoftStrongBacklog.fitness = 0.55
        weakSoftStrongBacklog.objectiveCache = [
            "Conflict": 1.0, "BacklogOrder": 1.0, "FocusBlock": 0.2,
        ]

        let best = [strongSoftWeakBacklog, weakSoftStrongBacklog].bestByLex(using: ext)
        // Hard tier (Conflict) ties at 1.0. Mid tier (BacklogOrder)
        // picks `weakSoftStrongBacklog` even though its scalar
        // fitness is lower. This is the exact trade-off the new
        // mid-tier fixes.
        #expect(best?.rawFitness == 0.55)
    }
}
