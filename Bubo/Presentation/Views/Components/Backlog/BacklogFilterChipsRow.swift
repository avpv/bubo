import SwiftUI

/// Horizontally-scrolling row of project + color filter chips above the
/// backlog list. Project chips hide when the picker has already selected
/// an active project: in that state the backlog is already filtered by
/// one context and chip clicks would intersect with the picker, yielding
/// either a redundant pill or an empty result. Color chips remain — they
/// work on top of the project and don't duplicate it.
///
/// Selection is owned by the host as `@State`; the row mutates it via
/// the two `@Binding`s.
struct BacklogFilterChipsRow: View {
    let projects: [String]
    let colors: [EventColorTag]
    @Binding var projectFilter: String?
    @Binding var colorFilter: EventColorTag?

    @Environment(\.activeSkin) private var skin
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if !projects.isEmpty || !colors.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: DS.Spacing.xs) {
                    ForEach(projects, id: \.self) { project in
                        projectChip(project)
                    }
                    if !projects.isEmpty && !colors.isEmpty {
                        Divider()
                            .frame(height: 16)
                            .padding(.horizontal, DS.Spacing.xxs)
                    }
                    ForEach(colors, id: \.rawValue) { color in
                        colorChip(color)
                    }
                }
                .padding(.horizontal, DS.Spacing.sm)
                .padding(.vertical, DS.Spacing.xxs)
            }
        }
    }

    @ViewBuilder
    private func projectChip(_ project: String) -> some View {
        let isOn = projectFilter == project
        Button {
            Haptics.tap()
            withAnimation(DS.Animation.motionAware(DS.Animation.quick, reduceMotion: reduceMotion)) {
                projectFilter = isOn ? nil : project
            }
        } label: {
            Text(project)
                .font(.footnote.weight(isOn ? .semibold : .regular))
                .foregroundStyle(isOn ? skin.accentColor : skin.resolvedTextSecondary)
                .padding(.horizontal, DS.Spacing.sm)
                .padding(.vertical, DS.Spacing.xxs)
                .background(
                    Capsule().fill(skin.accentColor.opacity(isOn ? DS.Opacity.lightFill : 0))
                )
                .overlay(
                    Capsule().strokeBorder(
                        skin.accentColor.opacity(isOn ? DS.Opacity.softAccent : DS.Opacity.borderIdle),
                        lineWidth: DS.Border.thin
                    )
                )
        }
        .buttonStyle(.plain)
        .help(isOn ? "Showing tasks in \u{201C}\(project)\u{201D} — tap to clear" : "Filter to \u{201C}\(project)\u{201D}")
    }

    @ViewBuilder
    private func colorChip(_ color: EventColorTag) -> some View {
        let isOn = colorFilter == color
        Button {
            Haptics.tap()
            withAnimation(DS.Animation.motionAware(DS.Animation.quick, reduceMotion: reduceMotion)) {
                colorFilter = isOn ? nil : color
            }
        } label: {
            Circle()
                .fill(color.color)
                .frame(width: 12, height: 12)
                .padding(.horizontal, DS.Spacing.xxs)
                .padding(.vertical, DS.Spacing.xxs)
                .overlay(
                    Capsule().strokeBorder(
                        skin.accentColor.opacity(isOn ? DS.Opacity.softAccent : 0),
                        lineWidth: DS.Border.thin
                    )
                )
                .padding(.horizontal, DS.Spacing.xxs)
                .background(
                    Capsule().fill(color.color.opacity(isOn ? DS.Opacity.subtleFill : 0))
                )
        }
        .buttonStyle(.plain)
        .help(isOn ? "Showing only \(color.rawValue) tasks — tap to clear" : "Filter to \(color.rawValue) tasks")
    }
}
