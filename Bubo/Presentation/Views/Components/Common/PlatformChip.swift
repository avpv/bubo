import SwiftUI

// MARK: - PlatformChip
//
// Brand-coloured chip identifying a meeting's conferencing platform.
// Used in the Today event row's `meta-stack` (Zoom · M·A·+2),
// in the fullscreen meeting alert's platform-aware Join button
// (`Join Zoom`), and in the join ribbon's title block.
//
// `PRINCIPLES §7`: brand tints carry meaning (which app the user
// clicks into). They are NOT skinnable — Zoom is always Zoom blue,
// Meet is always Meet teal, Teams is always Teams purple. A skin
// that overrode them would be vandalism (HIG §Colour).

/// The conferencing platform a meeting lives on. `.generic` is the
/// fallback when the URL is recognisably a video meeting but the
/// provider isn't known to us.
enum MeetingPlatform: String, Codable, Hashable, CaseIterable {
    case zoom
    case meet
    case teams
    case webex
    case generic

    /// Display label suitable for buttons («Join Zoom», «Join»).
    var displayName: String {
        switch self {
        case .zoom:    return "Zoom"
        case .meet:    return "Meet"
        case .teams:   return "Teams"
        case .webex:   return "Webex"
        case .generic: return "Video"
        }
    }

    /// Brand colour. Hex values are from the mockup
    /// (`ui_kits/index2.html .platform-chip[data-app]`).
    var brandColor: Color {
        switch self {
        case .zoom:    return Color(red: 0.176, green: 0.549, blue: 1.0)     // #2D8CFF
        case .meet:    return Color(red: 0.0,   green: 0.537, blue: 0.482)   // #00897B
        case .teams:   return Color(red: 0.384, green: 0.392, blue: 0.655)   // #6264A7
        case .webex:   return Color(red: 0.0,   green: 0.604, blue: 0.851)   // #009ADB
        case .generic: return .secondary
        }
    }

    /// SF Symbol glyph. `generic` falls back to the system video
    /// icon; brand-specific glyphs would require shipping their own
    /// assets — out of scope for v1.
    var symbol: String { "video.fill" }

    /// Detect a platform from a conferencing URL. Returns `nil` if
    /// the URL is not recognisably a video meeting; returns
    /// `.generic` if it looks like a video URL but the provider
    /// is unknown.
    static func detect(from url: URL?) -> MeetingPlatform? {
        guard let url else { return nil }
        let host = url.host?.lowercased() ?? ""
        let s = url.absoluteString.lowercased()
        if host.contains("zoom.us") || s.hasPrefix("zoommtg:") || s.hasPrefix("zoomus:") {
            return .zoom
        }
        if host.contains("meet.google.com") {
            return .meet
        }
        if host.contains("teams.microsoft.com") || host.contains("teams.live.com") {
            return .teams
        }
        if host.contains("webex.com") {
            return .webex
        }
        // Any other URL with "meet" / "call" / "join" path components
        // is plausibly a video meeting we don't recognise.
        if s.contains("meet") || s.contains("call") || s.contains("join") {
            return .generic
        }
        return nil
    }
}

/// Compact pill labelling the conferencing platform. Used in event
/// row meta-stacks.
struct PlatformChip: View {
    let platform: MeetingPlatform
    let showLabel: Bool

    init(_ platform: MeetingPlatform, showLabel: Bool = true) {
        self.platform = platform
        self.showLabel = showLabel
    }

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: platform.symbol)
                .font(.caption2.weight(.semibold))
            if showLabel {
                Text(platform.displayName)
                    .font(.caption2.weight(.semibold))
            }
        }
        .foregroundStyle(platform.brandColor)
        .padding(.horizontal, 5)
        .padding(.vertical, 1)
        .background(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(platform.brandColor.opacity(DS.Opacity.subtleFill + 0.02))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .strokeBorder(
                    platform.brandColor.opacity(DS.Opacity.faintBorder),
                    lineWidth: 0.5
                )
        )
        .accessibilityLabel("\(platform.displayName) meeting")
    }
}

// MARK: - Preview

#if DEBUG
#Preview("PlatformChip · all platforms") {
    VStack(alignment: .leading, spacing: DS.Spacing.md) {
        HStack(spacing: DS.Spacing.sm) {
            PlatformChip(.zoom)
            PlatformChip(.meet)
            PlatformChip(.teams)
            PlatformChip(.webex)
            PlatformChip(.generic)
        }
        HStack(spacing: DS.Spacing.sm) {
            PlatformChip(.zoom, showLabel: false)
            PlatformChip(.meet, showLabel: false)
            PlatformChip(.teams, showLabel: false)
        }
        VStack(alignment: .leading, spacing: DS.Spacing.xs) {
            Text("URL detection samples").font(.caption.weight(.semibold))
            ForEach([
                "https://zoom.us/j/12345",
                "https://meet.google.com/abc-defg-hij",
                "https://teams.microsoft.com/l/meetup-join/…",
                "https://webex.com/meet/team",
                "https://example.com/calls/123",
                "https://example.com/posts/foo",
            ], id: \.self) { raw in
                HStack {
                    Text(raw).font(.caption.monospaced()).foregroundStyle(.secondary)
                    Spacer()
                    if let platform = MeetingPlatform.detect(from: URL(string: raw)) {
                        PlatformChip(platform, showLabel: false)
                    } else {
                        Text("—").foregroundStyle(.tertiary)
                    }
                }
            }
        }
    }
    .padding()
    .frame(width: 420)
}
#endif
