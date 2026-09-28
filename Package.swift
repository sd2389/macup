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
        // The SwiftUI desktop app. Built with scripts/build-app.sh until the
        // Xcode project (Apps/MacUpApp/MacUpApp.xcodeproj) wraps the same sources.
        //
        // The app is a library plus a one-line entry point rather than one
        // executable, because a test target cannot import an executable and
        // the model is worth testing. It uses MacUpCore only; no provider or
        // policy logic lives here.
        .target(
            name: "MacUpAppCore",
            dependencies: ["MacUpCore"],
            path: "Apps/MacUpApp/MacUpApp",
            exclude: ["Resources"]
        ),
        .executableTarget(
            name: "MacUpApp",
            dependencies: ["MacUpAppCore"],
            path: "Apps/MacUpApp/Main"
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
        .testTarget(
            name: "MacUpAppTests",
            dependencies: ["MacUpAppCore", "MacUpCore", "MacUpTestSupport"]
        ),
    ]
)
