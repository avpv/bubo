// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Bubo",
    platforms: [
        .macOS(.v14)
    ],
    targets: [
        // Pure value-type domain layer. No dependencies on the rest of the
        // codebase. Carries CalendarEvent, BacklogTask, RecurrenceRule,
        // Period, PomodoroConfig, OptimizableEvent, ReminderSettings, etc.
        .target(
            name: "BuboDomain",
            path: "Sources/BuboDomain",
            exclude: ["Reminders/README.md"]
        ),
        // Multi-objective scheduling engine. Depends on BuboDomain for
        // value types (CalendarEvent, BacklogTask, Period, PomodoroConfig,
        // OptimizableEvent). No dependency on the main Bubo target.
        .target(
            name: "BuboOptimizer",
            dependencies: ["BuboDomain"],
            path: "Sources/BuboOptimizer",
            exclude: ["README.md"]
        ),
        // The macOS app: Composition, Presentation, Application,
        // Infrastructure layers. Depends on both BuboDomain and
        // BuboOptimizer for the types they own.
        .executableTarget(
            name: "Bubo",
            dependencies: ["BuboDomain", "BuboOptimizer"],
            path: "Bubo",
            exclude: [
                "Info.plist",
                "Resources/owl.svg",
                "Bubo.entitlements",
                "Bubo.adhoc.entitlements",
                "Presentation/Views/Skins/TEMPLATE.json",
                "Presentation/Views/Skins/buboskin.schema.json",
            ],
            resources: [
                .copy("Resources/AppIcon.icns"),
                .copy("Resources/MenuBarIcon.png"),
                .copy("Resources/MenuBarIcon@2x.png"),
                .copy("Presentation/Views/Skins/BuiltInSkins"),
            ]
        ),
        .testTarget(
            name: "BuboTests",
            dependencies: ["Bubo", "BuboDomain", "BuboOptimizer"],
            path: "Tests"
        ),
    ]
)
