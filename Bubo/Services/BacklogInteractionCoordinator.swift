import AppKit
import Foundation
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Typed drag payload

/// Payload dragged out of the backlog.
///
/// The row itself uses `.onDrag` (NSItemProvider with `public.json`)
/// to initiate the drag — long-press anywhere on the row, no visible
/// handle (Apple Reminders / Things pattern). Drop targets use
/// `.dropDestination(for:)` with this type's `CodableRepresentation`.
/// Both sides agree on the `.json` UTType so the pasteboard round-trip
/// works without a custom UTType declaration.
struct BacklogTaskDrag: Codable, Transferable, Hashable {
    let taskId: String
    let title: String
    let durationMinutes: Int
    let context: String?

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .json)
    }
}

// MARK: - Shared interaction coordinator

/// Cross-view state for an in-flight backlog-task drag and for the typed
/// "ghost" preview.
///
/// The backlog lives inside a scroll view; free-slot rows live further down
/// the same scroll view. Without a shared coordinator, each row only knows
/// what the user's cursor is currently over — we couldn't light up every
/// valid drop target the moment the drag starts, and we couldn't render a
/// ghost block on the timeline while the user is still typing in the input.
///
/// This object is instantiated once by `MenuBarView`, injected via the
/// environment, and read by both the drag source (`BacklogTaskRow`) and the
/// drop targets (`FreeSlotRow`, plus the ghost row renderer in `MenuBarView`).
@MainActor
@Observable
final class BacklogInteractionCoordinator {

    // MARK: Drag state

    /// The task currently being dragged out of the backlog, or nil when no
    /// drag is in flight. Free-slot rows observe this to pulse an accent
    /// outline so all valid drop targets are visible at once.
    var draggedTask: BacklogTaskDrag? = nil

    var isDraggingTask: Bool { draggedTask != nil }

    /// Watchdog that ends the drag the moment the user releases the left
    /// mouse button. Defence-in-depth backup for the SwiftUI drag-preview
    /// lifecycle (`.draggable(_:preview:) { ... .onDisappear { ... } }`),
    /// which on macOS still has reports of not firing reliably when the
    /// drag is cancelled (cursor dropped outside any registered
    /// destination, Esc pressed mid-drag). Without this, `draggedTask` can
    /// stay non-nil after a cancelled drag — the timeline then keeps
    /// showing the collapsed-events header and free slots only, and the
    /// events look like they vanished.
    ///
    /// Once the `.draggable` migration has soaked on real hardware and the
    /// preview's `onDisappear` proves reliable, this watchdog can be
    /// deleted — `endDrag()` from the preview lifecycle is enough.
    private var dragReleaseWatchdog: Task<Void, Never>?

    /// Wrapping the mutation in `withAnimation` means every subscriber
    /// (BacklogView's expansion, MenuBarView's collapsed-events header,
    /// FreeSlotRow's drop-awaiting border, any future consumers) animates
    /// in lockstep. Without this, each observer picks its own timing and
    /// the transition «щёлкает».
    func beginDrag(_ payload: BacklogTaskDrag) {
        withAnimation(DS.Animation.standard) {
            draggedTask = payload
        }
        startDragReleaseWatchdog()
    }

    func endDrag() {
        dragReleaseWatchdog?.cancel()
        dragReleaseWatchdog = nil
        withAnimation(DS.Animation.standard) {
            draggedTask = nil
            // Drag-initiated ghost (from FreeSlotRow's drop-target hover)
            // is bound to the drag lifetime: once the drop lands or the
            // drag is cancelled, the ghost has nothing to predict. Clear
            // it here so MenuBarView's suppression logic doesn't freeze
            // a slot as "filled" after the fact.
            ghostSlot = nil
            ghostTitle = nil
        }
    }

    /// Poll the global mouse-button state until the left button is no
    /// longer held, then finalise the drag. `NSEvent.pressedMouseButtons`
    /// is a real-time query that works during AppKit's modal drag loop,
    /// where regular SwiftUI/NSEvent monitor callbacks are unreliable.
    /// 80 ms is below the perceptual threshold for "the timeline froze"
    /// while staying cheap enough not to register on the runloop.
    private func startDragReleaseWatchdog() {
        dragReleaseWatchdog?.cancel()
        dragReleaseWatchdog = Task { @MainActor [weak self] in
            let pollInterval: UInt64 = 80_000_000 // 80 ms
            // One tick of grace so we don't sample before AppKit has
            // committed the mouse button into "drag in progress" state.
            try? await Task.sleep(nanoseconds: pollInterval)
            while !Task.isCancelled {
                guard let self, self.draggedTask != nil else { return }
                if NSEvent.pressedMouseButtons & 0x1 == 0 {
                    self.endDrag()
                    return
                }
                try? await Task.sleep(nanoseconds: pollInterval)
            }
        }
    }

    // MARK: Ghost preview state

    /// The slot that a ghost block should occupy on the timeline while the
    /// user is typing a new task. nil hides the ghost entirely.
    var ghostSlot: DateInterval? = nil

    /// Title shown inside the ghost block. Cleared together with `ghostSlot`.
    var ghostTitle: String? = nil

    func setGhost(slot: DateInterval?, title: String?) {
        withAnimation(DS.Animation.quick) {
            ghostSlot = slot
            ghostTitle = title
        }
    }

    func clearGhost() {
        withAnimation(DS.Animation.quick) {
            ghostSlot = nil
            ghostTitle = nil
        }
    }
}

// MARK: - Environment plumbing

private struct BacklogInteractionCoordinatorKey: EnvironmentKey {
    static let defaultValue: BacklogInteractionCoordinator? = nil
}

extension EnvironmentValues {
    /// The shared coordinator for backlog drag + ghost preview state.
    /// nil when the backlog isn't wired into the current view hierarchy
    /// (e.g. settings panes) — consumers must handle that gracefully.
    var backlogCoordinator: BacklogInteractionCoordinator? {
        get { self[BacklogInteractionCoordinatorKey.self] }
        set { self[BacklogInteractionCoordinatorKey.self] = newValue }
    }
}

// MARK: - Title parsing

/// Shared title/duration parser used by the backlog input and its ghost
/// preview. Lives on the coordinator type so tests can exercise it without
/// spinning up a SwiftUI view.
enum BacklogTitleParser {

    /// Pre-compiled regex for the trailing-duration pattern.
    /// The TextField calls `parse` on every keystroke, which used to
    /// re-compile this regex every time — small cost in isolation, but
    /// enough to show up as a main-thread hotspot once the parser was
    /// also wired into SwiftUI computed properties (body re-eval path).
    /// Compiling once and reusing drops the steady-state cost to a
    /// single `firstMatch` call per keystroke.
    private static let trailingDurationRegex: NSRegularExpression? = {
        let pattern = #"(?:\s|^)(?:(\d+)\s*(?:h|hr|hrs|hour|hours)(?:\s*(\d+)\s*(?:m|min|mins|minute|minutes))?|(\d+)\s*(?:m|min|mins|minute|minutes))\s*$"#
        return try? NSRegularExpression(pattern: pattern, options: .caseInsensitive)
    }()

    /// Parse a trailing duration hint out of a task title.
    ///
    /// Recognises simple patterns at the very end of the title:
    ///   "write report 1h"        → ("write report", 60)
    ///   "review PR 90m"          → ("review PR", 90)
    ///   "design sync 1h30m"      → ("design sync", 90)
    ///   "coffee 2h"              → ("coffee", 120)
    ///
    /// Returns `(cleaned, minutes)` where `cleaned` has the duration token
    /// stripped (trimmed) and `minutes` is nil when nothing matched.
    static func parse(_ title: String) -> (cleaned: String, durationMinutes: Int?) {
        let trimmed = title.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return (trimmed, nil) }

        // Anchor at end-of-string so a word like "30-minute meeting"
        // in the middle of the title isn't mistaken for a duration.
        guard let regex = trailingDurationRegex else {
            return (trimmed, nil)
        }
        let range = NSRange(trimmed.startIndex..., in: trimmed)
        guard let match = regex.firstMatch(in: trimmed, range: range) else {
            return (trimmed, nil)
        }

        func group(_ idx: Int) -> Int? {
            guard match.numberOfRanges > idx,
                  let r = Range(match.range(at: idx), in: trimmed) else { return nil }
            return Int(trimmed[r])
        }

        let hours = group(1)
        let extraMinutes = group(2)
        let onlyMinutes = group(3)

        let total: Int?
        if let hours {
            total = hours * 60 + (extraMinutes ?? 0)
        } else if let onlyMinutes {
            total = onlyMinutes
        } else {
            total = nil
        }

        // Cap the parsed duration at 12h — anything larger is almost
        // certainly not a user intent ("backlog 9999" etc.) and would blow
        // out the ghost-preview scan.
        let clamped = total.map { max(5, min(12 * 60, $0)) }

        guard let clamped,
              let matchRange = Range(match.range, in: trimmed) else {
            return (trimmed, nil)
        }

        let cleaned = String(trimmed[..<matchRange.lowerBound])
            .trimmingCharacters(in: .whitespaces)

        // If stripping the duration leaves nothing, keep the original title
        // so the user doesn't lose what they typed — a bare "30m" becomes
        // both the title and the duration hint.
        return (cleaned.isEmpty ? trimmed : cleaned, clamped)
    }

    // MARK: - Duration guess (machine sweats)

    /// Coarse «what does this verb usually take?» table used by
    /// `guessDuration(for:)` when the user hasn't provided an explicit
    /// duration in the title. Birman: «пусть потеет машина» — даже без
    /// явного 30m система предлагает разумный default по глаголу,
    /// пользователь только поправляет, если не угадали.
    ///
    /// The keys are matched against the title's first whitespace-
    /// delimited word, lowercased — so «Call mom», «call mom 5pm» and
    /// «CALL Anna» all hit the «call» entry. A few nouns are included
    /// for «meeting», «review», «sync» where the noun *is* the action.
    ///
    /// Numbers picked from typical office-work distributions, kept
    /// short on purpose — overestimating is friendlier than under, but
    /// 60-min defaults across the board crush calendars in tests.
    private static let durationGuessTable: [String: Int] = [
        // Communication
        "call":      30,
        "phone":     30,
        "email":     15,
        "reply":     10,
        "respond":   10,
        "message":   10,
        "text":      5,
        "ping":      5,
        // Meetings (the noun *is* the action)
        "meet":      60,
        "meeting":   60,
        "sync":      30,
        "standup":   15,
        "1:1":       30,
        "interview": 45,
        // Writing / making
        "write":     90,
        "draft":     60,
        "design":    90,
        "code":      120,
        "build":     120,
        "ship":      30,
        "deploy":    30,
        "fix":       45,
        "debug":     60,
        // Review / consume
        "review":    45,
        "read":      30,
        "watch":     30,
        "research":  60,
        "study":     60,
        // Errands / chores
        "buy":       30,
        "pick":      30,
        "drop":      15,
        "errand":    30,
        // Admin
        "plan":      30,
        "schedule":  15,
        "book":      10,
        "file":      15,
    ]

    /// Default duration when the verb table doesn't fire — a 60-minute
    /// «medium task» bucket. Caller can override with the user's
    /// `defaultTaskDurationMinutes` setting if they prefer a different
    /// fallback. Returns nil to mean «no guess at all»; this constant is
    /// just the floor used by `guessDuration` when `useDefault: true`.
    static let guessFallbackMinutes: Int = 60

    /// «What does this task usually take?» — coarse machine guess based
    /// on the first word of the title. Returns nil when no entry in the
    /// `durationGuessTable` matches and `useDefault` is false.
    ///
    /// Caller convention: render the result with a leading tilde
    /// («~30m») in `DS.Typography.machineHint` so the user reads it as
    /// «the computer prepared a guess, fix it if you want» — never as a
    /// committed duration. The guess is meant to be displayed alongside
    /// (or instead of) the explicit-parser result; it does not modify
    /// the title.
    ///
    /// Pure, locale-insensitive (lowercase ASCII match). Cap at 4h so a
    /// stray «build the company» doesn't propose a half-day block.
    static func guessDuration(for title: String, useDefault: Bool = false) -> Int? {
        let trimmed = title.trimmingCharacters(in: .whitespaces).lowercased()
        guard !trimmed.isEmpty else { return nil }

        // First whitespace-delimited word; falls back to the whole title
        // when there's no whitespace («call» on its own).
        let firstWord = trimmed.split(separator: " ", maxSplits: 1).first.map(String.init) ?? trimmed

        if let table = durationGuessTable[firstWord] {
            return min(4 * 60, max(5, table))
        }

        return useDefault ? guessFallbackMinutes : nil
    }
}
