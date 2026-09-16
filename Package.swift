// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "sniffing",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(name: "sniffing", path: "Sources/sniffing"),
        .testTarget(name: "sniffingTests", dependencies: ["sniffing"], path: "Tests/sniffingTests"),
    ]
)
