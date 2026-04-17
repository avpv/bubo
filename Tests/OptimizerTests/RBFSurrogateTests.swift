import Foundation
import Testing
@testable import Bubo

@Suite("RBF Surrogate Screening")
struct RBFSurrogateTests {

    private func makeFeatures(_ value: Double) -> ContiguousArray<Double> {
        ContiguousArray(repeating: value, count: ScheduleFeatureVector.dimension)
    }

    @Test("Warm-up phase forces real evaluation")
    func warmupScreens() {
        let surrogate = RBFSurrogate(config: .default)
        switch surrogate.screen(features: makeFeatures(0.5)) {
        case .realEvaluate:
            #expect(true)
        case .accept:
            Issue.record("Surrogate should not accept during warm-up")
        }
    }

    @Test("After warm-up, nearby queries accept the surrogate prediction")
    func postWarmupAcceptsNearby() {
        let config = RBFSurrogate.Configuration(
            capacity: 100,
            bandwidth: 0.3,
            neighbors: 5,
            realEvalThreshold: 0.5,
            trustRefreshInterval: 100,
            warmupSamples: 10
        )
        let surrogate = RBFSurrogate(config: config)
        let baseline = makeFeatures(0.5)
        for _ in 0..<15 { surrogate.record(features: baseline, fitness: 0.8) }

        var near = baseline
        near[0] += 0.01
        switch surrogate.screen(features: near) {
        case .accept(let predicted):
            #expect(abs(predicted - 0.8) < 0.1)
        case .realEvaluate:
            Issue.record("Expected surrogate to accept a near-duplicate query")
        }
    }

    @Test("Far queries trigger real evaluation")
    func farQueriesRealEvaluate() {
        let config = RBFSurrogate.Configuration(
            capacity: 100,
            bandwidth: 0.3,
            neighbors: 5,
            realEvalThreshold: 0.2,
            trustRefreshInterval: 100,
            warmupSamples: 10
        )
        let surrogate = RBFSurrogate(config: config)
        let baseline = makeFeatures(0.0)
        for _ in 0..<15 { surrogate.record(features: baseline, fitness: 0.8) }

        switch surrogate.screen(features: makeFeatures(1.0)) {
        case .realEvaluate:
            #expect(true)
        case .accept:
            Issue.record("Expected real-evaluate on a far-away query")
        }
    }
}
