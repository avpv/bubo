import Foundation
import Testing
@testable import Bubo

@Suite("Reachability Bitset")
struct ReachabilityBitsetTests {

    // MARK: - Construction

    @Test("Empty id list returns nil")
    func emptyIdsReturnNil() {
        #expect(ReachabilityBitset.build(ids: [], edges: [:]) == nil)
    }

    @Test("Single id with no edges has zero reachables")
    func singletonHasZeroReachables() {
        let bitset = ReachabilityBitset.build(ids: ["a"], edges: [:])
        #expect(bitset != nil)
        #expect(bitset?.reachableCount(from: "a") == 0)
        #expect(bitset?.contains(from: "a", to: "a") == false)
    }

    // MARK: - Queries

    @Test("contains matches the input edge map")
    func containsMatchesInput() {
        let edges: [String: Set<String>] = [
            "a": ["b", "c"],
            "b": ["c"]
        ]
        let bitset = ReachabilityBitset.build(ids: ["a", "b", "c"], edges: edges)!
        #expect(bitset.contains(from: "a", to: "b"))
        #expect(bitset.contains(from: "a", to: "c"))
        #expect(bitset.contains(from: "b", to: "c"))
        // Missing edges return false.
        #expect(bitset.contains(from: "b", to: "a") == false)
        #expect(bitset.contains(from: "c", to: "a") == false)
    }

    @Test("Unknown ids return false instead of trapping")
    func unknownIdsReturnFalse() {
        let bitset = ReachabilityBitset.build(ids: ["a"], edges: [:])!
        #expect(bitset.contains(from: "ghost", to: "a") == false)
        #expect(bitset.contains(from: "a", to: "ghost") == false)
    }

    @Test("reachableCount equals neighbour set size")
    func reachableCountMatchesSet() {
        let edges: [String: Set<String>] = ["a": ["b", "c", "d"]]
        let bitset = ReachabilityBitset.build(
            ids: ["a", "b", "c", "d"],
            edges: edges
        )!
        #expect(bitset.reachableCount(from: "a") == 3)
        #expect(bitset.reachableCount(from: "b") == 0)
    }

    @Test("forEachReachable visits exactly the recorded targets")
    func forEachReachableEnumerates() {
        let edges: [String: Set<String>] = ["a": ["b", "d"]]
        let bitset = ReachabilityBitset.build(
            ids: ["a", "b", "c", "d"],
            edges: edges
        )!
        var seen: Set<String> = []
        bitset.forEachReachable(from: "a") { seen.insert($0) }
        #expect(seen == ["b", "d"])
    }

    // MARK: - Layout

    @Test("Words-per-row covers count rounded up to nearest 64")
    func wordsPerRowMatchesLayout() {
        let smallIds = (0..<10).map { "n\($0)" }
        let smallBitset = ReachabilityBitset.build(ids: smallIds, edges: [:])!
        #expect(smallBitset.wordsPerRow == 1)

        let largeIds = (0..<70).map { "n\($0)" }
        let largeBitset = ReachabilityBitset.build(ids: largeIds, edges: [:])!
        #expect(largeBitset.wordsPerRow == 2)
    }
}
