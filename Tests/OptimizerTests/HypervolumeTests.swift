import Foundation
import Testing
@testable import Bubo

@Suite("Hypervolume Estimator (HypE-lite)")
struct HypervolumeEstimatorTests {

    @Test("Total hypervolume of a single point equals its volume fraction")
    func totalHypervolumeSinglePoint() {
        let hv = HypervolumeEstimator(objectiveCount: 2, sampleCount: 20_000, seed: 7)
        let single: [[Double]] = [[0.5, 0.5]]
        let volume = hv.totalHypervolume(single)
        // A (0.5, 0.5) point dominates 25% of the unit square. Monte Carlo
        // noise with 20k samples gives ~0.5% std; allow 5% slack.
        #expect(abs(volume - 0.25) < 0.05)
    }

    @Test("Contributions are non-negative and sum at most to the unit hypercube")
    func contributionsAreBounded() {
        let hv = HypervolumeEstimator(objectiveCount: 3, sampleCount: 5_000, seed: 11)
        let pop: [[Double]] = [
            [0.9, 0.1, 0.5],
            [0.1, 0.9, 0.5],
            [0.5, 0.5, 0.9],
            [0.3, 0.3, 0.3]
        ]
        let contribs = hv.contributions(pop)
        #expect(contribs.count == pop.count)
        #expect(contribs.allSatisfy { $0 >= 0 })
        let total = contribs.reduce(0, +)
        #expect(total <= 1.0 + 1e-6)
    }

    @Test("Survivors returns exactly k unique indices")
    func survivorsReturnsKUniqueIndices() {
        let hv = HypervolumeEstimator(objectiveCount: 3, sampleCount: 2_000, seed: 13)
        let ranker = NSGA3.forPopulation(objectiveCount: 3, populationSize: 6)
        let pop: [[Double]] = [
            [0.9, 0.1, 0.1],
            [0.1, 0.9, 0.1],
            [0.1, 0.1, 0.9],
            [0.5, 0.5, 0.1],
            [0.5, 0.1, 0.5],
            [0.2, 0.2, 0.2]
        ]
        let survivors = hv.survivorsWithNSGA3(pop, keeping: 4, using: ranker)
        #expect(survivors.count == 4)
        #expect(Set(survivors).count == 4)
    }

    @Test("Same seed + salt produce identical estimates")
    func deterministicUnderSameSeed() {
        let hv = HypervolumeEstimator(objectiveCount: 3, sampleCount: 2_000, seed: 42)
        let pop: [[Double]] = [[0.9, 0.1, 0.5], [0.5, 0.5, 0.5]]
        let a = hv.contributions(pop, callSalt: 1)
        let b = hv.contributions(pop, callSalt: 1)
        for (x, y) in zip(a, b) { #expect(x == y) }
    }
}
