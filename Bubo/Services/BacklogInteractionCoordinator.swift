import Foundation
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Typed drag payload

/// Payload dragged out of the backlog.
///
/// The drag handle uses `.onDrag` (NSItemProvider with `public.json`)
/// to initiate the drag, and drop targets use `.dropDestination(for:)`
/// with this type's `CodableRepresentation`. Both sides agree on the
/// `.json` UTType so the pasteboard round-trip works without a custom
/// UTType declaration.
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

    func beginDrag(_ payload: BacklogTaskDrag) {
        draggedTask = payload
    }

    func endDrag() {
        draggedTask = nil
    }

    // MARK: Ghost preview state

    /// The slot that a ghost block should occupy on the timeline while the
    /// user is typing a new task. nil hides the ghost entirely.
    var ghostSlot: DateInterval? = nil

    /// Title shown inside the ghost block. Cleared together with `ghostSlot`.
    var ghostTitle: String? = nil

    func setGhost(slot: DateInterval?, title: String?) {
        ghostSlot = slot
        ghostTitle = title
    }

    func clearGhost() {
        ghostSlot = nil
        ghostTitle = nil
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
        let pattern = #"(?:\s|^)(?:(\d+)\s*(?:h|hr|hrs|hour|hours)(?:\s*(\d+)\s*(?:m|min|mins|minute|minutes))?|(\d+)\s*(?:m|min|mins|minute|minutes))\s*$"#

        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else {
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
}
