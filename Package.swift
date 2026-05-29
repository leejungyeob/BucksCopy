// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "BucksCopyServer",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(
            name: "BucksCopyPaperRunner",
            targets: ["BucksCopyPaperRunner"]
        )
    ],
    targets: [
        .executableTarget(
            name: "BucksCopyPaperRunner",
            path: ".",
            exclude: [
                ".codex",
                ".dockerignore",
                ".github",
                "AGENTS.md",
                "BucksCopy.xcodeproj",
                "BucksCopy.xcworkspace",
                "Derived",
                "Project.swift",
                "README.md",
                "Tests",
                "docs",
                "fixtures",
                "scripts",
                "Server/Dockerfile",
                "Server/README.md",
                "Server/docker-compose.paper.yml",
                "Server/env.paper.example",
                "Sources/BucksCopy/App",
                "Sources/BucksCopy/Presentation",
                "Sources/BucksCopy/Data/BitgetAccountRepository.swift",
                "Sources/BucksCopy/Data/BitgetCandleBackfillRepository.swift",
                "Sources/BucksCopy/Data/BitgetCandleWebSocketClient.swift",
                "Sources/BucksCopy/Data/BitgetLiveOrderClient.swift",
                "Sources/BucksCopy/Data/BitgetPositionRepository.swift",
                "Sources/BucksCopy/Data/BitgetPositionWebSocketClient.swift",
                "Sources/BucksCopy/Data/BitgetRESTClient.swift",
                "Sources/BucksCopy/Data/BitgetRequestSigner.swift",
                "Sources/BucksCopy/Data/BitgetSymbolCatalogRepository.swift",
                "Sources/BucksCopy/Data/BitgetTPSLOrderClient.swift",
                "Sources/BucksCopy/Data/DemoDataSeeder.swift",
                "Sources/BucksCopy/Data/InMemoryCredentialStore.swift",
                "Sources/BucksCopy/Data/KeychainCredentialStore.swift",
                "Sources/BucksCopy/Data/SQLiteCandleRepository.swift",
                "Sources/BucksCopy/Data/SQLiteDatabase.swift",
                "Sources/BucksCopy/Data/SQLiteTradeEventLogStore.swift"
            ],
            sources: [
                "Sources/BucksCopy/Domains",
                "Server/PaperRunner"
            ]
        )
    ]
)
