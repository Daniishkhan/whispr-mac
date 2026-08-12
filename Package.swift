// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Whispr",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Whispr",
            path: "Sources/Whispr"
        ),
        .testTarget(
            name: "WhisprTests",
            dependencies: ["Whispr"],
            path: "Tests/WhisprTests"
        ),
    ]
)
