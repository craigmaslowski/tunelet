// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "Tunelet",
    platforms: [.macOS(.v26)],
    targets: [
        .target(name: "TuneletCore"),
        // The menu-bar app. Run it as a bundle via scripts/bundle.sh, not `swift run`:
        // LSUIElement and microphone permission both need the Info.plist.
        .executableTarget(name: "Tunelet", dependencies: ["TuneletCore"]),
        // Command-line check of live capture against a real instrument: swift run tunelet-probe
        .executableTarget(name: "tunelet-probe", dependencies: ["TuneletCore"]),
        .testTarget(name: "TuneletCoreTests", dependencies: ["TuneletCore"]),
    ]
)
