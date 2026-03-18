import SwiftUI

struct SettingsPlatter<Content: View>: View {
    var title: String?
    let content: Content

    init(_ title: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.md) {
            if let title {
                Text(title)
                    .font(.headline)
                    .foregroundColor(DS.Colors.textPrimary)
                    .padding(.bottom, DS.Spacing.xs)
            }
            content
        }
        .padding(DS.Spacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DS.Materials.platter)
        .clipShape(RoundedRectangle(cornerRadius: DS.Size.cornerRadius, style: .continuous))
        .shadow(color: DS.Shadows.ambientColor, radius: DS.Shadows.ambientRadius, y: DS.Shadows.ambientY)
    }
}
