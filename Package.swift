// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Minutes",
    platforms: [.macOS("26.0")],
    dependencies: [
        // On-device speaker diarization (CoreML). traits: [] leaves out the text-processing binary
        // (only used for text-to-speech), so only the diarization code is linked.
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.17.5", traits: []),
    ],
    targets: [
        .executableTarget(
            name: "Minutes",
            dependencies: [.product(name: "FluidAudio", package: "FluidAudio")],
            path: "Sources/Minutes"
        )
    ]
)
