// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Session",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "SessionApp", targets: ["SessionApp"])],
    targets: [
        .target(name: "SessionCore"),
        .executableTarget(name: "SessionApp", dependencies: ["SessionCore"]),
        .testTarget(name: "SessionCoreTests", dependencies: ["SessionCore"]),
    ]
)
