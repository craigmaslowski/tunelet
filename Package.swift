// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "Tunelet",
    platforms: [.macOS(.v26)],
    targets: [
        .target(name: "TuneletCore"),
        .testTarget(name: "TuneletCoreTests", dependencies: ["TuneletCore"]),
    ]
)
