import Foundation
import Testing
@testable import Bubo
@testable import BuboDomain
@testable import BuboOptimizer

@Suite("RBF Surrogate Screening")
struct RBFSurrogateTests {

    private func makeFeatures(_ value: Double) -> ContiguousArray<Double> {
        ContiguousArray(repeating: value, count: ScheduleFeatureVector.dimension)
    }

    @Test("Warm-up phase forces real evaluation")
    func warmupScreens() {
        let surrogate = RBFSurrogate(config: .default)
        switch surrogate.screen(features: makeFeatures(0.5)) {
        case .realEvaluate(_, _):
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
        case .accept(let predicted, _):
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

    @Test("Accepted queries carry a predicted objective vector when training had one")
    func acceptReturnsObjectiveVector() {
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
        let objectiveVec = ContiguousArray<Double>(repeating: 0.7, count: 13)
        for _ in 0..<15 {
            surrogate.record(features: baseline, fitness: 0.8, objectives: objectiveVec)
        }
        switch surrogate.screen(features: baseline) {
        case .accept(_, let predictedObjectives):
            #expect(predictedObjectives != nil)
            #expect(predictedObjectives?.count == 13)
            if let vec = predictedObjectives {
                for v in vec { #expect(abs(v - 0.7) < 0.1) }
            }
        case .realEvaluate:
            Issue.record("Expected accept on a baseline-duplicate query")
        }
    }

    @Test("realEvaluate carries prior prediction once warm-up passes")
    func realEvaluateExposesPriorPrediction() {
        let config = RBFSurrogate.Configuration(
            capacity: 100,
            bandwidth: 0.3,
            neighbors: 5,
            realEvalThreshold: 0.05,    // tight threshold forces uncertainty
            trustRefreshInterval: 1000,
            warmupSamples: 5
        )
        let surrogate = RBFSurrogate(config: config)
        let baseline = makeFeatures(0.0)
        for _ in 0..<10 { surrogate.record(features: baseline, fitness: 0.5) }

        // Ask about a point far enough to trip the threshold.
        switch surrogate.screen(features: makeFeatures(0.4)) {
        case .realEvaluate(_, let priorPrediction):
            #expect(priorPrediction != nil)
        case .accept:
            Issue.record("Expected high-uncertainty realEvaluate")
        }
    }
}
