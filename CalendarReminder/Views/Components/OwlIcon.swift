import SwiftUI

struct OwlIcon: View {
    var size: CGFloat = 20

    var body: some View {
        if let url = Bundle.module.url(forResource: "MenuBarIcon", withExtension: "png"),
           let nsImage = NSImage(contentsOf: url) {
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
