import ProjectDescription

let project = Project(
    name: "BucksCopy",
    options: .options(automaticSchemesOptions: .enabled()),
    settings: .settings(base: [
        "SWIFT_VERSION": "5.0",
        "MACOSX_DEPLOYMENT_TARGET": "14.0",
        "ENABLE_USER_SCRIPT_SANDBOXING": "NO"
    ]),
    targets: [
        .target(
            name: "BucksCopy",
            destinations: .macOS,
            product: .app,
            bundleId: "com.buckscopy.app",
            deploymentTargets: .macOS("14.0"),
            infoPlist: .extendingDefault(with: [
                "CFBundleDisplayName": "BucksCopy",
                "CFBundleShortVersionString": "0.1.0",
                "CFBundleVersion": "1",
                "LSMinimumSystemVersion": "14.0"
            ]),
            sources: ["Sources/BucksCopy/**"],
            dependencies: [],
            settings: .settings(base: [
                "OTHER_LDFLAGS": "$(inherited) -lsqlite3 -framework Security"
            ])
        ),
        .target(
            name: "BucksCopyTests",
            destinations: .macOS,
            product: .unitTests,
            bundleId: "com.buckscopy.tests",
            deploymentTargets: .macOS("14.0"),
            infoPlist: .default,
            sources: ["Tests/BucksCopyTests/**"],
            dependencies: [
                .target(name: "BucksCopy")
            ]
        )
    ]
)
