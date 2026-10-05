// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Keet",
    platforms: [.macOS(.v15)],
    dependencies: [
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.17.4"),
    ],
    targets: [
        // whisper.cpp v1.9.4 (tag commit 927cfce, published as build b5130), for Hebrew.
        .binaryTarget(
            name: "whisper",
            url: "https://github.com/ggml-org/whisper.cpp/releases/download/b5130/whisper-b5130-xcframework.zip",
            checksum: "033a43b0174e8cf9b366f72e4a428cdcf126f93ad1c87d3fa119a96bed6f231a"
        ),
        .target(
            name: "KeetCore",
            dependencies: [.product(name: "FluidAudio", package: "FluidAudio"), "whisper"]
        ),
        .executableTarget(
            name: "Keet", dependencies: ["KeetCore"],
            // build-app.sh puts whisper.framework in Contents/Frameworks.
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]
        ),
        .executableTarget(name: "keet-bench", dependencies: ["KeetCore"]),
        .testTarget(name: "KeetCoreTests", dependencies: ["KeetCore"]),
    ],
    swiftLanguageModes: [.v5]
)
