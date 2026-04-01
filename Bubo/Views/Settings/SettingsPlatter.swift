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
                    .font(.headline)
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
