// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Session",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "SessionApp", targets: ["SessionApp"])],
    dependencies: [.package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0")],
    targets: [
        .target(name: "SessionCore", dependencies: [.product(name: "GRDB", package: "GRDB.swift")]),
        .executableTarget(name: "SessionApp", dependencies: ["SessionCore"], resources: [.copy("Resources/Fonts")]),
        .testTarget(name: "SessionCoreTests", dependencies: ["SessionCore"]),
    ]
)
