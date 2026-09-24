// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "GhostHand",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "GhostHandApp", targets: ["GhostHandApp"]),
        .executable(name: "ghosthand", targets: ["GhostHandCLI"]),
    ],
    targets: [
        // Platform-independent logic: models, Jev client, risk policy, agent loop.
        .target(name: "GhostHandCore"),
        // macOS services: Accessibility, Vision OCR, CGEvent input, Keychain, Speech.
        .target(name: "GhostHandPlatform", dependencies: ["GhostHandCore"]),
        // Menu bar app with prompt panel and confirmation dialog.
        .executableTarget(name: "GhostHandApp", dependencies: ["GhostHandCore", "GhostHandPlatform"]),
        // `ghosthand check | read | run` developer CLI.
        .executableTarget(name: "GhostHandCLI", dependencies: ["GhostHandCore", "GhostHandPlatform"]),
        .testTarget(name: "GhostHandCoreTests", dependencies: ["GhostHandCore"]),
        .testTarget(name: "GhostHandPlatformTests", dependencies: ["GhostHandPlatform"]),
    ],
    swiftLanguageModes: [.v5]
)
