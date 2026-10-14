// swift-tools-version:6.2
import PackageDescription

let package = Package(
    name: "SymphonyBar",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "SymphonyBar", targets: ["SymphonyBar"]),
        .library(name: "SymphonyBarCore", targets: ["SymphonyBarCore"]),
        .library(name: "SymphonyBarUI", targets: ["SymphonyBarUI"]),
    ],
    targets: [
        .executableTarget(
            name: "SymphonyBar",
            dependencies: ["SymphonyBarCore", "SymphonyBarUI"]
        ),
        .target(name: "SymphonyBarCore"),
        // AppKit views the app wraps for SwiftUI, kept out of the executable so they are tested without a window.
        .target(name: "SymphonyBarUI", dependencies: ["SymphonyBarCore"]),
        .testTarget(
            name: "SymphonyBarCoreTests",
            dependencies: ["SymphonyBarCore"],
            // Read from the source tree by path, so the tests also run without a resource bundle.
            exclude: ["Fixtures"]
        ),
        .testTarget(
            name: "SymphonyBarUITests",
            dependencies: ["SymphonyBarUI", "SymphonyBarCore"]
        ),
    ],
    // Swift 6 tools with the Swift 5 language mode: the app predates strict concurrency checking.
    swiftLanguageModes: [.v5]
)
