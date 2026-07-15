// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "SwiftAgentKit",
    platforms: [
        .iOS("26.4"),
        .macOS("26.4")
    ],
    products: [
        .library(name: "SwiftAgentKit", targets: ["SwiftAgentKit"]),
        .library(name: "SwiftAgentKitOpenAI", targets: ["SwiftAgentKitOpenAI"]),
        .library(name: "SwiftAgentKitFoundationModels", targets: ["SwiftAgentKitFoundationModels"])
    ],
    targets: [
        .target(name: "SwiftAgentKit"),
        .target(
            name: "SwiftAgentKitOpenAI",
            dependencies: ["SwiftAgentKit"]
        ),
        .target(
            name: "SwiftAgentKitFoundationModels",
            dependencies: ["SwiftAgentKit"]
        )
    ]
)
