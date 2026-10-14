// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "TodoWidget",
    platforms: [.macOS(.v26)],
    targets: [
        .binaryTarget(name: "TodoCoreFFI", path: "Generated/TodoCoreFFI.xcframework"),
        .executableTarget(
            name: "TodoWidget",
            dependencies: ["TodoCoreFFI"],
            path: "Sources/TodoWidget"
        ),
    ]
)
