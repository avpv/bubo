import SwiftUI

// MARK: - Calendar / Tag Dot
//
// Small coloured circle that appears next to:
//   • Pomodoro task title (`.pomo-task .cal-dot` — 8 px, --cal-color)
//   • Task source row in task details (`.tp-source` calendar icon)
//   • Slot-picker scheduled-task line (`.sp-task-dot` — 8 px)
//   • Tag chip in task details (`.tp-tag .dot` — 6 px, --tag-color)
//
// One canonical primitive instead of three `Circle().fill(...).frame(...)`
// reinventions. Default size matches the prototype's 8 px dot; use
// `.tag` for the smaller 6 px tag variant.

enum CalDotSize {
    /// 8 pt — calendar / task indicator dot.
    case calendar
    /// 6 pt — tag-chip leading dot.
    case tag
    /// Custom diameter.
    case custom(CGFloat)

    var diameter: CGFloat {
        switch self {
        case .calendar: return 8
        case .tag: return 6
        case .custom(let value): return value
        }
    }
}

struct CalDot: View {
    let color: Color
    var size: CalDotSize = .calendar

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: size.diameter, height: size.diameter)
            .accessibilityHidden(true)
    }
}
