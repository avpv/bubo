import Foundation

// MARK: - Period

/// Time-of-day bucket used by tasks, intents, and scheduling preferences.
///
/// Lives in `Domain/` rather than `Optimizer/` because it is referenced
/// from `BacklogTask`, presentation pickers, and intent DSL — all of
/// which sit above or beside the optimizer. Moving it here breaks the
/// Domain ↔ Optimizer dependency cycle.
public enum Period: String, Codable, Hashable, CaseIterable, Sendable {
    case night
    case morning
    case afternoon
    case evening

    public var hourRange: ClosedRange<Int> {
        switch self {
        case .night: return 0...6
        case .morning: return 6...12
        case .afternoon: return 12...18
        case .evening: return 18...23
        }
    }

    /// Short human label used by pill controls and accessibility hints.
    /// Keeps the vocabulary consistent wherever the period surfaces.
    public var displayLabel: String {
        switch self {
        case .night: return "Night"
        case .morning: return "Morning"
        case .afternoon: return "Afternoon"
        case .evening: return "Evening"
        }
    }
}
