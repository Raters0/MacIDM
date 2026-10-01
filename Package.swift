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
    dependencies: [
        // Sparkle 2 powers the in-app auto-update (EdDSA-signed releases,
        // appcast hosted as a GitHub Release asset). Zero-cost tier keeps
        // the app bundle ad-hoc signed; see technical-spec §6.1/§6.2.
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.10.0")
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
            dependencies: [
                "IDMEngine",
                "MacIDMBridge",
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .executableTarget(name: "MacIDMHost", dependencies: ["MacIDMBridge"]),
        .testTarget(name: "IDMEngineTests", dependencies: ["IDMEngine"]),
        .testTarget(name: "MacIDMBridgeTests", dependencies: ["MacIDMBridge"]),
        .testTarget(name: "MacIDMAppTests", dependencies: ["MacIDMApp", "MacIDMCLI"]),
    ]
)
