// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "RAPPRewind",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "RAPPRewind", targets: ["RAPPRewind"]),
        .library(name: "RAPPRewindCore", targets: ["RAPPRewindCore"])
    ],
    dependencies: [
        .package(
            url: "https://github.com/kody-w/rapp-tools.git",
            revision: "f0bc616c2aed34f2a88888806ed056ec7bafba61"
        )
    ],
    targets: [
        .systemLibrary(name: "CSQLite"),
        .target(
            name: "RAPPRewindCore",
            dependencies: ["CSQLite"],
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .executableTarget(
            name: "RAPPRewind",
            dependencies: [
                "RAPPRewindCore",
                .product(name: "RAPPDesktopSupport", package: "rapp-tools")
            ],
            resources: [.process("Resources")]
        ),
        .testTarget(
            name: "RAPPRewindCoreTests",
            dependencies: ["RAPPRewindCore", "CSQLite"]
        )
    ]
)
