// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "FramePipelineKit",
    platforms: [.macOS(.v12)],
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
