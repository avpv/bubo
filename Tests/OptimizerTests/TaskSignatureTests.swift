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
}
