// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Bubo",
    platforms: [
        .macOS(.v14)
    ],
    targets: [
        .executableTarget(
            name: "Bubo",
            path: "Bubo",
            exclude: ["Info.plist", "Resources/owl.svg", "Bubo.entitlements", "Bubo.adhoc.entitlements", "Presentation/Skins/TEMPLATE.json", "Presentation/Skins/buboskin.schema.json", "Domain/Reminders/README.md"],
            resources: [
                .copy("Resources/AppIcon.icns"),
                .copy("Resources/MenuBarIcon.png"),
                .copy("Resources/MenuBarIcon@2x.png"),
                .copy("Presentation/Skins/BuiltInSkins"),
            ]
        ),
        .testTarget(
            name: "BuboTests",
            dependencies: ["Bubo"],
            path: "Tests/BuboTests"
        ),
    ]
)
