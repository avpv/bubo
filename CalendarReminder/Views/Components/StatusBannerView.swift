import SwiftUI

struct StatusBanner: View {
    let icon: String
    let text: String
    let color: Color

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.caption2)
                .foregroundColor(color)
            Text(text)
                .font(.caption2)
                .foregroundColor(.primary.opacity(0.8))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(color.opacity(0.1))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(color.opacity(0.2), lineWidth: 0.5)
        )
        .padding(.horizontal, 8)
    }
}
