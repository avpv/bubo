import SwiftUI

struct OwlIcon: View {
    var size: CGFloat = 20
    @State private var isBouncing = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Canvas { context, canvasSize in
            let s = canvasSize.width

            // Body (rounded rect)
            let bodyRect = CGRect(x: s * 0.15, y: s * 0.05, width: s * 0.7, height: s * 0.7)
            let bodyPath = RoundedRectangle(cornerRadius: s * 0.2)
                .path(in: bodyRect)
            context.fill(bodyPath, with: .foreground)

            // Left ear
            var leftEar = Path()
            leftEar.move(to: CGPoint(x: s * 0.15, y: s * 0.65))
            leftEar.addLine(to: CGPoint(x: s * 0.28, y: s * 0.92))
            leftEar.addLine(to: CGPoint(x: s * 0.38, y: s * 0.7))
            leftEar.closeSubpath()
            context.fill(leftEar, with: .foreground)

            // Right ear
            var rightEar = Path()
            rightEar.move(to: CGPoint(x: s * 0.85, y: s * 0.65))
            rightEar.addLine(to: CGPoint(x: s * 0.72, y: s * 0.92))
            rightEar.addLine(to: CGPoint(x: s * 0.62, y: s * 0.7))
            rightEar.closeSubpath()
            context.fill(rightEar, with: .foreground)

            // Eyes (cut out circles)
            let eyeR = s * 0.1
            let eyeY = s * 0.48
            let leftEyeRect = CGRect(x: s * 0.28, y: eyeY, width: eyeR * 2, height: eyeR * 2)
            let rightEyeRect = CGRect(x: s * 0.52, y: eyeY, width: eyeR * 2, height: eyeR * 2)
            let leftEyePath = Ellipse().path(in: leftEyeRect)
            let rightEyePath = Ellipse().path(in: rightEyeRect)
            context.blendMode = .destinationOut
            context.fill(leftEyePath, with: .foreground)
            context.fill(rightEyePath, with: .foreground)

            // Pupils (fill back)
            context.blendMode = .normal
            let pupilR = s * 0.05
            let pupilY = eyeY + eyeR - pupilR
            let leftPupil = Ellipse().path(in: CGRect(x: s * 0.33, y: pupilY, width: pupilR * 2, height: pupilR * 2))
            let rightPupil = Ellipse().path(in: CGRect(x: s * 0.57, y: pupilY, width: pupilR * 2, height: pupilR * 2))
            context.fill(leftPupil, with: .foreground)
            context.fill(rightPupil, with: .foreground)

            // Small beak
            var beak = Path()
            beak.move(to: CGPoint(x: s * 0.44, y: s * 0.4))
            beak.addLine(to: CGPoint(x: s * 0.5, y: s * 0.32))
            beak.addLine(to: CGPoint(x: s * 0.56, y: s * 0.4))
            beak.closeSubpath()
            context.fill(beak, with: .foreground)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
        .scaleEffect(isBouncing ? 0.75 : 1.0)
        .rotationEffect(.degrees(isBouncing ? 12 : 0))
        .onTapGesture {
            Haptics.tap()
            guard !reduceMotion else { return }
            withAnimation(.spring(response: 0.2, dampingFraction: 0.4)) {
                isBouncing = true
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                withAnimation(.spring(response: 0.4, dampingFraction: 0.5)) {
                    isBouncing = false
                }
            }
        }
        #if os(macOS)
        .onHover { isHovered in
            if isHovered {
                NSCursor.pointingHand.push()
            } else {
                NSCursor.pop()
            }
        }
        #endif
    }
}
