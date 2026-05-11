import Foundation
import Testing
@testable import Bubo

@Suite("Schedule Feature Vector")
struct ScheduleFeatureVectorTests {

    @Test("Feature vector length matches the declared dimension")
    func featureDimensionIsConstant() {
        let context = OptimizerTestFixtures.makeContext(
            movableEvents: [OptimizerTestFixtures.makeEvent(id: "t1"), OptimizerTestFixtures.makeEvent(id: "t2")]
        )
        let chromo = ScheduleChromosome.random(context: context)
        let vector = ScheduleFeatureVector.extract(chromo, context: context)
        #expect(vector.values.count == ScheduleFeatureVector.dimension)
    }

    @Test("All features are clamped to [0, 1]")
    func featuresInUnitRange() {
        let context = OptimizerTestFixtures.makeContext(
            movableEvents: (0..<10).map { OptimizerTestFixtures.makeEvent(id: "t\($0)") }
        )
        let chromo = ScheduleChromosome.random(context: context)
        let vector = ScheduleFeatureVector.extract(chromo, context: context)
        #expect(vector.values.allSatisfy { $0 >= 0 && $0 <= 1 })
    }

    @Test("Behavior descriptor reuses the first three feature components")
    func behaviorIsSliceOfFeatures() {
        let context = OptimizerTestFixtures.makeContext(
            movableEvents: (0..<5).map { OptimizerTestFixtures.makeEvent(id: "t\($0)") }
        )
        let chromo = ScheduleChromosome.random(context: context)
        let vector = ScheduleFeatureVector.extract(chromo, context: context)
        let descriptor = vector.behavior
        #expect(descriptor.focusMass == vector.values[0])
        #expect(descriptor.morningSkew == vector.values[1])
        #expect(descriptor.daySpread == vector.values[2])
    }
}
