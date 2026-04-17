import Foundation
import Testing
@testable import Bubo

@Suite("TaskSignature")
struct TaskSignatureTests {

    private func makeContext(
        eventCount: Int,
        priorityScale: Double = 1.0,
        weightOverride: ((inout OptimizerPreferences) -> Void)? = nil
    ) -> OptimizerContext {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        var prefs = OptimizerPreferences()
        weightOverride?(&prefs)
        let events = (0..<eventCount).map { i in
            OptimizableEvent(
                id: "e-\(eventCount)-\(i)",
                title: "e\(i)",
                duration: TimeInterval((30 + i * 5) * 60),
                priority: Double(i) * priorityScale / Double(max(1, eventCount))
            )
        }
        return OptimizerContext(
            movableEvents: events,
            workingHours: 9...18,
            planningHorizon: DateInterval(start: today, duration: 86400),
            preferences: prefs
        )
    }

    @Test("Same workload → same signature")
    func sameWorkloadProducesSameSignature() {
        let a = makeContext(eventCount: 5)
        let b = makeContext(eventCount: 5)
        #expect(TaskSignature(context: a) == TaskSignature(context: b))
    }

    @Test("Different event counts → different signatures")
    func differentEventCountChangesSignature() {
        let a = makeContext(eventCount: 5)
        let b = makeContext(eventCount: 10)
        #expect(TaskSignature(context: a) != TaskSignature(context: b))
    }

    @Test("Different preference weights → different signatures")
    func differentPrefsChangeSignature() {
        let a = makeContext(eventCount: 5)
        let b = makeContext(eventCount: 5) { p in
            p.deadlineWeight = 99.0  // wildly different
        }
        #expect(TaskSignature(context: a) != TaskSignature(context: b))
    }

    @Test("Sub-decimal preference jitter does NOT change signature")
    func microPrefChangePreservesSignature() {
        let a = makeContext(eventCount: 5)
        let b = makeContext(eventCount: 5) { p in
            // Quantization to 1 decimal absorbs sub-0.05 changes.
            p.focusBlockWeight += 0.001
        }
        #expect(TaskSignature(context: a) == TaskSignature(context: b))
    }

    @Test("Property: 100 distinct workloads produce ≥ 95 unique signatures")
    func collisionRateBelowFivePercent() {
        // Generate 100 workloads spanning event count, prefs, durations.
        var contexts: [OptimizerContext] = []
        for c in 1...10 {
            for w in 0..<10 {
                let scale = 1.0 + 0.5 * Double(w)
                contexts.append(makeContext(eventCount: c, priorityScale: scale) { p in
                    p.deadlineWeight = 1.0 + Double(w)
                    p.focusBlockWeight = 1.0 + 0.3 * Double(w)
                })
            }
        }
        let signatures = Set(contexts.map { TaskSignature(context: $0) })
        #expect(signatures.count >= 95, "Got \(signatures.count) unique signatures out of 100")
    }

    // MARK: - Adversarial collision constructions

    /// Two workloads with the same total duration but different
    /// per-event durations — their `totalDurationBucket` collides.
    /// The signature must still distinguish them via `eventIDsHash`.
    @Test("Equal total duration with different event mixes produces distinct signatures")
    func sameTotalDurationDifferentMix() {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let horizon = DateInterval(start: today, duration: 86400)
        let a = OptimizerContext(
            movableEvents: [
                .init(id: "a-1", title: "a-1", duration: 3600, priority: 0.5),
                .init(id: "a-2", title: "a-2", duration: 3600, priority: 0.5)
            ],
            workingHours: 9...18,
            planningHorizon: horizon,
            preferences: OptimizerPreferences()
        )
        let b = OptimizerContext(
            movableEvents: [
                .init(id: "b-1", title: "b-1", duration: 1800, priority: 0.5),
                .init(id: "b-2", title: "b-2", duration: 5400, priority: 0.5)
            ],
            workingHours: 9...18,
            planningHorizon: horizon,
            preferences: OptimizerPreferences()
        )
        // Both have totalDuration = 7200; eventIDsHash must
        // disambiguate.
        #expect(TaskSignature(context: a) != TaskSignature(context: b))
    }

    /// Two workloads with the same event IDs but different
    /// preference weights must produce different signatures.
    @Test("Same events, different prefs → distinct signatures")
    func sameEventsDifferentPrefs() {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let horizon = DateInterval(start: today, duration: 86400)
        let events: [OptimizableEvent] = [
            .init(id: "shared-1", title: "x", duration: 1800, priority: 0.5),
            .init(id: "shared-2", title: "y", duration: 1800, priority: 0.5)
        ]
        var prefsHigh = OptimizerPreferences()
        prefsHigh.deadlineWeight = 5.0
        var prefsLow = OptimizerPreferences()
        prefsLow.deadlineWeight = 0.1

        let a = OptimizerContext(movableEvents: events, workingHours: 9...18, planningHorizon: horizon, preferences: prefsHigh)
        let b = OptimizerContext(movableEvents: events, workingHours: 9...18, planningHorizon: horizon, preferences: prefsLow)
        #expect(TaskSignature(context: a) != TaskSignature(context: b))
    }

    /// Reordered event input must produce the same signature
    /// (signature should be order-independent).
    @Test("Event ordering doesn't affect signature")
    func eventOrderInsensitive() {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let horizon = DateInterval(start: today, duration: 86400)
        let e1 = OptimizableEvent(id: "x", title: "x", duration: 1800, priority: 0.5)
        let e2 = OptimizableEvent(id: "y", title: "y", duration: 3600, priority: 0.5)

        let forward = OptimizerContext(movableEvents: [e1, e2], workingHours: 9...18, planningHorizon: horizon, preferences: OptimizerPreferences())
        let reverse = OptimizerContext(movableEvents: [e2, e1], workingHours: 9...18, planningHorizon: horizon, preferences: OptimizerPreferences())
        #expect(TaskSignature(context: forward) == TaskSignature(context: reverse))
    }
}
