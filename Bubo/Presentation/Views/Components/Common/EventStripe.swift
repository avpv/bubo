import SwiftUI

// MARK: - Event Stripe
//
// The 3 px coloured stripe down the left edge of an event row in the
// prototype (`.bb-event .stripe`). Four variants encode the event type:
//
//   • `.solid`   — default. Filled with `--cal-color` (the event's
//                  calendar color) or `--accent` for the "now" stripe.
//   • `.dashed`  — travel events. Vertical dashes 0–4 / 4–7 in `--fg-3`.
//                  In the prototype: `background:
//                  repeating-linear-gradient(180deg, var(--fg-3) 0 4px,
//                  transparent 4px 7px);`
//   • `.dotted`  — reminders. 3 px radial dot column in `--cal-color`.
//                  In the prototype: `radial-gradient(circle 1.2px at
//                  50% 50%, var(--cal-color), transparent 70%);`
//                  `background-size: 100% 6px;`
//   • `.diagonal` — cancelled. 135° diagonal stripes of `--fg-1` at
//                   22 % opacity. In the prototype: `repeating-linear-
//                   gradient(135deg, ...22% 0 2px, transparent 2px 4px)`.
//
// All variants share width = `DS.Size.eventStripeWidth` (3 pt) and
// radius 2 pt. The host row passes the row height implicitly via
// `.frame(maxHeight: .infinity)`.

enum EventStripeVariant {
    case solid
    case dashed
    case dotted
    case diagonal
}

struct EventStripe: View {
    /// Tint for `solid` / `dotted` variants. Falls back to the active
    /// skin's accent when nil. Ignored for `dashed` (uses `--fg-3`) and
    /// `diagonal` (uses `--fg-1` at 22 %).
    var color: Color? = nil
    var variant: EventStripeVariant = .solid

    @Environment(\.activeSkin) private var skin

    var body: some View {
        let tint = color ?? skin.accentColor
        ZStack {
            switch variant {
            case .solid:
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(tint)
            case .dashed:
                // Repeating vertical dashes: 4 pt on, 3 pt off.
                GeometryReader { proxy in
                    Canvas { ctx, size in
                        let step: CGFloat = 7
                        let dashLen: CGFloat = 4
                        var y: CGFloat = 0
                        while y < size.height {
                            let rect = CGRect(x: 0, y: y, width: size.width, height: min(dashLen, size.height - y))
                            ctx.fill(Path(roundedRect: rect, cornerRadius: 1), with: .color(skin.resolvedTextTertiary))
                            y += step
                        }
                    }
                    .frame(width: proxy.size.width, height: proxy.size.height)
                }
            case .dotted:
                // Repeating radial dots, 6 pt cadence.
                GeometryReader { proxy in
                    Canvas { ctx, size in
                        let step: CGFloat = 6
                        let r: CGFloat = 1.2
                        var y: CGFloat = step / 2
                        let cx = size.width / 2
                        while y < size.height {
                            let rect = CGRect(x: cx - r, y: y - r, width: r * 2, height: r * 2)
                            ctx.fill(Path(ellipseIn: rect), with: .color(tint))
                            y += step
                        }
                    }
                    .frame(width: proxy.size.width, height: proxy.size.height)
                }
            case .diagonal:
                // 135° diagonal stripes at fg-1 22 %.
                GeometryReader { proxy in
                    Canvas { ctx, size in
                        let stripeColor = skin.resolvedTextPrimary.opacity(0.22)
                        let step: CGFloat = 4
                        let stripeW: CGFloat = 2
                        let diagonal = size.width + size.height
                        var offset: CGFloat = -size.height
                        while offset < diagonal {
                            var path = Path()
                            path.move(to: CGPoint(x: offset, y: 0))
                            path.addLine(to: CGPoint(x: offset + stripeW, y: 0))
                            path.addLine(to: CGPoint(x: offset + stripeW + size.height, y: size.height))
                            path.addLine(to: CGPoint(x: offset + size.height, y: size.height))
                            path.closeSubpath()
                            ctx.fill(path, with: .color(stripeColor))
                            offset += step
                        }
                    }
                    .frame(width: proxy.size.width, height: proxy.size.height)
                    .clipShape(RoundedRectangle(cornerRadius: 2, style: .continuous))
                }
            }
        }
        .frame(width: DS.Size.eventStripeWidth)
        .frame(maxHeight: .infinity)
    }
}
