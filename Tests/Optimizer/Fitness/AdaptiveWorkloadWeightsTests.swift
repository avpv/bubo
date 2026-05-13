import Foundation
import Testing
@testable import Bubo
@testable import BuboDomain
@testable import BuboOptimizer

// MARK: - Adaptive Workload Weight Tests
//
// Pin down the boost curve and the multiplier policy used by
// `BuboOptimizer.applyAdaptiveWorkloadWeights`. The mechanism leans
// the schedule toward energy-curve placement on sparse days and
// defers to compactness on packed ones — both ends of that range
// have to stay stable across refactors of the surrounding pipeline.

@Suite("Adaptive workload weights")
struct AdaptiveWorkloadWeightsTests {

    @Test("near-empty day yields full boost")
    func fullBoostAtFloor() {
        let boost = BuboOptimizer.adaptiveWorkloadBoost(
            difficulty: BuboOptimizer.workloadDifficultyFloor
        )
        #expect(boost == 1.0)
    }

    @Test("trivial-threshold yields zero boost (no-op)")
    func zeroAtThreshold() {
        let boost = BuboOptimizer.adaptiveWorkloadBoost(
            difficulty: BuboOptimizer.trivialWorkloadDifficulty
        )
        #expect(boost == 0)
    }

    @Test("packed day stays unboosted")
    func zeroAboveThreshold() {
        #expect(BuboOptimizer.adaptiveWorkloadBoost(difficulty: 0.5) == 0)
        #expect(BuboOptimizer.adaptiveWorkloadBoost(difficulty: 0.95) == 0)
    }

    @Test("boost interpolates linearly between floor and threshold")
    func linearInterpolation() {
        let floor = BuboOptimizer.workloadDifficultyFloor
        let trivial = BuboOptimizer.trivialWorkloadDifficulty
        let mid = (floor + trivial) / 2
        let midBoost = BuboOptimizer.adaptiveWorkloadBoost(difficulty: mid)
        #expect(abs(midBoost - 0.5) < 0.01)
    }

    @Test("difficulty=0.10 gives boost=0.75 (the logged scenario)")
    func realScenarioBoost() {
        // Matches the rid=026e89be log line:
        // workload_downshift difficulty=0.095163 — round to 0.10 for
        // a deterministic check that future tweaks don't silently
        // drift the boost in this real-world band.
        let boost = BuboOptimizer.adaptiveWorkloadBoost(difficulty: 0.10)
        #expect(abs(boost - 0.75) < 0.01)
    }

    @Test("full boost: energy×2, placement×1.5, compactness×0.3")
    func fullBoostMultipliers() {
        var prefs = OptimizerPreferences()
        let originalEnergy = prefs.energyCurveWeight
        let originalPlacement = prefs.taskPlacementWeight
        let originalCompactness = prefs.dayCompactnessWeight
            ?? OptimizerPreferences.defaultDayCompactnessWeight

        let boost = BuboOptimizer.applyAdaptiveWorkloadWeights(
            prefs: &prefs,
            difficulty: BuboOptimizer.workloadDifficultyFloor
        )
        #expect(boost == 1.0)
        #expect(abs(prefs.energyCurveWeight - originalEnergy * 2.0) < 1e-9)
        #expect(abs(prefs.taskPlacementWeight - originalPlacement * 1.5) < 1e-9)
        let newCompact = prefs.dayCompactnessWeight ?? 0
        #expect(abs(newCompact - originalCompactness * 0.3) < 1e-9)
    }

    @Test("at threshold: prefs untouched (no allocation, no log)")
    func noOpAtThreshold() {
        var prefs = OptimizerPreferences()
        let snapshot = prefs
        let boost = BuboOptimizer.applyAdaptiveWorkloadWeights(
            prefs: &prefs,
            difficulty: BuboOptimizer.trivialWorkloadDifficulty
        )
        #expect(boost == 0)
        #expect(prefs.energyCurveWeight == snapshot.energyCurveWeight)
        #expect(prefs.taskPlacementWeight == snapshot.taskPlacementWeight)
        #expect(prefs.dayCompactnessWeight == snapshot.dayCompactnessWeight)
    }

    @Test("custom user weights scale proportionally, not absolutely")
    func relativeScaling() {
        // A user who already cranked energyCurveWeight to 1.5 in
        // Settings should see *their* baseline boosted, not the
        // package default.
        var prefs = OptimizerPreferences(
            energyCurveWeight: 1.5,
            dayCompactnessWeight: 0.8
        )
        BuboOptimizer.applyAdaptiveWorkloadWeights(
            prefs: &prefs,
            difficulty: BuboOptimizer.workloadDifficultyFloor
        )
        #expect(abs(prefs.energyCurveWeight - 3.0) < 1e-9)        // 1.5 × 2.0
        let newCompact = prefs.dayCompactnessWeight ?? 0
        #expect(abs(newCompact - 0.8 * 0.3) < 1e-9)
    }

    @Test("nil compactness weight falls back to default before scaling")
    func nilCompactnessUsesDefault() {
        var prefs = OptimizerPreferences()
        // Sanity: default ctor leaves compactness as nil so the
        // fallback path is what production usually hits.
        #expect(prefs.dayCompactnessWeight == nil)

        BuboOptimizer.applyAdaptiveWorkloadWeights(
            prefs: &prefs,
            difficulty: BuboOptimizer.workloadDifficultyFloor
        )
        let scaled = prefs.dayCompactnessWeight ?? 0
        #expect(abs(scaled - OptimizerPreferences.defaultDayCompactnessWeight * 0.3) < 1e-9)
    }
}
