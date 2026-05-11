import SwiftUI

// MARK: - Menu-bar preference keys

/// Bottom-Y of the optimizer entry strip — the inline QuickActions card on
/// `.list`, or the fullscreen Backlog's block header on `.backlog`. The
/// command palette anchors itself below this Y so the «Optimize ⌘K» trigger
/// that opened it stays visible and the palette feels glued to its origin.
///
/// Both the menu-bar list and the fullscreen Backlog publish into the same
/// key so switching surfaces doesn't make the palette float over the
/// popover header.
struct OptimizerBottomKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// Named coordinate space shared by MenuBarView's root and its descendants
/// for hit-test math and popover anchoring.
let menuBarRootCoordinateSpace = "MenuBarViewRoot"
