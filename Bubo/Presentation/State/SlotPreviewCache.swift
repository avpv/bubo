import Foundation
import Observation
import BuboDomain

// MARK: - Slot Preview Cache

/// Memoises "where would a task of this duration land?" lookups so the
/// ghost preview under the "Add task" field and the per-row hover hint
/// share a single compute against `FreeSlotFinder`.
///
/// Keys on duration-minutes + an events fingerprint so both call sites
/// agree on the answer, and a calendar mutation invalidates the row hint
/// and ghost preview simultaneously.
@MainActor
@Observable
final class SlotPreviewCache {

    /// Debounce window used by callers — exposed as a constant so the two
    /// call sites (ghost preview, row hover) can stay in step without
    /// threading a configuration argument through.
    static let debounceMillis: Int = 250

    /// Result of a slot lookup — both the formatted label shown in the UI
    /// and the raw `DateInterval` so the ghost-block renderer on the
    /// timeline can draw the actual time range.
    struct Result: Equatable {
        var label: String
        var slot: DateInterval?
    }

    /// Cached results keyed by duration.  The fingerprint is not part of
    /// the key — it gates the whole cache: when it changes, the dictionary
    /// is dropped, not invalidated entry-by-entry. Fewer moving parts,
    /// cheaper to reason about, and the cache is small enough (O(N tasks))
    /// that a clear-and-recompute is trivial.
    private var entries: [Int: Result] = [:]

    /// Last fingerprint the cache was built for.  See `invalidateIfChanged`.
    private var fingerprint: Int = 0

    /// In-flight compute tasks so a quick hover-enter / hover-leave burst
    /// doesn't spawn N concurrent lookups for the same duration.
    private var inflight: [Int: Task<Result?, Never>] = [:]

    // MARK: Invalidation

    /// Cheap digest over the fields that affect slot answers.  Any mutation
    /// to task count, total duration, or the visible calendar event count
    /// trips a clear so stale hints don't linger.
    static func fingerprint(tasks: [BacklogTask], eventCount: Int) -> Int {
        var hasher = Hasher()
        hasher.combine(tasks.count)
        hasher.combine(tasks.reduce(0) { $0 + $1.durationMinutes })
        hasher.combine(eventCount)
        return hasher.finalize()
    }

    /// Drop the cache if the fingerprint changed since last check. Called
    /// from `BacklogView.onChange(of: fingerprint)` — the view owns the
    /// invalidation policy, we just apply it.
    func invalidateIfChanged(to newFingerprint: Int) {
        guard newFingerprint != fingerprint else { return }
        fingerprint = newFingerprint
        entries.removeAll()
        for (_, task) in inflight { task.cancel() }
        inflight.removeAll()
    }

    // MARK: Reads

    /// Return a cached preview label without computing. Callers use this
    /// from a SwiftUI body so the row reads instantly after a hover settles.
    func cached(durationMinutes: Int) -> String? {
        entries[durationMinutes]?.label
    }

    /// Return a cached full result (label + raw slot) without computing.
    func cachedResult(durationMinutes: Int) -> Result? {
        entries[durationMinutes]
    }

    /// Fetch-or-compute with the shared debounce. Cancelling the returned
    /// task is safe — in-flight results never land in the cache unless the
    /// task completed uncancelled.
    @discardableResult
    func preview(
        durationMinutes duration: Int,
        events: [CalendarEvent],
        workingHours: ClosedRange<Int>,
        debounce: Bool = true
    ) -> Task<Result?, Never> {
        if let cached = entries[duration] {
            return Task { cached }
        }
        if let existing = inflight[duration] {
            return existing
        }
        let task = Task<Result?, Never> { @MainActor in
            if debounce {
                try? await Task.sleep(for: .milliseconds(Self.debounceMillis))
                if Task.isCancelled { return nil }
            }
            let slot = FreeSlotFinder.nextSlot(
                matching: duration,
                in: events,
                workingHours: workingHours,
                maxDaysAhead: 7
            )
            if Task.isCancelled { return nil }
            let result = Self.format(slot: slot)
            entries[duration] = result
            inflight[duration] = nil
            return result
        }
        inflight[duration] = task
        return task
    }

    /// Format a raw slot into a `Result`. Exposed as a helper so tests
    /// can verify the label shape without spinning up an events fixture.
    static func format(slot: DateInterval?) -> Result {
        guard let slot else {
            return Result(label: "no free slot this week", slot: nil)
        }
        let fmt = DateFormatter()
        fmt.setLocalizedDateFormatFromTemplate("H:mm")
        let range = "\(fmt.string(from: slot.start))–\(fmt.string(from: slot.end))"
        return Result(label: "\(dayLabel(for: slot.start)) \(range)", slot: slot)
    }

    /// Cancel an in-flight compute — used when the cursor leaves a row
    /// before its debounced lookup lands.  Cache entries, once populated,
    /// survive cancellation so a quick return flashes the preview without
    /// spinning again.
    func cancel(durationMinutes: Int) {
        inflight[durationMinutes]?.cancel()
        inflight[durationMinutes] = nil
    }

    /// Cancel everything. Called from `BacklogView.onDisappear` so Task
    /// closures don't outlive the view.
    func cancelAll() {
        for (_, task) in inflight { task.cancel() }
        inflight.removeAll()
    }

    // MARK: Helpers

    /// Localised label describing how far off `date` is from today. Mirrors
    /// `BacklogView.dayLabel` — kept in sync so the two display paths agree.
    static func dayLabel(for date: Date, calendar cal: Calendar = .current) -> String {
        if cal.isDateInToday(date) { return "Today" }
        if cal.isDateInTomorrow(date) { return "Tomorrow" }
        let fmt = DateFormatter()
        fmt.setLocalizedDateFormatFromTemplate("EEE")
        return fmt.string(from: date)
    }
}
