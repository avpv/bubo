import SwiftUI

// MARK: - Platform Chip
//
// Conference-platform indicator on event rows that have a join URL.
// Mirrors the prototype's `.platform-chip` (in `prototype-spec.md` §1
// component table):
//
//   bg = fg-1 6 % mix, 0.5 px hairline of fg-1 14 %
//   text = brand colour
//   font weight-semibold 11 / 1, radius 5
//   padding 1 5, leading 10 px brand glyph
//
// Brand colours (literals straight from the prototype CSS):
//   • Zoom  — #2D8CFF
//   • Meet  — #00897B
//   • Teams — #6264A7
//
// Birman: one shape for one role. Don't reinvent this as
// `Capsule().fill(.blue)` somewhere else — wire through `PlatformChip`.

enum CallPlatform: String, CaseIterable {
    case zoom
    case meet
    case teams
    case webex
    case generic

    /// Brand colour for the chip's text and accent strip.
    var color: Color {
        switch self {
        case .zoom:    return Color(red: 0x2D / 255, green: 0x8C / 255, blue: 0xFF / 255)
        case .meet:    return Color(red: 0x00 / 255, green: 0x89 / 255, blue: 0x7B / 255)
        case .teams:   return Color(red: 0x62 / 255, green: 0x64 / 255, blue: 0xA7 / 255)
        case .webex:   return Color(red: 0x00 / 255, green: 0x9C / 255, blue: 0xDB / 255)
        case .generic: return .secondary
        }
    }

    /// Short label inside the chip. Localisation hooks live on the
    /// host's NSLocalizedString table, not here.
    var label: String {
        switch self {
        case .zoom:    return "Zoom"
        case .meet:    return "Meet"
        case .teams:   return "Teams"
        case .webex:   return "Webex"
        case .generic: return "Call"
        }
    }

    /// SF Symbol glyph that sits on the leading edge. `video.fill`
    /// reads as «video call»; specific brands keep the same glyph
    /// because Apple's symbol set doesn't ship brand marks.
    var systemImage: String {
        "video.fill"
    }

    /// Best-effort match from an event's join URL.
    static func detect(from url: URL?) -> CallPlatform? {
        guard let host = url?.host?.lowercased() else { return nil }
        if host.contains("zoom.us") { return .zoom }
        if host.contains("meet.google.com") || host.contains("g.co/meet") { return .meet }
        if host.contains("teams.microsoft.com") || host.contains("teams.live.com") { return .teams }
        if host.contains("webex.com") { return .webex }
        return .generic
    }
}

struct PlatformChip: View {
    let platform: CallPlatform

    @Environment(\.activeSkin) private var skin

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: platform.systemImage)
                .font(.system(size: 10, weight: .semibold))
            Text(platform.label)
                .font(.system(size: 11, weight: .semibold, design: skin.resolvedFontDesign))
        }
        .foregroundStyle(platform.color)
        .padding(.horizontal, 5)
        .padding(.vertical, 1)
        .background(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(skin.resolvedTextPrimary.opacity(DS.Mix.surfaceFilter))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .strokeBorder(
                    skin.resolvedTextPrimary.opacity(DS.Mix.surfaceSeparator),
                    lineWidth: DS.Border.thin
                )
        )
        .accessibilityLabel("\(platform.label) call")
    }
}
