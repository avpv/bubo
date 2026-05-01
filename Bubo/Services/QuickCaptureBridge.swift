import Foundation

// MARK: - Quick Capture Bridge

/// Tiny in-process buffer that ferries a `⇧↩` quick-capture prefill
/// from `AppDelegate` (where the panel is dismissed) to `MenuBarView`
/// (where `NewTaskView` actually mounts). Lives outside both
/// because the popover may be closed at the moment ⇧↩ fires — the
/// notification posted alongside is the fast path; this is the slow
/// path that survives until the user opens the popover next.
///
/// Single-pass: write once on submit, the next reader consumes via
/// `take()` and the slot is cleared. No queue — a second ⇧↩ before
/// the popover opens overwrites the previous prefill, matching the
/// "drop the thought, get back to work" ethos of quick-capture.
@MainActor
final class QuickCaptureBridge {
    static let shared = QuickCaptureBridge()

    /// Most recent ⇧↩ prefill from quick-capture. Nil = nothing pending.
    private var pendingPrefill: String?

    private init() {}

    func setPending(_ text: String) {
        pendingPrefill = text
    }

    /// Read-and-clear. Called by `MenuBarView` on appear (and on
    /// notification receipt) so the prefill is consumed exactly once.
    func take() -> String? {
        defer { pendingPrefill = nil }
        return pendingPrefill
    }
}
