// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "YandexCalendarReminder",
    platforms: [
        .macOS(.v13)
    ],
    targets: [
        .executableTarget(
            name: "YandexCalendarReminder",
            path: "YandexCalendarReminder"
        )
    ]
)
