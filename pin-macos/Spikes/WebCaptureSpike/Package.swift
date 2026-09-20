// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "WebCaptureSpike",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "WebCaptureSpike", targets: ["WebCaptureSpike"])
    ],
    targets: [
        .executableTarget(
            name: "WebCaptureSpike",
            path: "Sources/WebCaptureSpike"
        ),
        .testTarget(
            name: "WebCaptureSpikeTests",
            dependencies: ["WebCaptureSpike"],
            path: "Tests/WebCaptureSpikeTests"
        )
    ]
)
