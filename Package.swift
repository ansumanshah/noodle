// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Noodle",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "noodled", targets: ["noodled"]),
        .executable(name: "noodle", targets: ["noodle"]),
        .executable(name: "noodle-machine", targets: ["noodle-machine"]),
        .library(name: "NoodleCore", targets: ["NoodleCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.80.0"),
    ],
    targets: [
        // Foundation only. Shared by daemon, CLI and app. Never import NIO or SwiftUI here.
        .target(name: "NoodleCore"),
        .target(name: "NoodleVM", dependencies: ["NoodleCore"]),
        .target(name: "NoodleImages", dependencies: ["NoodleCore"], linkerSettings: [.linkedLibrary("z")]),
        .target(name: "NoodleEngine", dependencies: ["NoodleCore", "NoodleVM", "NoodleImages"]),
        .target(name: "NoodleAPI", dependencies: [
            "NoodleCore", "NoodleEngine",
            .product(name: "NIOCore", package: "swift-nio"),
            .product(name: "NIOPosix", package: "swift-nio"),
            .product(name: "NIOHTTP1", package: "swift-nio"),
        ]),
        .executableTarget(name: "noodled", dependencies: ["NoodleCore", "NoodleEngine", "NoodleAPI"]),
        .executableTarget(name: "noodle", dependencies: ["NoodleCore"]),
        // One process per running Linux machine. Not linked into noodled.
        .executableTarget(name: "noodle-machine"),
        .testTarget(name: "NoodleCoreTests", dependencies: ["NoodleCore"], path: "tests/NoodleCoreTests"),
        .testTarget(name: "NoodleEngineTests", dependencies: ["NoodleCore", "NoodleImages", "NoodleVM", "NoodleEngine", "NoodleAPI", "noodle"], path: "tests/NoodleEngineTests"),
    ]
)
