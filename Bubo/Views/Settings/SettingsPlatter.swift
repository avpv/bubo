import SwiftUI

struct SettingsPlatter<Content: View>: View {
    var title: String?
    let content: Content

    @Environment(\.activeSkin) private var skin

    init(_ title: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.md) {
            if let title {
                Text(title)
                    // PRINCIPLES §8: route titles through the shared
                    // headline accessor so the active skin's font
                    // design and headline weight apply, instead of
                    // pinning every Settings card title to the system
                    // headline style.
                    .font(DS.Typography.headline(skin: skin))
                    .foregroundStyle(skin.resolvedTextPrimary)
                    .accessibilityAddTraits(.isHeader)
                    .padding(.bottom, DS.Spacing.xs)
            }
            content
        }
        .padding(DS.Spacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .skinPlatter(skin)
        .skinPlatterDepth(skin)
    }
}
