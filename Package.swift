// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "MacIDM",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "IDMEngine", targets: ["IDMEngine"]),
        .library(name: "MacIDMBridge", targets: ["MacIDMBridge"]),
        .executable(name: "macidm", targets: ["MacIDMCLI"]),
        .executable(name: "MacIDMDesktop", targets: ["MacIDMApp"]),
        .executable(name: "macidm-host", targets: ["MacIDMHost"]),
    ],
    targets: [
        .target(name: "IDMEngine"),
        .target(
            name: "MacIDMBridge",
            linkerSettings: [.linkedFramework("Security")]
        ),
        .executableTarget(
            name: "MacIDMCLI",
            dependencies: ["IDMEngine"],
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .executableTarget(
            name: "MacIDMApp",
            dependencies: ["IDMEngine", "MacIDMBridge"],
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .executableTarget(name: "MacIDMHost", dependencies: ["MacIDMBridge"]),
        .testTarget(name: "IDMEngineTests", dependencies: ["IDMEngine"]),
        .testTarget(name: "MacIDMBridgeTests", dependencies: ["MacIDMBridge"]),
        .testTarget(name: "MacIDMAppTests", dependencies: ["MacIDMApp", "MacIDMCLI"]),
    ]
)
