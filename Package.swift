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
            exclude: ["Info.plist", "Resources/owl.svg", "Bubo.entitlements", "Skins/TEMPLATE.json", "Skins/buboskin.schema.json"],
            resources: [
                .copy("Resources/AppIcon.icns"),
                .copy("Resources/MenuBarIcon.png"),
                .copy("Resources/MenuBarIcon@2x.png"),
                .copy("Skins/BuiltInSkins"),
            ]
        ),
        .testTarget(
            name: "OptimizerTests",
            dependencies: ["Bubo"],
            path: "Tests/OptimizerTests"
        ),
    ]
)
