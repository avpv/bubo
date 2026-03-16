import SwiftUI

struct OwlIcon: View {
    var size: CGFloat = 20

    var body: some View {
        Canvas { context, canvasSize in
            let s = canvasSize.width

            // Body
            let bodyRect = CGRect(x: s * 0.1, y: s * 0.15, width: s * 0.8, height: s * 0.75)
            let bodyPath = RoundedRectangle(cornerRadius: s * 0.25)
                .path(in: bodyRect)
            context.fill(bodyPath, with: .linearGradient(
                Gradient(colors: [Color(red: 0.35, green: 0.28, blue: 0.65), Color(red: 0.25, green: 0.2, blue: 0.5)]),
                startPoint: CGPoint(x: s * 0.5, y: s * 0.15),
                endPoint: CGPoint(x: s * 0.5, y: s * 0.9)
            ))

            // Left ear
            var leftEar = Path()
            leftEar.move(to: CGPoint(x: s * 0.12, y: s * 0.35))
            leftEar.addLine(to: CGPoint(x: s * 0.25, y: s * 0.02))
            leftEar.addLine(to: CGPoint(x: s * 0.4, y: s * 0.3))
            leftEar.closeSubpath()
            context.fill(leftEar, with: .color(Color(red: 0.35, green: 0.28, blue: 0.65)))

            // Right ear
            var rightEar = Path()
            rightEar.move(to: CGPoint(x: s * 0.88, y: s * 0.35))
            rightEar.addLine(to: CGPoint(x: s * 0.75, y: s * 0.02))
            rightEar.addLine(to: CGPoint(x: s * 0.6, y: s * 0.3))
            rightEar.closeSubpath()
            context.fill(rightEar, with: .color(Color(red: 0.35, green: 0.28, blue: 0.65)))

            // Ear tufts (inner lighter triangles)
            var leftTuft = Path()
            leftTuft.move(to: CGPoint(x: s * 0.18, y: s * 0.35))
            leftTuft.addLine(to: CGPoint(x: s * 0.26, y: s * 0.1))
            leftTuft.addLine(to: CGPoint(x: s * 0.36, y: s * 0.32))
            leftTuft.closeSubpath()
            context.fill(leftTuft, with: .color(Color(red: 0.45, green: 0.38, blue: 0.72)))

            var rightTuft = Path()
            rightTuft.move(to: CGPoint(x: s * 0.82, y: s * 0.35))
            rightTuft.addLine(to: CGPoint(x: s * 0.74, y: s * 0.1))
            rightTuft.addLine(to: CGPoint(x: s * 0.64, y: s * 0.32))
            rightTuft.closeSubpath()
            context.fill(rightTuft, with: .color(Color(red: 0.45, green: 0.38, blue: 0.72)))

            // Face disc (lighter oval)
            let faceRect = CGRect(x: s * 0.18, y: s * 0.28, width: s * 0.64, height: s * 0.42)
            let facePath = Ellipse().path(in: faceRect)
            context.fill(facePath, with: .color(Color(red: 0.85, green: 0.82, blue: 0.92)))

            // Left eye white
            let eyeW = s * 0.2
            let eyeH = s * 0.22
            let eyeY = s * 0.34
            let leftEyeRect = CGRect(x: s * 0.22, y: eyeY, width: eyeW, height: eyeH)
            let leftEyePath = Ellipse().path(in: leftEyeRect)
            context.fill(leftEyePath, with: .color(.white))
            context.stroke(leftEyePath, with: .color(Color(red: 0.3, green: 0.25, blue: 0.5)), lineWidth: s * 0.015)

            // Right eye white
            let rightEyeRect = CGRect(x: s * 0.58, y: eyeY, width: eyeW, height: eyeH)
            let rightEyePath = Ellipse().path(in: rightEyeRect)
            context.fill(rightEyePath, with: .color(.white))
            context.stroke(rightEyePath, with: .color(Color(red: 0.3, green: 0.25, blue: 0.5)), lineWidth: s * 0.015)

            // Left pupil
            let pupilS = s * 0.1
            let pupilY = eyeY + eyeH * 0.3
            let leftPupil = Ellipse().path(in: CGRect(x: s * 0.27, y: pupilY, width: pupilS, height: pupilS))
            context.fill(leftPupil, with: .color(Color(red: 0.15, green: 0.1, blue: 0.3)))

            // Right pupil
            let rightPupil = Ellipse().path(in: CGRect(x: s * 0.63, y: pupilY, width: pupilS, height: pupilS))
            context.fill(rightPupil, with: .color(Color(red: 0.15, green: 0.1, blue: 0.3)))

            // Eye glints
            let glintS = s * 0.035
            let leftGlint = Ellipse().path(in: CGRect(x: s * 0.29, y: pupilY + s * 0.015, width: glintS, height: glintS))
            context.fill(leftGlint, with: .color(.white))
            let rightGlint = Ellipse().path(in: CGRect(x: s * 0.65, y: pupilY + s * 0.015, width: glintS, height: glintS))
            context.fill(rightGlint, with: .color(.white))

            // Beak
            var beak = Path()
            beak.move(to: CGPoint(x: s * 0.43, y: s * 0.54))
            beak.addLine(to: CGPoint(x: s * 0.5, y: s * 0.64))
            beak.addLine(to: CGPoint(x: s * 0.57, y: s * 0.54))
            beak.closeSubpath()
            context.fill(beak, with: .color(Color(red: 0.95, green: 0.7, blue: 0.2)))

            // Belly pattern (subtle chevrons)
            let chevronColor = Color(red: 0.3, green: 0.24, blue: 0.55).opacity(0.3)
            for i in 0..<3 {
                let cy = s * (0.68 + Double(i) * 0.06)
                var chevron = Path()
                chevron.move(to: CGPoint(x: s * 0.35, y: cy))
                chevron.addLine(to: CGPoint(x: s * 0.5, y: cy + s * 0.03))
                chevron.addLine(to: CGPoint(x: s * 0.65, y: cy))
                context.stroke(chevron, with: .color(chevronColor), lineWidth: s * 0.015)
            }

            // Feet
            let feetColor = Color(red: 0.95, green: 0.7, blue: 0.2)
            var leftFoot = Path()
            leftFoot.move(to: CGPoint(x: s * 0.3, y: s * 0.88))
            leftFoot.addLine(to: CGPoint(x: s * 0.25, y: s * 0.96))
            leftFoot.move(to: CGPoint(x: s * 0.35, y: s * 0.88))
            leftFoot.addLine(to: CGPoint(x: s * 0.32, y: s * 0.96))
            leftFoot.move(to: CGPoint(x: s * 0.4, y: s * 0.88))
            leftFoot.addLine(to: CGPoint(x: s * 0.39, y: s * 0.96))
            context.stroke(leftFoot, with: .color(feetColor), style: StrokeStyle(lineWidth: s * 0.025, lineCap: .round))

            var rightFoot = Path()
            rightFoot.move(to: CGPoint(x: s * 0.6, y: s * 0.88))
            rightFoot.addLine(to: CGPoint(x: s * 0.61, y: s * 0.96))
            rightFoot.move(to: CGPoint(x: s * 0.65, y: s * 0.88))
            rightFoot.addLine(to: CGPoint(x: s * 0.68, y: s * 0.96))
            rightFoot.move(to: CGPoint(x: s * 0.7, y: s * 0.88))
            rightFoot.addLine(to: CGPoint(x: s * 0.75, y: s * 0.96))
            context.stroke(rightFoot, with: .color(feetColor), style: StrokeStyle(lineWidth: s * 0.025, lineCap: .round))
        }
        .frame(width: size, height: size)
    }
}
