import SwiftUI

// MARK: - Overdue Pulse Dot

/// Red dot that softly pulses opacity to draw the eye to overdue tasks.
/// Sits before the meta text in the row footer. Static (no animation) when
/// `reduceMotion` is on — colour alone still flags the state.
struct OverduePulseDot: View {
    let reduceMotion: Bool
    @Environment(\.activeSkin) var skin
    @State var pulsing = false

    var body: some View {
        Circle()
            .fill(skin.resolvedDestructiveColor)
            .frame(width: DS.Size.recipeDotSize, height: DS.Size.recipeDotSize)
            .opacity(reduceMotion ? 1 : (pulsing ? 0.35 : 1))
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(DS.Animation.pulseMedium().repeatForever(autoreverses: true)) {
                    pulsing = true
                }
            }
    }
}
