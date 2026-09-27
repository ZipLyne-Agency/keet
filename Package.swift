// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Keet",
    platforms: [.macOS(.v15)],
    dependencies: [
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.17.4"),
    ],
    targets: [
        .target(
            name: "KeetCore",
            dependencies: [.product(name: "FluidAudio", package: "FluidAudio")]
        ),
        .executableTarget(name: "Keet", dependencies: ["KeetCore"]),
        .executableTarget(name: "keet-bench", dependencies: ["KeetCore"]),
        .testTarget(name: "KeetCoreTests", dependencies: ["KeetCore"]),
    ],
    swiftLanguageModes: [.v5]
)
