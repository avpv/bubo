// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "CalendarReminder",
    platforms: [
        .macOS(.v13)
    ],
    targets: [
        .executableTarget(
            name: "CalendarReminder",
            path: "CalendarReminder",
            exclude: ["Info.plist"],
            resources: [
                .copy("Resources/AppIcon.icns"),
                .copy("Resources/MenuBarIcon.png"),
                .copy("Resources/MenuBarIcon@2x.png"),
            ]
        )
    ]
)
