// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "FramePipelineKit",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "FramePipelineKit", targets: ["FramePipelineKit"])
    ],
    targets: [
        .target(name: "FramePipelineKit"),
        .testTarget(
            name: "FramePipelineKitTests",
            dependencies: ["FramePipelineKit"]
        )
    ]
)
