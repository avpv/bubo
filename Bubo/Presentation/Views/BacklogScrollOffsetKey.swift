import SwiftUI

// MARK: - BacklogScrollOffsetKey

/// Reports the scroll offset of the `BacklogFullscreenView` content area
/// up to the parent view, which uses it to drive sticky-collapse of the
/// filter band. Reduce keeps the latest value — the probe sits at the
/// top of the scroll content, so there's only ever one writer per pass.
///
/// Lives at file scope (was nested fileprivate inside
/// `BacklogFullscreenView.swift` until 2026-05-11) so the type's surface
/// is independent of the view implementation.
struct BacklogScrollOffsetKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}
