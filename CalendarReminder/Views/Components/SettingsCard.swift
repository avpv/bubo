import SwiftUI

struct SettingsCard<Content: View>: View {
    let icon: String
    let title: String
    let description: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.subheadline)
                    .foregroundStyle(.accentColor.gradient)
                    .frame(width: 20)

                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.system(.subheadline, design: .rounded).weight(.semibold))
                    Text(description)
                        .font(.system(size: 10, design: .rounded))
                        .foregroundColor(.secondary)
                }
            }

            content
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.primary.opacity(0.06), lineWidth: 0.5)
        )
    }
}
