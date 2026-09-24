// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Shebang",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "ShebangApp", targets: ["ShebangApp"]),
        .executable(name: "shebang", targets: ["ShebangCLI"]),
    ],
    targets: [
        // Platform-independent logic: models, Jev client, risk policy, agent loop.
        .target(name: "ShebangCore"),
        // macOS services: Accessibility, Vision OCR, CGEvent input, Keychain, Speech.
        .target(name: "ShebangPlatform", dependencies: ["ShebangCore"]),
        // Menu bar app with prompt panel and confirmation dialog.
        .executableTarget(name: "ShebangApp", dependencies: ["ShebangCore", "ShebangPlatform"]),
        // `shebang check | read | run` developer CLI.
        .executableTarget(name: "ShebangCLI", dependencies: ["ShebangCore", "ShebangPlatform"]),
        .testTarget(name: "ShebangCoreTests", dependencies: ["ShebangCore"]),
        .testTarget(name: "ShebangPlatformTests", dependencies: ["ShebangPlatform"]),
        .testTarget(name: "ShebangAppTests", dependencies: ["ShebangApp"]),
    ],
    swiftLanguageModes: [.v5]
)
