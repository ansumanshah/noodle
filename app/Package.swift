// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "NoodleApp",
    defaultLocalization: "en",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "NoodleApp", targets: ["NoodleApp"]),
    ],
    dependencies: [
        .package(name: "Noodle", path: ".."),
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", exact: "1.99.3"),
    ],
    targets: [
        .executableTarget(name: "NoodleApp", dependencies: [
            .product(name: "NoodleCore", package: "Noodle"),
            .product(name: "SwiftTerm", package: "SwiftTerm"),
        ], resources: [.process("Resources/Localizable.xcstrings"), .process("Resources/apps.json")]),
        .testTarget(name: "NoodleAppTests", dependencies: [
            "NoodleApp", .product(name: "NoodleCore", package: "Noodle"),
        ], path: "tests/NoodleAppTests"),
    ]
)
