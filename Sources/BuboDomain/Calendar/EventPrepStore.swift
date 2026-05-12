import Foundation

// MARK: - Event Prep Store
//
// Per-event prep notes — a private markdown scratchpad keyed by event id
// for jotting down what to say / what to ask before a meeting. Lives in
// `UserDefaults` (mirrored to iCloud key-value store via
// `CloudSyncService.shared.push`) so notes survive restarts and follow
// the user across devices, but never touch the shared calendar event —
// colleagues invited to the same meeting see nothing.
//
// Storage shape: a single JSON-encoded `[String: PrepEntry]` blob under
// `Key.notes`. Encoding the whole map at once keeps the on-disk
// representation small (one round-trip per write, no per-event prefix
// scan) and survives iCloud KV's per-key value-size limit comfortably —
// even 100 events × 4 KB of notes is well under the 1 MB ceiling.
//
// Eviction: trimmed by `maxEntries` on save, dropping the oldest
// `updatedAt` first. Per-event delete is also explicit so a user can
// wipe one note without affecting the others.

public enum EventPrepStore {

    /// One stored prep blob. `text` is markdown, `updatedAt` is the
    /// last write timestamp (used for eviction order).
    struct PrepEntry: Codable, Hashable {
        var text: String
        var updatedAt: Date
    }

    private enum Key {
        static let notes = "BuboEventPrepNotes"
    }

    /// Soft cap on the number of stored prep entries. Older entries
    /// (lowest `updatedAt`) are evicted on save. Tuned generously — most
    /// users keep prep for a handful of upcoming meetings, not a year of
    /// archives.
    private static let maxEntries = 200

    // MARK: - Read

    /// Returns the current note for `eventId`, or empty string when none
    /// exists. Callers in the view layer should treat empty == not yet
    /// written so the row is collapsed by default.
    public static func text(for eventId: String) -> String {
        loadAll()[eventId]?.text ?? ""
    }

    /// Returns the most recent update time for `eventId`'s note, used by
    /// the detail view to label the section ("Updated 2 min ago"). nil
    /// when no note exists.
    public static func updatedAt(for eventId: String) -> Date? {
        loadAll()[eventId]?.updatedAt
    }

    // MARK: - Write

    /// Persist a note for `eventId`. Empty / whitespace-only writes
    /// remove the entry instead of storing a blank one — keeps the
    /// dictionary small and avoids iCloud sync of empty payloads.
    public static func setText(_ text: String, for eventId: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var all = loadAll()
        if trimmed.isEmpty {
            guard all[eventId] != nil else { return }
            all.removeValue(forKey: eventId)
        } else {
            all[eventId] = PrepEntry(text: text, updatedAt: Date())
        }
        save(all)
    }

    /// Drop the entry for `eventId`. No-op when missing.
    public static func clear(for eventId: String) {
        var all = loadAll()
        guard all.removeValue(forKey: eventId) != nil else { return }
        save(all)
    }

    // MARK: - Internals

    private static func loadAll() -> [String: PrepEntry] {
        guard let data = UserDefaults.standard.data(forKey: Key.notes),
              let decoded = try? JSONDecoder().decode([String: PrepEntry].self, from: data)
        else { return [:] }
        return decoded
    }

    private static func save(_ map: [String: PrepEntry]) {
        // Eviction: keep at most `maxEntries`, ordered by recency. The
        // pre-evict step runs only when we cross the cap so the common
        // case (a few dozen entries) avoids the sort cost.
        var trimmed = map
        if trimmed.count > maxEntries {
            let sorted = trimmed.sorted { $0.value.updatedAt > $1.value.updatedAt }
            trimmed = Dictionary(uniqueKeysWithValues: sorted.prefix(maxEntries).map { ($0.key, $0.value) })
        }
        guard let data = try? JSONEncoder().encode(trimmed) else { return }
        UserDefaults.standard.set(data, forKey: Key.notes)
    }
}
