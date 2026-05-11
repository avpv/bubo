import Foundation

// MARK: - IslandModelGA cross-island diversity measurement
//
// Computes a single `CrossIslandDiversity` snapshot from the per-island
// best-ever individuals — unique-best fraction, fitness range, fitness
// std dev. Fed back into `evolveIslands` (in `IslandModelGA.swift`) to
// drive `adaptiveMigration` interval shortening when islands start to
// converge on the same answer, or lengthening when they diverge.
//
// Extracted from `IslandModelGA.swift`; `measureCrossIslandDiversity`
// dropped its `private` modifier so the Core Evolution Loop in the
// main file can still call it.

extension IslandModelGA {

    // MARK: - Cross-Island Diversity

    /// Measure how different the best solutions across islands are.
    /// Uses Equatable conformance to count unique bests and fitness spread.
    func measureCrossIslandDiversity(_ islands: [Island<C>]) -> CrossIslandDiversity {
        let bests = islands.compactMap(\.bestEver)
        guard bests.count > 1 else {
            return CrossIslandDiversity(uniqueBestFraction: 1.0, fitnessRange: 0, fitnessStdDev: 0)
        }

        // Count unique bests using Equatable
        var uniqueCount = 0
        var seen: [C] = []
        for best in bests {
            if !seen.contains(where: { $0 == best }) {
                seen.append(best)
                uniqueCount += 1
            }
        }
        let uniqueFraction = Double(uniqueCount) / Double(bests.count)

        // Fitness range and std dev across island bests
        let fitnesses = bests.map(\.fitness)
        let minFit = fitnesses.min() ?? 0
        let maxFit = fitnesses.max() ?? 0
        let range = maxFit - minFit

        let avg = fitnesses.reduce(0, +) / Double(fitnesses.count)
        let variance = fitnesses.reduce(0.0) { $0 + pow($1 - avg, 2) } / Double(fitnesses.count - 1)
        let stdDev = sqrt(variance)

        return CrossIslandDiversity(
            uniqueBestFraction: uniqueFraction,
            fitnessRange: range,
            fitnessStdDev: stdDev
        )
    }
}
