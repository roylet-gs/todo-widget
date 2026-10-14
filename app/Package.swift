// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "TodoWidget",
    platforms: [.macOS(.v26)],
    targets: [
        .binaryTarget(name: "TodoCoreFFI", path: "Generated/TodoCoreFFI.xcframework"),
        .target(name: "TodoCore", dependencies: ["TodoCoreFFI"], path: "Sources/TodoCore"),
        .executableTarget(
            name: "TodoWidget",
            dependencies: ["TodoCore"],
            path: "Sources/TodoWidget"
        ),
    ]
)
