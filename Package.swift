// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MacUp",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(name: "MacUpCore", targets: ["MacUpCore"]),
        .executable(name: "macup", targets: ["macup"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0"),
    ],
    targets: [
        .target(
            name: "MacUpCore"
        ),
        .executableTarget(
            name: "macup",
            dependencies: [
                "MacUpCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        // Fakes shared by the test targets. Never linked into shipping products.
        .target(
            name: "MacUpTestSupport",
            dependencies: ["MacUpCore"],
            path: "Tests/MacUpTestSupport"
        ),
        .testTarget(
            name: "MacUpCoreTests",
            dependencies: ["MacUpCore", "MacUpTestSupport"],
            resources: [.copy("Fixtures")]
        ),
        .testTarget(
            name: "MacUpCLITests",
            dependencies: ["macup", "MacUpCore", "MacUpTestSupport"]
        ),
    ]
)
