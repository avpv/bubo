import SwiftUI

struct OwlIcon: View {
    var size: CGFloat = 20

    var body: some View {
        let url = Bundle.safeModule?.url(forResource: "MenuBarIcon", withExtension: "png")
            ?? Bundle.main.url(forResource: "MenuBarIcon", withExtension: "png")
        if let url, let nsImage = NSImage(contentsOf: url) {
            Image(nsImage: nsImage)
                .resizable()
                .interpolation(.high)
                .frame(width: size, height: size)
        } else {
            Image(systemName: "calendar.badge.clock")
                .resizable()
                .frame(width: size, height: size)
                .foregroundColor(.blue)
        }
    }
}
