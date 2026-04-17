import Foundation
import Testing
@testable import Bubo

@Suite("Federated Mutation Bandit")
struct FederatedBanditTests {

    @Test("Per-island bandits are independent before merging")
    func perIslandIndependent() {
        let federated = FederatedMutationBandit(islandCount: 3)
        let a = federated.bandit(forIsland: 0)
        let b = federated.bandit(forIsland: 1)
        #expect(a !== b)
        a.record(op: .shift, reward: 0.3)
        let bPulls = b.snapshot[.shift]?.pulls ?? 0
        #expect(bPulls == 0)
    }

    @Test("Merge averages statistics across islands")
    func mergeBlendsStatistics() {
        let config = FederatedMutationBandit.Configuration(
            mergeInterval: 10,
            mergeWeight: 1.0, // full adoption — post-merge islands should be identical
            explorationAlpha: 1.0,
            regularizationLambda: 1.0
        )
        let federated = FederatedMutationBandit(islandCount: 2, config: config)
        let a = federated.bandit(forIsland: 0)
        let b = federated.bandit(forIsland: 1)

        a.updateContext(BanditContext(diversity: 0.7, stagnation: 0.2, imbalance: 0.1))
        b.updateContext(BanditContext(diversity: 0.3, stagnation: 0.8, imbalance: 0.5))

        for _ in 0..<20 {
            a.record(op: .shift, reward: 0.2)
            b.record(op: .guided, reward: 0.4)
        }

        federated.merge()

        let sa = a.snapshot
        let sb = b.snapshot
        for op in MutationOperator.allCases {
            guard let ta = sa[op]?.theta, let tb = sb[op]?.theta else { continue }
            for (va, vb) in zip(ta, tb) {
                #expect(abs(va - vb) < 1e-6)
            }
        }
    }

    @Test("maybeMerge respects the configured interval")
    func maybeMergeTriggersOnInterval() {
        let config = FederatedMutationBandit.Configuration(
            mergeInterval: 5,
            mergeWeight: 0.5,
            explorationAlpha: 1.0,
            regularizationLambda: 1.0
        )
        let federated = FederatedMutationBandit(islandCount: 3, config: config)
        #expect(federated.maybeMerge(generation: 1) == false)
        #expect(federated.maybeMerge(generation: 5) == true)
        #expect(federated.maybeMerge(generation: 6) == false)
        #expect(federated.maybeMerge(generation: 10) == true)
    }
}
