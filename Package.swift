// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Owlenda",
    platforms: [
        .macOS(.v13)
    ],
    targets: [
        .executableTarget(
            name: "Owlenda",
            path: "Owlenda",
            exclude: ["Info.plist", "Resources/owl.svg"],
            resources: [
                .copy("Resources/AppIcon.icns"),
                .copy("Resources/MenuBarIcon.png"),
                .copy("Resources/MenuBarIcon@2x.png"),
            ]
        )
    ]
)
