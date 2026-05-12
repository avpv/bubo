import Foundation
import Testing
@testable import Bubo
@testable import BuboDomain
@testable import BuboOptimizer

// MARK: - Symmetry Breaker Tests (Wave 1 / item 16)

@Suite("Symmetry breaker canonicalization")
struct SymmetryBreakerTests {

    private static func gene(
        _ id: String,
        at hour: Int,
        priority: Double = 0.5,
        included: Bool = true
    ) -> ScheduleGene {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let start = cal.date(bySettingHour: hour, minute: 0, second: 0, of: today)!
        return ScheduleGene(
            eventId: id,
            title: id,
            startTime: start,
            duration: 3600,
            context: nil,
            energyCost: 0.5,
            priority: priority,
            isFocusBlock: false,
            isIncluded: included
        )
    }

    @Test("canonicalize produces same order for two equivalent inputs")
    func deterministicOrder() {
        let g1 = Self.gene("A", at: 10, priority: 0.7)
        let g2 = Self.gene("B", at: 10, priority: 0.7)
        let g3 = Self.gene("C", at: 14, priority: 0.4)

        var c1 = ScheduleChromosome(genes: [g1, g2, g3])
        var c2 = ScheduleChromosome(genes: [g3, g2, g1])
        SymmetryBreaker.canonicalize(&c1)
        SymmetryBreaker.canonicalize(&c2)
        #expect(c1.genes.map(\.eventId) == c2.genes.map(\.eventId))
    }

    @Test("canonicalize is idempotent")
    func idempotent() {
        let genes = [
            Self.gene("B", at: 10),
            Self.gene("A", at: 10),
            Self.gene("C", at: 12),
        ]
        var c = ScheduleChromosome(genes: genes)
        SymmetryBreaker.canonicalize(&c)
        let first = c.genes.map(\.eventId)
        let changedSecond = SymmetryBreaker.canonicalize(&c)
        #expect(!changedSecond)
        #expect(c.genes.map(\.eventId) == first)
    }

    @Test("higher priority genes come before lower at same slot")
    func priorityOrder() {
        let lo = Self.gene("lo", at: 10, priority: 0.2)
        let hi = Self.gene("hi", at: 10, priority: 0.9)
        var c = ScheduleChromosome(genes: [lo, hi])
        SymmetryBreaker.canonicalize(&c)
        #expect(c.genes.first?.eventId == "hi")
    }

    @Test("included genes come before excluded at same slot")
    func includedFirst() {
        let drop = Self.gene("drop", at: 9, included: false)
        let keep = Self.gene("keep", at: 9, included: true)
        var c = ScheduleChromosome(genes: [drop, keep])
        SymmetryBreaker.canonicalize(&c)
        #expect(c.genes.first?.eventId == "keep")
    }

    @Test("equivalence classifier buckets same-slot genes together")
    func classifierBuckets() {
        let a = Self.gene("A", at: 10, priority: 0.5)
        let b = Self.gene("B", at: 10, priority: 0.5)
        let c = Self.gene("C", at: 14, priority: 0.5)
        let chromosome = ScheduleChromosome(genes: [a, b, c])
        let classes = GeneEquivalenceClassifier.classes(in: chromosome)
        #expect(classes.count == 1)
        #expect(Set(classes[0]) == Set([0, 1]))
    }
}
