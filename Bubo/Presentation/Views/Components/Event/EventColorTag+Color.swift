import SwiftUI
import BuboDomain

// MARK: - EventColorTag → SwiftUI Color

/// SwiftUI mapping for `EventColorTag`. Kept out of the domain model so
/// `Models/Domain/CalendarEvent.swift` doesn't need to import `SwiftUI`.
extension EventColorTag {
    var color: Color {
        switch self {
        case .red: .red
        case .orange: .orange
        case .yellow: .yellow
        case .green: .green
        case .blue: .blue
        case .purple: .purple
        case .pink: .pink
        }
    }
}
