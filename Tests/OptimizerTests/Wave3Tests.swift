import Foundation
import Testing
@testable import Bubo

// MARK: - Wave 3 Tests
// Covers CPSATRepairer, LearnedBranchingBandit, MigrationTopologyBandit.

@Suite("CP-SAT repair")
struct CPSATRepairTests {
    @Test("empty problem returns empty assignment")
    func emptyProblem() {
        let repairer = CPSATRepairer()
        let result = repairer.solve(
            variables: [],
            precedence: [],
            fixedBlocks: [],
            scoreAssignment: { _ in 0 }
        )
        #expect(result.assignments.isEmpty)
        #expect(result.nodesExplored == 0)
    }

    @Test("two-variable problem without conflicts picks best")
    func twoVariables() {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let slot1 = cal.date(bySettingHour: 10, minute: 0, second: 0, of: today)!
        let slot2 = cal.date(bySettingHour: 14, minute: 0, second: 0, of: today)!
        let v1 = CPVariable(geneIndex: 0, domain: [slot1, slot2], duration: 3600)
        let v2 = CPVariable(geneIndex: 1, domain: [slot1, slot2], duration: 3600)

        let repairer = CPSATRepairer()
        let result = repairer.solve(
            variables: [v1, v2],
            precedence: [],
            fixedBlocks: [],
            // Score: prefer variable 0 at slot1.
            scoreAssignment: { assignment in
                var s = 0.0
                if assignment[0] == slot1 { s += 1 }
                if assignment[1] == slot2 { s += 1 }
                return s
            }
        )
        #expect(result.assignments[0] == slot1)
        #expect(result.assignments[1] == slot2)
    }

    @Test("precedence forces ordered placement")
    func precedenceEnforced() {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let slot1 = cal.date(bySettingHour: 10, minute: 0, second: 0, of: today)!
        let slot2 = cal.date(bySettingHour: 14, minute: 0, second: 0, of: today)!
        let v1 = CPVariable(geneIndex: 0, domain: [slot1, slot2], duration: 3600)
        let v2 = CPVariable(geneIndex: 1, domain: [slot1, slot2], duration: 3600)

        let repairer = CPSATRepairer()
        let result = repairer.solve(
            variables: [v1, v2],
            precedence: [(0, 1)],
            fixedBlocks: [],
            scoreAssignment: { _ in 1 }
        )
        if let s1 = result.assignments[0], let s2 = result.assignments[1] {
            #expect(s1.addingTimeInterval(3600) <= s2)
        }
    }
}

@Suite("Learned branching bandit")
struct LearnedBranchingBanditTests {
    @Test("warmup cycles through every arm")
    func warmupRoundRobin() {
        let bandit = LearnedBranchingBandit(
            config: .init(
                explorationC: sqrt(2),
                warmupSamplesPerArm: 1,
                rewardSmoothing: 0.25
            )
        )
        let feats = BranchingDecisionFeatures(
            averageDomainRatio: 0.5,
            activeConstraintFraction: 0.5,
            stagnation: 0.0,
            searchDepth: 0.0
        )
        var selections = Set<BranchingPolicy>()
        for _ in 0..<BranchingPolicy.allCases.count {
            let p = bandit.select(features: feats)
            selections.insert(p)
            bandit.observe(policy: p, features: feats, reward: 0.1)
        }
        // Every arm should have been seen during warmup.
        #expect(selections.count == BranchingPolicy.allCases.count)
    }

    @Test("high-reward arm dominates post-warmup")
    func winningArmDominates() {
        let bandit = LearnedBranchingBandit()
        let feats = BranchingDecisionFeatures(
            averageDomainRatio: 0.5,
            activeConstraintFraction: 0.5,
            stagnation: 0,
            searchDepth: 0
        )
        // Train: domOverDeg always returns reward 1, others 0.
        for _ in 0..<60 {
            for policy in BranchingPolicy.allCases {
                let reward = policy == .domOverDeg ? 1.0 : 0.0
                bandit.observe(policy: policy, features: feats, reward: reward)
            }
        }
        // After training, selection should lean toward domOverDeg.
        var tally = [BranchingPolicy: Int]()
        for _ in 0..<50 {
            tally[bandit.select(features: feats), default: 0] += 1
        }
        let winner = tally.max(by: { $0.value < $1.value })?.key
        #expect(winner == .domOverDeg)
    }
}

@Suite("Migration topology bandit")
struct MigrationTopologyBanditTests {
    @Test("warmup returns every pair at least once")
    func warmupCovers() {
        let bandit = MigrationTopologyBandit(islandCount: 3, config: .init(
            explorationC: sqrt(2), warmupSelectionsPerPair: 1,
            rewardBlend: 0.3, stalePairAgeGenerations: 50
        ))
        let total = 3 * 2 // N·(N-1) directed pairs
        var seen = Set<MigrationPair>()
        for _ in 0..<total {
            let p = bandit.selectOne()
            seen.insert(p)
            bandit.observe(pair: p, reward: 0.1)
        }
        #expect(seen.count == total)
    }

    @Test("positive reward lifts pair in later selection")
    func rewardInfluencesSelection() {
        let bandit = MigrationTopologyBandit(islandCount: 3)
        let winner = MigrationPair(donor: 0, receiver: 1)
        // Saturate warmup.
        for _ in 0..<3 {
            for d in 0..<3 {
                for r in 0..<3 where r != d {
                    bandit.observe(
                        pair: MigrationPair(donor: d, receiver: r),
                        reward: MigrationPair(donor: d, receiver: r) == winner ? 1.0 : 0.0
                    )
                }
            }
        }
        var tally = [MigrationPair: Int]()
        for _ in 0..<50 {
            let p = bandit.selectOne()
            tally[p, default: 0] += 1
            bandit.observe(pair: p, reward: p == winner ? 1.0 : 0.0)
        }
        let max = tally.max(by: { $0.value < $1.value })?.key
        #expect(max == winner)
    }

    @Test("requires at least 2 islands")
    func precondition2Islands() {
        let bandit = MigrationTopologyBandit(islandCount: 2)
        let pair = bandit.selectOne()
        #expect(pair.donor != pair.receiver)
    }
}
