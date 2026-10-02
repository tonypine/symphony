// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "SymphonyBar",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "SymphonyBar", targets: ["SymphonyBar"]),
        .library(name: "SymphonyBarCore", targets: ["SymphonyBarCore"]),
    ],
    targets: [
        .executableTarget(
            name: "SymphonyBar",
            dependencies: ["SymphonyBarCore"]
        ),
        .target(name: "SymphonyBarCore"),
        .testTarget(
            name: "SymphonyBarCoreTests",
            dependencies: ["SymphonyBarCore"],
            // Read from the source tree by path, so the tests also run without a resource bundle.
            exclude: ["Fixtures"]
        ),
    ]
)
